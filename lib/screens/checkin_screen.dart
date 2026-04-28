import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/platform_tags.dart';

import '../models/academy_session.dart';
import '../models/attendance_record.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';

enum _FeedbackKind { success, duplicate, unknown, error }


class _Feedback {
  final _FeedbackKind kind;
  final String? studentName;
  final AttendanceType? attendanceType;
  final String? message;

  const _Feedback({
    required this.kind,
    this.studentName,
    this.attendanceType,
    this.message,
  });
}

class CheckinScreen extends StatefulWidget {
  final AcademySession session;
  const CheckinScreen({super.key, required this.session});

  @override
  State<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends State<CheckinScreen>
    with SingleTickerProviderStateMixin {
  // 피드백 오버레이 애니메이션
  late final AnimationController _overlayCtrl;
  late final Animation<double> _overlayOpacity;
  late final Animation<double> _cardScale;

  bool _isProcessing = false;
  _Feedback? _feedback;
  Timer? _dismissTimer;

  // ── [TEST ONLY] 가상 태깅 in-memory 상태 — 배포 시 삭제 ──
  DateTime? _lastTestTagTime;
  AttendanceType? _lastTestTagType;
  final List<Map<String, dynamic>> _testLocalRecords = [];

  @override
  void initState() {
    super.initState();
    _overlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _overlayOpacity =
        CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeOut);
    _cardScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeOutBack),
    );
    _startNfc();
  }

  @override
  void dispose() {
    _overlayCtrl.dispose();
    _dismissTimer?.cancel();
    NfcManager.instance.stopSession();
    super.dispose();
  }

  // ── NFC ─────────────────────────────────────────────────
  Future<void> _startNfc() async {
    final available = await NfcManager.instance.isAvailable();
    if (!available) {
      _showFeedback(const _Feedback(
        kind: _FeedbackKind.error,
        message: 'NFC를 사용할 수 없습니다.\n기기 설정에서 NFC를 활성화해주세요.',
      ));
      return;
    }
    NfcManager.instance.startSession(onDiscovered: _onTag);
  }

  Future<void> _onTag(NfcTag tag) async {
    if (_isProcessing) return;
    _isProcessing = true;

    final uid = _extractUid(tag);
    if (uid == null) {
      _showFeedback(const _Feedback(
        kind: _FeedbackKind.error,
        message: '카드를 인식하지 못했습니다.\n다시 태깅해주세요.',
      ));
      return;
    }
    await _processUid(uid);
  }

  Future<void> _processUid(String uid) async {
    final result = await AttendanceService.processTag(
      nfcUid: uid,
      academyId: widget.session.academyId,
    );

    switch (result) {
      case AttendanceSuccess(:final student, :final type):
        _showFeedback(_Feedback(
          kind: _FeedbackKind.success,
          studentName: student.name,
          attendanceType: type,
        ));
      case AttendanceDuplicate(:final student, :final lastType):
        _showFeedback(_Feedback(
          kind: _FeedbackKind.duplicate,
          studentName: student.name,
          attendanceType: lastType,
        ));
      case AttendanceUnknownCard():
        _showFeedback(const _Feedback(
          kind: _FeedbackKind.unknown,
          message: '등록되지 않은 카드입니다.',
        ));
      case AttendanceError(:final message):
        _showFeedback(_Feedback(kind: _FeedbackKind.error, message: message));
    }
  }

  // ── [TEST ONLY] 가상 태깅 — 배포 시 이 메서드 삭제 ───────
  void _mockTagTap() {
    if (_isProcessing) return;
    _isProcessing = true;

    const mockName = '테스트 학생';
    const duplicateWindow = Duration(minutes: 20);
    final now = DateTime.now();

    // ① 20분 중복 체크 — 순수 in-memory, 네트워크 완전 무관
    final lastTime = _lastTestTagTime;
    if (lastTime != null && now.difference(lastTime) < duplicateWindow) {
      _showFeedback(_Feedback(
        kind: _FeedbackKind.duplicate,
        studentName: mockName,
        attendanceType: _lastTestTagType,
      ));
      return;
    }

    // ② 등원 ↔ 하원 토글
    final nextType = (_lastTestTagType == AttendanceType.arrival)
        ? AttendanceType.departure
        : AttendanceType.arrival;
    final timeStr = DateFormat('HH:mm').format(now);

    // ③ setState로 로컬 리스트·상태 즉시 갱신 (Firestore await 없음)
    setState(() {
      _lastTestTagTime = now;
      _lastTestTagType = nextType;
      _testLocalRecords.insert(0, {
        'name': mockName,
        'time': timeStr,
        'isArrival': nextType == AttendanceType.arrival,
      });
    });

    // ④ Firestore 저장 — fire-and-forget (await 없음 → 무반응 버그 해결)
    FirebaseFirestore.instance.collection('attendance').add({
      'studentId': '__mock_student__',
      'studentName': mockName,
      'academyId': widget.session.academyId,
      'type': nextType == AttendanceType.arrival ? 'arrival' : 'departure',
      'timestamp': Timestamp.fromDate(now),
      'date': DateFormat('yyyy-MM-dd').format(now),
    }).catchError((_) {});

    // ⑤ 성공 오버레이 즉시 표시
    _showFeedback(_Feedback(
      kind: _FeedbackKind.success,
      studentName: mockName,
      attendanceType: nextType,
    ));
  }

  String? _extractUid(NfcTag tag) {
    final id = NfcA.from(tag)?.identifier ??
        NfcB.from(tag)?.identifier ??
        NfcF.from(tag)?.identifier ??
        NfcV.from(tag)?.identifier ??
        IsoDep.from(tag)?.identifier ??
        MifareClassic.from(tag)?.identifier ??
        MifareUltralight.from(tag)?.identifier;
    if (id == null) return null;
    return id.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
  }

  // ── 피드백 오버레이 제어 ─────────────────────────────────
  void _showFeedback(_Feedback fb) {
    if (!mounted) return;
    setState(() => _feedback = fb);
    _overlayCtrl.forward(from: 0);

    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _overlayCtrl.reverse().then((_) {
        if (mounted) {
          setState(() {
            _feedback = null;
            _isProcessing = false;
          });
        }
      });
    });
  }

  // ── 로그아웃 ─────────────────────────────────────────────
  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('로그아웃',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: Text(
          '${widget.session.academyName} 계정에서 로그아웃하시겠습니까?',
          style:
              TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('취소', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('로그아웃',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await AuthService.logout();
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ── [TEST ONLY] 배포 시 floatingActionButton 두 줄 삭제 ─
      floatingActionButton: _MockTagButton(onTap: _mockTagTap),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: [
          // ── 70 / 30 분할 메인 레이아웃 ───────────────────
          Row(
            children: [
              Expanded(flex: 7, child: const _LeftPanel()),
              Expanded(
                flex: 3,
                child: _RightPanel(
                  session: widget.session,
                  localRecords: _testLocalRecords,
                ),
              ),
            ],
          ),

          // ── 피드백 오버레이 (애니메이션) ─────────────────
          if (_feedback != null)
            FadeTransition(
              opacity: _overlayOpacity,
              child: Container(
                color: Colors.black.withValues(alpha: 0.55),
                child: Center(
                  child: ScaleTransition(
                    scale: _cardScale,
                    child: _FeedbackCard(feedback: _feedback!),
                  ),
                ),
              ),
            ),

          // ── 우상단 로그아웃 ───────────────────────────────
          Positioned(
            top: 12,
            right: 14,
            child: GestureDetector(
              onTap: _confirmLogout,
              child: Row(
                children: [
                  Text(
                    widget.session.academyName,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0x66FFFFFF)),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.logout_rounded,
                      size: 15, color: Color(0x44FFFFFF)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// 좌측 패널 (70%) — Blob 배경 + 안내 문구
// ══════════════════════════════════════════════════════════
class _LeftPanel extends StatelessWidget {
  const _LeftPanel();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 베이스 색상
        ColoredBox(color: const Color(0xFFE7DAFF).withValues(alpha: 0.92)),

        // Blob 레이어 (ImageFiltered blur)
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 65, sigmaY: 65),
          child: CustomPaint(
            painter: _BlobPainter(),
            child: const SizedBox.expand(),
          ),
        ),

        // 콘텐츠
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 안내 문구
              const Text(
                '스티커를 리더기에 대주세요',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: 0.5,
                  shadows: [
                    Shadow(
                      color: Color(0x44000000),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),

              // NFC 카드 + 손 아이콘 (심플 조합)
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35),
                          width: 1.5),
                    ),
                  ),
                  const Icon(Icons.contactless_rounded,
                      size: 52, color: Colors.white),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'NFC 카드 또는 스티커를 단말기에 가까이 가져다 대주세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  color: Color(0xFF424242),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Blob CustomPainter ────────────────────────────────────
class _BlobPainter extends CustomPainter {
  const _BlobPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final blobs = [
      (Offset(size.width * 0.12, size.height * 0.20), 160.0, const Color(0xFFCDB4DB)),
      (Offset(size.width * 0.55, size.height * 0.12), 140.0, const Color(0xFFFFC8DD)),
      (Offset(size.width * 0.30, size.height * 0.78), 150.0, const Color(0xFFBDE0FE)),
      (Offset(size.width * 0.82, size.height * 0.60), 120.0, const Color(0xFFA2D2FF)),
      (Offset(size.width * 0.08, size.height * 0.72), 110.0, const Color(0xFFFFAFCC)),
      (Offset(size.width * 0.72, size.height * 0.28), 130.0, const Color(0xFFE2CFFF)),
      (Offset(size.width * 0.48, size.height * 0.50), 100.0, const Color(0xFFC9F0FF)),
      (Offset(size.width * 0.90, size.height * 0.15), 90.0, const Color(0xFFFFC8DD)),
    ];

    for (final (offset, radius, color) in blobs) {
      canvas.drawCircle(
        offset,
        radius,
        Paint()..color = color.withValues(alpha: 0.82),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ══════════════════════════════════════════════════════════
// 우측 패널 (30%) — 로고 + 최근 등원 현황
// ══════════════════════════════════════════════════════════
class _RightPanel extends StatelessWidget {
  final AcademySession session;
  final List<Map<String, dynamic>> localRecords;
  const _RightPanel({required this.session, this.localRecords = const []});

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final todayLabel =
        DateFormat('yyyy.MM.dd (E)', 'ko').format(DateTime.now());

    return Container(
      color: const Color(0xFFF8F9FA),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 로고 헤더 ───────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              border: Border(
                bottom: BorderSide(
                    color: Colors.black.withValues(alpha: 0.07)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // "HakwonS Check In" 텍스트 로고
                Align(
                  alignment: Alignment.centerRight,
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF4A5EFF), Color(0xFF5A3BD9)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ).createShader(bounds),
                    child: const Text(
                      'HakwonS Check In',
                      style: TextStyle(
                        fontFamily: 'Pacifico',
                        fontSize: 19,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 타이틀 + 날짜
                const Text(
                  '최근 등원 현황',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2D2D2D),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  todayLabel,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF212121)),
                ),
              ],
            ),
          ),

          // ── 출결 리스트 (로컬 우선, 없으면 Firestore) ────
          Expanded(
            child: localRecords.isNotEmpty
                ? _LocalList(records: localRecords)
                : StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('attendance')
                        .where('academyId', isEqualTo: session.academyId)
                        .where('date', isEqualTo: today)
                        .orderBy('timestamp', descending: true)
                        .limit(5)
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError ||
                          (snapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !snapshot.hasData)) {
                        return _EmptyList();
                      }
                      final docs = snapshot.data?.docs ?? [];
                      if (docs.isEmpty) return _EmptyList();
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: Colors.black.withValues(alpha: 0.05),
                          indent: 18,
                          endIndent: 18,
                        ),
                        itemBuilder: (_, i) {
                          final data =
                              docs[i].data() as Map<String, dynamic>;
                          final ts = data['timestamp'] as Timestamp?;
                          final time = ts != null
                              ? DateFormat('HH:mm')
                                  .format(ts.toDate().toLocal())
                              : DateFormat('HH:mm').format(DateTime.now());
                          return _AttendanceItem(
                            name: data['studentName'] as String? ?? '',
                            time: time,
                            isArrival:
                                (data['type'] as String?) == 'arrival',
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── [TEST ONLY] 로컬 리스트 위젯 — 배포 시 삭제 ─────────
class _LocalList extends StatelessWidget {
  final List<Map<String, dynamic>> records;
  const _LocalList({required this.records});

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return _EmptyList();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: records.length.clamp(0, 5),
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: Colors.black.withValues(alpha: 0.05),
        indent: 18,
        endIndent: 18,
      ),
      itemBuilder: (_, i) => _AttendanceItem(
        name: records[i]['name'] as String,
        time: records[i]['time'] as String,
        isArrival: records[i]['isArrival'] as bool,
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded,
                size: 40,
                color: const Color(0xFF2D2D2D).withValues(alpha: 0.18)),
            const SizedBox(height: 10),
            Text(
              '아직 기록이 없습니다.',
              style: TextStyle(
                  fontSize: 13,
                  color: const Color(0xFF2D2D2D).withValues(alpha: 0.35)),
            ),
          ],
        ),
      );
}

class _AttendanceItem extends StatelessWidget {
  final String name;
  final String time;
  final bool isArrival;

  const _AttendanceItem({
    required this.name,
    required this.time,
    required this.isArrival,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isArrival
        ? const Color(0xFF4CAF50)
        : const Color(0xFFFF9800);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: accent.withValues(alpha: 0.13),
            child: Text(
              name.isNotEmpty ? name[0] : '?',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isArrival ? '등원' : '하원',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: accent),
                  ),
                ),
              ],
            ),
          ),
          Text(
            time,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF999999)),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// 피드백 카드 (오버레이 위에 표시)
// ══════════════════════════════════════════════════════════
class _FeedbackCard extends StatelessWidget {
  final _Feedback feedback;
  const _FeedbackCard({required this.feedback});

  @override
  Widget build(BuildContext context) {
    return switch (feedback.kind) {
      _FeedbackKind.success => _SuccessCard(
          name: feedback.studentName ?? '',
          isArrival: feedback.attendanceType == AttendanceType.arrival,
        ),
      _FeedbackKind.duplicate => _DuplicateCard(
          name: feedback.studentName ?? '',
        ),
      _FeedbackKind.unknown || _FeedbackKind.error => _AlertCard(
          message: feedback.message ?? '오류가 발생했습니다.',
          isError: feedback.kind == _FeedbackKind.error,
        ),
    };
  }
}

// ── 등원/하원 성공 ────────────────────────────────────────
class _SuccessCard extends StatelessWidget {
  final String name;
  final bool isArrival;
  const _SuccessCard({required this.name, required this.isArrival});

  @override
  Widget build(BuildContext context) {
    final accent =
        isArrival ? const Color(0xFF4CAF50) : const Color(0xFFFF9800);
    final bg = isArrival
        ? const Color(0xFF1B2E1B)
        : const Color(0xFF2E1F0A);

    return Container(
      width: 340,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: accent.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isArrival ? Icons.login_rounded : Icons.logout_rounded,
            size: 60,
            color: accent,
          ),
          const SizedBox(height: 18),
          Text(
            '$name 학생',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${isArrival ? '등원' : '하원'} 완료',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 20분 중복 ────────────────────────────────────────────
class _DuplicateCard extends StatelessWidget {
  final String name;
  const _DuplicateCard({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2200).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
            color: Colors.amber.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined,
              size: 56, color: Colors.amber.shade300),
          const SizedBox(height: 18),
          Text(
            name,
            style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white),
          ),
          const SizedBox(height: 10),
          Text(
            '이미 기록되었습니다.',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.amber.shade300),
          ),
          const SizedBox(height: 6),
          Text(
            '20분 이내 중복 태깅은 기록되지 않습니다.',
            style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }
}

// ── 오류 / 미등록 ─────────────────────────────────────────
class _AlertCard extends StatelessWidget {
  final String message;
  final bool isError;
  const _AlertCard({required this.message, required this.isError});

  @override
  Widget build(BuildContext context) {
    final accent =
        isError ? Colors.redAccent.shade200 : Colors.orangeAccent;

    return Container(
      width: 340,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      decoration: BoxDecoration(
        color: const Color(0xFF200000).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border:
            Border.all(color: accent.withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 56, color: accent),
          const SizedBox(height: 18),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              color: Colors.white.withValues(alpha: 0.85),
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// [TEST ONLY] 가상 태깅 버튼 — 배포 시 이 클래스 전체 삭제
// ══════════════════════════════════════════════════════════
class _MockTagButton extends StatelessWidget {
  final VoidCallback onTap;
  const _MockTagButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.55,
      child: FloatingActionButton(
        onPressed: onTap,
        backgroundColor: Colors.black54,
        elevation: 2,
        mini: true,
        tooltip: '[TEST] 가상 NFC 태깅',
        child: const Icon(Icons.touch_app, color: Colors.white, size: 20),
      ),
    );
  }
}
