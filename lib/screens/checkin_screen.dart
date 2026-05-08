import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/academy_session.dart';
import '../models/attendance_record.dart';
import '../services/attendance_service.dart';
import '../services/auth_service.dart';
import '../services/usb_nfc_reader_service.dart';

enum _FeedbackKind { success, duplicate, completed, unknown, error }

final Map<String, Future<String?>> _studentClassNameFutures = {};

class _Feedback {
  final _FeedbackKind kind;
  final String? studentName;
  final String? studentClassName;
  final AttendanceType? attendanceType;
  final String? message;

  const _Feedback({
    required this.kind,
    this.studentName,
    this.studentClassName,
    this.attendanceType,
    this.message,
  });
}

class _RecentAttendance {
  final _FeedbackKind kind;
  final String studentName;
  final String? studentClassName;
  final AttendanceType? attendanceType;
  final DateTime expiresAt;

  const _RecentAttendance({
    required this.kind,
    required this.studentName,
    required this.studentClassName,
    required this.attendanceType,
    required this.expiresAt,
  });
}

String _formatStudentDisplayName(String name, String? className) {
  final trimmedName = name.trim();
  final trimmedClassName = className?.trim();
  if (trimmedClassName == null || trimmedClassName.isEmpty) {
    return trimmedName;
  }
  return '$trimmedName ($trimmedClassName)';
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

String _redactedCardIdLabel(String cardId) => 'len=${cardId.length}';

Future<String?> _fetchStudentClassName({
  required String academyId,
  required String studentId,
}) {
  final cacheKey = '$academyId/$studentId';
  return _studentClassNameFutures.putIfAbsent(cacheKey, () async {
    try {
      final firestore = FirebaseFirestore.instance;
      final studentDoc = await firestore
          .collection('students')
          .doc(studentId)
          .get();
      final classId = studentDoc.data()?['classId'] as String?;
      if (!_hasText(classId)) return null;

      final classDoc = await firestore
          .collection('academies')
          .doc(academyId)
          .collection('classes')
          .doc(classId!.trim())
          .get();
      final className = classDoc.data()?['name'] as String?;
      if (!_hasText(className)) return null;
      return className!.trim();
    } catch (_) {
      return null;
    }
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
  static const _localDuplicateWindow = Duration(minutes: 20);

  // 피드백 오버레이 애니메이션
  late final AnimationController _overlayCtrl;
  late final Animation<double> _overlayOpacity;
  late final Animation<double> _cardScale;

  bool _isProcessing = false;
  bool _isSavingAttendance = false;
  String? _processingCardId;
  _Feedback? _feedback;
  Timer? _dismissTimer;
  StreamSubscription<UsbNfcReaderEvent>? _readerSubscription;
  final Queue<String> _cardQueue = Queue<String>();
  final Map<String, _RecentAttendance> _recentAttendanceByCardId = {};

  @override
  void initState() {
    super.initState();
    _overlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _overlayOpacity = CurvedAnimation(
      parent: _overlayCtrl,
      curve: Curves.easeOut,
    );
    _cardScale = Tween<double>(
      begin: 0.82,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeOutBack));
    unawaited(_configureCrashlyticsContext());
    _startUsbReader();
  }

  @override
  void dispose() {
    _logCrashlytics('checkin_screen_disposed', {
      'screen': 'none',
      'usb_reader_state': 'stopping',
    });
    _overlayCtrl.dispose();
    _dismissTimer?.cancel();
    _readerSubscription?.cancel();
    unawaited(UsbNfcReaderService.stop());
    super.dispose();
  }

  Future<void> _configureCrashlyticsContext() async {
    final crashlytics = FirebaseCrashlytics.instance;
    await crashlytics.setUserIdentifier(widget.session.academyId);
    await crashlytics.setCustomKey('screen', 'checkin');
    await crashlytics.setCustomKey('academy_id', widget.session.academyId);
    await crashlytics.setCustomKey('actor_role', widget.session.actorRole);
    await crashlytics.setCustomKey('usb_reader_state', 'initializing');
    await crashlytics.setCustomKey('pending_queue_count', 0);
    await crashlytics.log('checkin_screen_opened');
  }

  void _setCrashlyticsKeys(Map<String, Object> keys) {
    final crashlytics = FirebaseCrashlytics.instance;
    for (final entry in keys.entries) {
      unawaited(crashlytics.setCustomKey(entry.key, entry.value));
    }
  }

  void _logCrashlytics(String message, [Map<String, Object> keys = const {}]) {
    unawaited(FirebaseCrashlytics.instance.log(message));
    if (keys.isNotEmpty) {
      _setCrashlyticsKeys(keys);
    }
  }

  String _attendanceResultName(AttendanceResult result) => switch (result) {
    AttendanceSuccess() => 'success',
    AttendanceDuplicate() => 'duplicate',
    AttendanceCompleted() => 'completed',
    AttendanceUnknownCard() => 'unknown_card',
    AttendanceError() => 'error',
  };

  void _logAttendanceResult(AttendanceResult result) {
    final keys = <String, Object>{
      'last_attendance_result': _attendanceResultName(result),
      'pending_queue_count': _cardQueue.length,
    };

    switch (result) {
      case AttendanceSuccess(:final type):
        keys['last_attendance_type'] = type.name;
      case AttendanceDuplicate(:final lastType):
        keys['last_attendance_type'] = lastType.name;
      case AttendanceCompleted():
        keys['last_attendance_type'] = 'completed';
      case AttendanceUnknownCard():
        keys['last_attendance_type'] = 'unknown';
      case AttendanceError():
        keys['last_attendance_type'] = 'error';
    }

    _logCrashlytics(
      'attendance_result_${keys['last_attendance_result']}',
      keys,
    );
  }

  // ── ACR122U USB 리더기 ───────────────────────────────────
  Future<void> _startUsbReader() async {
    _logCrashlytics('usb_reader_start_requested', {
      'usb_reader_state': 'starting',
    });
    _readerSubscription = UsbNfcReaderService.events().listen(
      _handleReaderEvent,
      onError: (_) {
        _logCrashlytics('usb_reader_stream_error', {
          'usb_reader_state': 'stream_error',
        });
        _showFeedback(
          const _Feedback(
            kind: _FeedbackKind.error,
            message: 'USB 리더기 연결을 확인해주세요.',
          ),
        );
      },
    );

    try {
      await UsbNfcReaderService.start();
      _logCrashlytics('usb_reader_started', {'usb_reader_state': 'started'});
    } catch (_) {
      _logCrashlytics('usb_reader_start_failed', {
        'usb_reader_state': 'start_failed',
      });
      _showFeedback(
        const _Feedback(
          kind: _FeedbackKind.error,
          message: 'USB 리더기를 시작하지 못했습니다.\n연결과 권한을 확인해주세요.',
        ),
      );
    }
  }

  void _handleReaderEvent(UsbNfcReaderEvent event) {
    switch (event) {
      case UsbNfcReaderUid(:final uid):
        _logCrashlytics('nfc_uid_received', {
          'last_reader_event': 'uid',
          'last_card_id_length': uid.length,
        });
        _onReaderUid(uid);
      case UsbNfcReaderError(:final message):
        _logCrashlytics('usb_reader_event_error', {
          'last_reader_event': 'error',
          'usb_reader_state': 'event_error',
        });
        _showFeedback(_Feedback(kind: _FeedbackKind.error, message: message));
      case UsbNfcReaderStatus(:final message):
        developer.log(message, name: 'UsbNfcReader');
        _setCrashlyticsKeys({'last_reader_event': 'status'});
        if (message.contains('권한')) {
          _logCrashlytics('usb_reader_permission_required', {
            'usb_reader_state': 'permission_required',
          });
          _showFeedback(_Feedback(kind: _FeedbackKind.error, message: message));
        }
    }
  }

  Future<void> _onReaderUid(String uid) async {
    final cardId = uid;
    if (cardId.isEmpty) {
      _logCrashlytics('nfc_empty_card_id', {
        'last_attendance_result': 'empty_card_id',
      });
      _showFeedback(
        const _Feedback(
          kind: _FeedbackKind.error,
          message: '카드 일련번호를 읽지 못했습니다.\n카드를 리더기에 다시 태그해주세요.',
        ),
      );
      return;
    }

    if (_showCachedResultIfRecent(cardId)) return;

    _cardQueue.add(cardId);
    developer.log(
      'queued cardId=${_redactedCardIdLabel(cardId)} queue=${_cardQueue.length}',
      name: 'CheckinQueue',
    );
    _logCrashlytics('attendance_card_queued', {
      'pending_queue_count': _cardQueue.length,
    });
    unawaited(_drainQueue());
  }

  Future<void> _drainQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _logCrashlytics('attendance_queue_processing_started', {
      'is_processing': true,
      'pending_queue_count': _cardQueue.length,
    });

    while (mounted && _cardQueue.isNotEmpty) {
      final cardId = _cardQueue.removeFirst();
      if (_showCachedResultIfRecent(cardId)) continue;

      developer.log(
        'processing cardId=${_redactedCardIdLabel(cardId)}',
        name: 'CheckinQueue',
      );
      setState(() {
        _isSavingAttendance = true;
        _processingCardId = cardId;
      });
      _logCrashlytics('attendance_process_started', {
        'is_saving_attendance': true,
        'pending_queue_count': _cardQueue.length,
      });

      final result = await AttendanceService.processTag(
        attendanceCardId: cardId,
        academyId: widget.session.academyId,
        actorRole: widget.session.actorRole,
      );

      if (!mounted) return;
      setState(() {
        _isSavingAttendance = false;
        _processingCardId = null;
      });
      developer.log(
        'processed cardId=${_redactedCardIdLabel(cardId)} '
        'result=${result.runtimeType}',
        name: 'CheckinQueue',
      );
      _logAttendanceResult(result);
      _showAttendanceResult(cardId, result);
    }

    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _isSavingAttendance = false;
      _processingCardId = null;
    });
    _logCrashlytics('attendance_queue_processing_finished', {
      'is_processing': false,
      'is_saving_attendance': false,
      'pending_queue_count': 0,
    });
  }

  bool _showCachedResultIfRecent(String cardId) {
    final recent = _recentAttendanceByCardId[cardId];
    if (recent == null) return false;

    if (!DateTime.now().isBefore(recent.expiresAt)) {
      _recentAttendanceByCardId.remove(cardId);
      return false;
    }

    developer.log(
      'local cached result cardId=${_redactedCardIdLabel(cardId)}',
      name: 'CheckinQueue',
    );
    _logCrashlytics('attendance_recent_cache_hit', {
      'last_attendance_result': 'recent_cache_hit',
      'pending_queue_count': _cardQueue.length,
    });
    _showFeedback(
      _Feedback(
        kind: recent.kind,
        studentName: recent.studentName,
        studentClassName: recent.studentClassName,
        attendanceType: recent.attendanceType,
      ),
    );
    return true;
  }

  void _rememberRecentTag({
    required String cardId,
    required _FeedbackKind kind,
    required String studentName,
    required String? studentClassName,
    required AttendanceType? attendanceType,
    required DateTime expiresAt,
  }) {
    _recentAttendanceByCardId[cardId] = _RecentAttendance(
      kind: kind,
      studentName: studentName,
      studentClassName: studentClassName,
      attendanceType: attendanceType,
      expiresAt: expiresAt,
    );
  }

  DateTime _endOfToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  void _showAttendanceResult(String cardId, AttendanceResult result) {
    switch (result) {
      case AttendanceSuccess(:final student, :final type):
        _rememberRecentTag(
          cardId: cardId,
          kind: type == AttendanceType.arrival
              ? _FeedbackKind.duplicate
              : _FeedbackKind.completed,
          studentName: student.name,
          studentClassName: student.className,
          attendanceType: type,
          expiresAt: type == AttendanceType.arrival
              ? DateTime.now().add(_localDuplicateWindow)
              : _endOfToday(),
        );
        _showFeedback(
          _Feedback(
            kind: _FeedbackKind.success,
            studentName: student.name,
            studentClassName: student.className,
            attendanceType: type,
          ),
        );
      case AttendanceDuplicate(:final student, :final lastType):
        _rememberRecentTag(
          cardId: cardId,
          kind: _FeedbackKind.duplicate,
          studentName: student.name,
          studentClassName: student.className,
          attendanceType: lastType,
          expiresAt: DateTime.now().add(_localDuplicateWindow),
        );
        _showFeedback(
          _Feedback(
            kind: _FeedbackKind.duplicate,
            studentName: student.name,
            studentClassName: student.className,
            attendanceType: lastType,
          ),
        );
      case AttendanceCompleted(:final student):
        _rememberRecentTag(
          cardId: cardId,
          kind: _FeedbackKind.completed,
          studentName: student.name,
          studentClassName: student.className,
          attendanceType: null,
          expiresAt: _endOfToday(),
        );
        _showFeedback(
          _Feedback(
            kind: _FeedbackKind.completed,
            studentName: student.name,
            studentClassName: student.className,
          ),
        );
      case AttendanceUnknownCard(:final uid):
        _showFeedback(
          _Feedback(
            kind: _FeedbackKind.unknown,
            message: '등록되지 않은 카드입니다.\n읽힌 카드 ID: $uid',
          ),
        );
      case AttendanceError(:final message):
        _showFeedback(_Feedback(kind: _FeedbackKind.error, message: message));
    }
  }

  // ── 피드백 오버레이 제어 ─────────────────────────────────
  void _showFeedback(_Feedback fb) {
    if (!mounted) return;
    setState(() => _feedback = fb);
    _overlayCtrl.forward(from: 0);

    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      _overlayCtrl.reverse().then((_) {
        if (mounted) {
          setState(() => _feedback = null);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '로그아웃',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          '${widget.session.academyName} 계정에서 로그아웃하시겠습니까?',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.65),
            fontSize: 14,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '로그아웃',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      _logCrashlytics('logout_confirmed', {'screen': 'logout'});
      await AuthService.logout();
      unawaited(FirebaseCrashlytics.instance.setUserIdentifier(''));
      if (mounted) Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── 70 / 30 분할 메인 레이아웃 ───────────────────
          Row(
            children: [
              Expanded(flex: 7, child: const _LeftPanel()),
              Expanded(flex: 3, child: _RightPanel(session: widget.session)),
            ],
          ),

          // ── Firebase 등록중 표시 (리더 이벤트는 계속 수신) ─────────
          if (_isSavingAttendance)
            _ProcessingOverlay(
              queuedCount: _cardQueue.length,
              cardId: _processingCardId,
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
                      fontSize: 11,
                      color: Color(0x66FFFFFF),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.logout_rounded,
                    size: 15,
                    color: Color(0x44FFFFFF),
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

              // NFC 카드 + 리더기 태그 안내 아이콘
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
                        width: 1.5,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.contactless_rounded,
                    size: 52,
                    color: Colors.white,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'NFC 카드 또는 스티커를 리더기에\n가까이 가져다 대주세요',
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
      (
        Offset(size.width * 0.12, size.height * 0.20),
        160.0,
        const Color(0xFFCDB4DB),
      ),
      (
        Offset(size.width * 0.55, size.height * 0.12),
        140.0,
        const Color(0xFFFFC8DD),
      ),
      (
        Offset(size.width * 0.30, size.height * 0.78),
        150.0,
        const Color(0xFFBDE0FE),
      ),
      (
        Offset(size.width * 0.82, size.height * 0.60),
        120.0,
        const Color(0xFFA2D2FF),
      ),
      (
        Offset(size.width * 0.08, size.height * 0.72),
        110.0,
        const Color(0xFFFFAFCC),
      ),
      (
        Offset(size.width * 0.72, size.height * 0.28),
        130.0,
        const Color(0xFFE2CFFF),
      ),
      (
        Offset(size.width * 0.48, size.height * 0.50),
        100.0,
        const Color(0xFFC9F0FF),
      ),
      (
        Offset(size.width * 0.90, size.height * 0.15),
        90.0,
        const Color(0xFFFFC8DD),
      ),
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
  const _RightPanel({required this.session});

  @override
  Widget build(BuildContext context) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final todayLabel = DateFormat(
      'yyyy.MM.dd (E)',
      'ko',
    ).format(DateTime.now());

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
                bottom: BorderSide(color: Colors.black.withValues(alpha: 0.07)),
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
                    fontSize: 13,
                    color: Color(0xFF212121),
                  ),
                ),
              ],
            ),
          ),

          // ── 출결 리스트 (로컬 우선, 없으면 Firestore) ────
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('attendance')
                  .where('academyId', isEqualTo: session.academyId)
                  .where('date', isEqualTo: today)
                  .orderBy('timestamp', descending: true)
                  .limit(5)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError ||
                    (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData)) {
                  return _EmptyList();
                }
                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) return _EmptyList();
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: docs.length,
                  separatorBuilder: (context, index) => Divider(
                    height: 1,
                    color: Colors.black.withValues(alpha: 0.05),
                    indent: 18,
                    endIndent: 18,
                  ),
                  itemBuilder: (_, i) {
                    final data = docs[i].data() as Map<String, dynamic>;
                    final ts = data['timestamp'] as Timestamp?;
                    final time = ts != null
                        ? DateFormat('HH:mm').format(ts.toDate().toLocal())
                        : DateFormat('HH:mm').format(DateTime.now());
                    return _AttendanceRecordItem(
                      data: data,
                      academyId: session.academyId,
                      time: time,
                      isArrival: (data['type'] as String?) == 'arrival',
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

class _AttendanceRecordItem extends StatelessWidget {
  final Map<String, dynamic> data;
  final String academyId;
  final String time;
  final bool isArrival;

  const _AttendanceRecordItem({
    required this.data,
    required this.academyId,
    required this.time,
    required this.isArrival,
  });

  @override
  Widget build(BuildContext context) {
    final studentName = data['studentName'] as String? ?? '';
    final savedClassName = data['studentClassName'] as String?;
    if (_hasText(savedClassName)) {
      return _AttendanceItem(
        name: _formatStudentDisplayName(studentName, savedClassName),
        time: time,
        isArrival: isArrival,
      );
    }

    final studentId = data['studentId'] as String?;
    if (!_hasText(studentId)) {
      return _AttendanceItem(
        name: studentName,
        time: time,
        isArrival: isArrival,
      );
    }

    return FutureBuilder<String?>(
      future: _fetchStudentClassName(
        academyId: academyId,
        studentId: studentId!.trim(),
      ),
      builder: (context, snapshot) {
        return _AttendanceItem(
          name: _formatStudentDisplayName(studentName, snapshot.data),
          time: time,
          isArrival: isArrival,
        );
      },
    );
  }
}

class _EmptyList extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.people_outline_rounded,
          size: 40,
          color: const Color(0xFF2D2D2D).withValues(alpha: 0.18),
        ),
        const SizedBox(height: 10),
        Text(
          '아직 기록이 없습니다.',
          style: TextStyle(
            fontSize: 13,
            color: const Color(0xFF2D2D2D).withValues(alpha: 0.35),
          ),
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
                color: accent,
              ),
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
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isArrival ? '등원' : '하원',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
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
              color: Color(0xFF999999),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// Firebase 등록중 딤 레이어
// ══════════════════════════════════════════════════════════
class _ProcessingOverlay extends StatelessWidget {
  final int queuedCount;
  final String? cardId;

  const _ProcessingOverlay({required this.queuedCount, required this.cardId});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.28),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 34),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF171722).withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '출결 등록 중',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        if (queuedCount > 0)
                          Text(
                            '대기 $queuedCount건',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.58),
                            ),
                          )
                        else if (cardId != null)
                          Text(
                            cardId!,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: 0.38),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
    final displayName = _formatStudentDisplayName(
      feedback.studentName ?? '',
      feedback.studentClassName,
    );

    return switch (feedback.kind) {
      _FeedbackKind.success => _SuccessCard(
        name: displayName,
        isArrival: feedback.attendanceType == AttendanceType.arrival,
      ),
      _FeedbackKind.duplicate => _DuplicateCard(name: displayName),
      _FeedbackKind.completed => _CompletedCard(name: displayName),
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
    final accent = isArrival
        ? const Color(0xFF4CAF50)
        : const Color(0xFFFF9800);
    final bg = isArrival ? const Color(0xFF1B2E1B) : const Color(0xFF2E1F0A);

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
          color: Colors.amber.withValues(alpha: 0.5),
          width: 1.5,
        ),
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
          Icon(Icons.timer_outlined, size: 56, color: Colors.amber.shade300),
          const SizedBox(height: 18),
          Text(
            name,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '이미 기록되었습니다.',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.amber.shade300,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '20분 이내 중복 태깅은 기록되지 않습니다.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 오늘 등·하원 완료 ───────────────────────────────────────
class _CompletedCard extends StatelessWidget {
  final String name;
  const _CompletedCard({required this.name});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF64B5F6);

    return Container(
      width: 340,
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 34),
      decoration: BoxDecoration(
        color: const Color(0xFF102133).withValues(alpha: 0.92),
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
          const Icon(Icons.task_alt_rounded, size: 58, color: accent),
          const SizedBox(height: 18),
          Text(
            name,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '오늘 등·하원 기록이 완료되었습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '추가 태깅은 기록되지 않습니다.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.45),
            ),
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
    final accent = isError ? Colors.redAccent.shade200 : Colors.orangeAccent;

    return Container(
      width: 340,
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      decoration: BoxDecoration(
        color: const Color(0xFF200000).withValues(alpha: 0.92),
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
