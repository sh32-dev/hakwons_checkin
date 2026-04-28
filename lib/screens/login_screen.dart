import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/academy_session.dart';
import '../services/auth_service.dart';
import 'checkin_screen.dart';

const _kTestPhone = '01011111111';
const _kTestOtp = '123456';
const _kTestVerifId = '__test_mode__';

// 로컬 번들 폰트 상수
const _fontNotoKR = 'NotoSansKR';
const _fontPacifico = 'Pacifico';

enum _Step { phone, otp }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  _Step _step = _Step.phone;

  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  final _otpFocus = FocusNode();

  bool _loading = false;
  String? _error;
  String? _verificationId;
  bool _isTestMode = false;

  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    _phoneFocus.dispose();
    _otpFocus.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final digits = _phoneCtrl.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length < 10) {
      setState(() => _error = '올바른 전화번호를 입력해주세요.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    if (digits == _kTestPhone) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      setState(() {
        _isTestMode = true;
        _verificationId = _kTestVerifId;
        _step = _Step.otp;
        _loading = false;
      });
      _startCountdown();
      _otpFocus.requestFocus();
      return;
    }

    try {
      await AuthService.sendOtp(
        phoneNumber: _phoneCtrl.text,
        onCodeSent: (verificationId) {
          if (!mounted) return;
          setState(() {
            _isTestMode = false;
            _verificationId = verificationId;
            _step = _Step.otp;
            _loading = false;
          });
          _startCountdown();
          _otpFocus.requestFocus();
        },
        onError: (msg) {
          if (!mounted) return;
          setState(() {
            _error = msg;
            _loading = false;
          });
        },
        onAutoVerified: (session) {
          if (!mounted) return;
          _goToCheckin(session);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = '6자리 인증번호를 입력해주세요.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    if (_isTestMode) {
      if (code == _kTestOtp) {
        final session = await AuthService.createMockSession(
            _phoneCtrl.text.replaceAll(RegExp(r'[^\d]'), ''));
        if (mounted) _goToCheckin(session);
      } else {
        setState(() {
          _error = '인증번호가 올바르지 않습니다.';
          _loading = false;
        });
      }
      return;
    }

    try {
      final session = await AuthService.verifyOtp(
        verificationId: _verificationId!,
        smsCode: code,
        phoneNumber: _phoneCtrl.text,
      );
      if (mounted) _goToCheckin(session);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _error = AuthService.parseError(e);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdown = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _countdown--;
        if (_countdown <= 0) t.cancel();
      });
    });
  }

  void _resend() {
    _otpCtrl.clear();
    setState(() {
      _step = _Step.phone;
      _error = null;
      _isTestMode = false;
    });
    _sendOtp();
  }

  void _goToCheckin(AcademySession session) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => CheckinScreen(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Row(
        children: [
          const Expanded(flex: 35, child: _LeftPanel()),
          Expanded(
            flex: 65,
            child: Container(
              color: const Color(0xFFFAFAFA),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [const _GradientLogo()],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          child: _step == _Step.phone
                              ? _PhoneForm(
                                  key: const ValueKey('phone'),
                                  controller: _phoneCtrl,
                                  focusNode: _phoneFocus,
                                  loading: _loading,
                                  error: _error,
                                  onSend: _sendOtp,
                                )
                              : _OtpForm(
                                  key: const ValueKey('otp'),
                                  phone: _phoneCtrl.text,
                                  controller: _otpCtrl,
                                  focusNode: _otpFocus,
                                  loading: _loading,
                                  error: _error,
                                  countdown: _countdown,
                                  isTestMode: _isTestMode,
                                  onVerify: _verifyOtp,
                                  onResend: _resend,
                                  onChanged: (v) {
                                    if (v.length == 6) _verifyOtp();
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
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
// 좌측 패널: Blob 배경 + 브랜드
// ══════════════════════════════════════════════════════════
class _LeftPanel extends StatelessWidget {
  const _LeftPanel();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF9A8FD4)),
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 70, sigmaY: 70),
          child: CustomPaint(
            painter: _LoginBlobPainter(),
            child: const SizedBox.expand(),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '학원쓰 출결',
                style: TextStyle(
                  fontFamily: _fontNotoKR,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'NFC 출결 전용 키오스크',
                style: TextStyle(
                  fontFamily: _fontNotoKR,
                  fontSize: 13,
                  fontWeight: FontWeight.w300,
                  color: Color(0xFF212121),
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 24),
              Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const Icon(
                    Icons.contactless_rounded,
                    size: 42,
                    color: Colors.white,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoginBlobPainter extends CustomPainter {
  const _LoginBlobPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final blobs = [
      (Offset(size.width * 0.10, size.height * 0.15), 170.0, const Color(0xFFE7DAFF)),
      (Offset(size.width * 0.60, size.height * 0.10), 150.0, const Color(0xFFFFD1E8)),
      (Offset(size.width * 0.25, size.height * 0.80), 160.0, const Color(0xFFCCE8FF)),
      (Offset(size.width * 0.85, size.height * 0.65), 130.0, const Color(0xFFFFBBD6)),
      (Offset(size.width * 0.05, size.height * 0.65), 120.0, const Color(0xFFDEEFFF)),
      (Offset(size.width * 0.75, size.height * 0.30), 140.0, const Color(0xFFF0DEFF)),
      (Offset(size.width * 0.50, size.height * 0.48), 110.0, const Color(0xFFE7DAFF)),
      (Offset(size.width * 0.92, size.height * 0.10), 100.0, const Color(0xFFFFD1E8)),
    ];
    for (final (offset, radius, color) in blobs) {
      canvas.drawCircle(offset, radius, Paint()..color = color.withValues(alpha: 0.85));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ══════════════════════════════════════════════════════════
// "Hakwons Check In" 로고 (Pacifico + 그라디언트)
// ══════════════════════════════════════════════════════════
class _GradientLogo extends StatelessWidget {
  const _GradientLogo();

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        colors: [Color(0xFF4A5EFF), Color(0xFF5A3BD9)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(bounds),
      child: const Text(
        'Hakwons Check In',
        style: TextStyle(
          fontFamily: _fontPacifico,
          fontSize: 27,
          color: Colors.white,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// 1단계: 전화번호 입력
// ══════════════════════════════════════════════════════════
class _PhoneForm extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;
  final String? error;
  final VoidCallback onSend;

  const _PhoneForm({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.error,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '원장님, 안녕하세요 👋',
          style: TextStyle(
            fontFamily: _fontNotoKR,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '휴대폰번호로 로그인해주세요.',
          style: TextStyle(
            fontFamily: _fontNotoKR,
            fontSize: 13,
            fontWeight: FontWeight.w300,
            color: Color(0xFF212121),
          ),
        ),
        const SizedBox(height: 32),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.phone,
          inputFormatters: [_KoreanPhoneFormatter()],
          style: const TextStyle(
              fontSize: 17, color: Color(0xFF1A1A1A), fontWeight: FontWeight.w500),
          decoration: _deco('010-0000-0000'),
          onSubmitted: (_) => onSend(),
        ),
        if (error != null) ...[const SizedBox(height: 10), _ErrorRow(error!)],
        const SizedBox(height: 24),
        _PrimaryBtn(label: '인증번호 받기', loading: loading, onPressed: onSend),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════
// 2단계: OTP 입력
// ══════════════════════════════════════════════════════════
class _OtpForm extends StatelessWidget {
  final String phone;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool loading;
  final String? error;
  final int countdown;
  final bool isTestMode;
  final VoidCallback onVerify;
  final VoidCallback onResend;
  final ValueChanged<String> onChanged;

  const _OtpForm({
    super.key,
    required this.phone,
    required this.controller,
    required this.focusNode,
    required this.loading,
    required this.error,
    required this.countdown,
    required this.isTestMode,
    required this.onVerify,
    required this.onResend,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '인증번호를 입력해주세요',
          style: TextStyle(
            fontFamily: _fontNotoKR,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$phone 으로 문자를 보냈습니다.',
          style: TextStyle(
            fontFamily: _fontNotoKR,
            fontSize: 13,
            fontWeight: FontWeight.w300,
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 32),
        const _Label('인증번호 6자리'),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A1A),
            letterSpacing: 10,
          ),
          decoration: _deco('000000').copyWith(counterText: ''),
          onChanged: onChanged,
          onSubmitted: (_) => onVerify(),
        ),
        if (error != null) ...[const SizedBox(height: 10), _ErrorRow(error!)],
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (countdown > 0)
              Text(
                '$countdown초 후 재발송 가능',
                style: TextStyle(
                    fontSize: 12,
                    color: const Color(0xFF1A1A1A).withValues(alpha: 0.3)),
              )
            else
              GestureDetector(
                onTap: onResend,
                child: const Text(
                  '인증번호 다시 받기',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7B6CC4),
                    decoration: TextDecoration.underline,
                    decorationColor: Color(0xFF7B6CC4),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        _PrimaryBtn(label: '확인', loading: loading, onPressed: onVerify),
      ],
    );
  }
}

// ── 공통 위젯 ─────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            fontFamily: _fontNotoKR,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.5)),
      );
}

class _ErrorRow extends StatelessWidget {
  final String text;
  const _ErrorRow(this.text);

  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
          ),
        ],
      );
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback onPressed;
  const _PrimaryBtn(
      {required this.label, required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: loading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF7B6CC4),
            foregroundColor: Colors.white,
            disabledBackgroundColor:
                const Color(0xFF7B6CC4).withValues(alpha: 0.4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            elevation: 0,
          ),
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(label,
                  style: const TextStyle(
                      fontFamily: _fontNotoKR,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
        ),
      );
}

InputDecoration _deco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
          color: const Color(0xFF1A1A1A).withValues(alpha: 0.2), fontSize: 15),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFE8E8E8))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFE8E8E8))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF7B6CC4), width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.redAccent)),
    );

class _KoreanPhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) return newValue.copyWith(text: '');
    String formatted;
    if (digits.length <= 3) {
      formatted = digits;
    } else if (digits.length <= 7) {
      formatted = '${digits.substring(0, 3)}-${digits.substring(3)}';
    } else {
      final end = digits.length.clamp(0, 11);
      formatted =
          '${digits.substring(0, 3)}-${digits.substring(3, 7)}-${digits.substring(7, end)}';
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
