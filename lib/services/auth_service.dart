import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/academy_session.dart';

class AuthService {
  static const _keyAcademyId = 'academy_id';
  static const _keyAcademyName = 'academy_name';
  static const _keyPhone = 'phone_number';
  static const _keyActorRole = 'actor_role';

  // ── 저장된 세션 복원 ────────────────────────────────────
  static Future<AcademySession?> getSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    final academyId = prefs.getString(_keyAcademyId);
    final academyName = prefs.getString(_keyAcademyName);
    final phone = prefs.getString(_keyPhone);
    final actorRole = prefs.getString(_keyActorRole) ?? 'director';
    if (academyId == null || academyName == null || phone == null) return null;
    return AcademySession(
      academyId: academyId,
      academyName: academyName,
      phoneNumber: phone,
      actorRole: actorRole,
    );
  }

  // ── 1단계: OTP 발송 ─────────────────────────────────────
  static Future<void> sendOtp({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(String message) onError,
    void Function(AcademySession session)? onAutoVerified,
  }) async {
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: _toE164(phoneNumber),
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        // Android 자동 인증 (SMS 없이 즉시 처리)
        try {
          final session = await _signIn(credential, phoneNumber);
          onAutoVerified?.call(session);
        } catch (e) {
          onError(e.toString());
        }
      },
      verificationFailed: (FirebaseAuthException e) {
        onError(parseError(e));
      },
      codeSent: (String verificationId, int? _) {
        onCodeSent(verificationId);
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  // ── 2단계: OTP 확인 ─────────────────────────────────────
  static Future<AcademySession> verifyOtp({
    required String verificationId,
    required String smsCode,
    required String phoneNumber,
  }) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
    return _signIn(credential, phoneNumber);
  }

  // ── 테스트 모드 세션 (네트워크 없이 바로 로그인) ──────────
  static Future<AcademySession> createMockSession(String phoneNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAcademyId, 'test_academy');
    await prefs.setString(_keyAcademyName, '테스트 학원');
    await prefs.setString(_keyPhone, phoneNumber);
    await prefs.setString(_keyActorRole, 'director');
    return AcademySession(
      academyId: 'test_academy',
      academyName: '테스트 학원',
      phoneNumber: phoneNumber,
      actorRole: 'director',
    );
  }

  // ── 로그아웃 ────────────────────────────────────────────
  static Future<void> logout() async {
    await FirebaseAuth.instance.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAcademyId);
    await prefs.remove(_keyAcademyName);
    await prefs.remove(_keyPhone);
    await prefs.remove(_keyActorRole);
  }

  // ── 내부 공통 로그인 처리 ───────────────────────────────
  static Future<AcademySession> _signIn(
    PhoneAuthCredential credential,
    String phoneNumber,
  ) async {
    final result = await FirebaseAuth.instance.signInWithCredential(credential);
    final uid = result.user!.uid;

    final firestore = FirebaseFirestore.instance;
    final userDoc = await firestore.collection('users').doc(uid).get();
    final userData = userDoc.data();

    final String academyId;
    final String academyName;
    final String actorRole;

    final userAcademyId =
        userData?['academyId'] as String? ??
        userData?['associatedAcademyId'] as String? ??
        userData?['activeAcademyId'] as String?;
    final role =
        userData?['role'] as String? ?? userData?['activeRole'] as String?;

    if (userAcademyId != null && userAcademyId.isNotEmpty) {
      academyId = userAcademyId;
      actorRole = role == 'teacher' ? 'teacher' : 'director';
    } else {
      final academySnap = await firestore
          .collection('academies')
          .where('directorUid', isEqualTo: uid)
          .limit(1)
          .get();
      if (academySnap.docs.isEmpty) {
        throw FirebaseAuthException(
          code: 'academy-not-found',
          message: '연결된 학원 정보를 찾을 수 없습니다.',
        );
      }
      academyId = academySnap.docs.first.id;
      actorRole = 'director';
    }

    final academyDoc = await firestore
        .collection('academies')
        .doc(academyId)
        .get();
    academyName = academyDoc.data()?['name'] as String? ?? '내 학원';

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAcademyId, academyId);
    await prefs.setString(_keyAcademyName, academyName);
    await prefs.setString(_keyPhone, phoneNumber);
    await prefs.setString(_keyActorRole, actorRole);

    return AcademySession(
      academyId: academyId,
      academyName: academyName,
      phoneNumber: phoneNumber,
      actorRole: actorRole,
    );
  }

  // 010-1234-5678 → +821012345678
  static String _toE164(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    final national = digits.startsWith('0') ? digits.substring(1) : digits;
    return '+82$national';
  }

  static String parseError(FirebaseAuthException e) {
    return switch (e.code) {
      'invalid-phone-number' => '올바른 전화번호 형식이 아닙니다.',
      'too-many-requests' => '요청이 너무 많습니다. 잠시 후 다시 시도해주세요.',
      'invalid-verification-code' => '인증번호가 올바르지 않습니다.',
      'session-expired' => '인증 시간이 만료되었습니다. 다시 시도해주세요.',
      'network-request-failed' => '네트워크 연결을 확인해주세요.',
      _ => '오류가 발생했습니다. (${e.code})',
    };
  }
}
