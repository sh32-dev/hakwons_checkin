import 'package:flutter_test/flutter_test.dart';
import 'package:hagwons_checkin/models/attendance_record.dart';
import 'package:hagwons_checkin/services/attendance_service.dart';

void main() {
  group('AttendanceService attendance policy', () {
    final now = DateTime(2026, 5, 6, 15);

    AttendanceRecord record(AttendanceType type, Duration ago) {
      return AttendanceRecord(
        id: '${type.name}-${ago.inMinutes}',
        studentId: 'student-1',
        studentName: '김학생',
        type: type,
        timestamp: now.subtract(ago),
        date: '2026-05-06',
      );
    }

    test('기록 없음 -> 등원 생성', () {
      final decision = AttendanceService.decideNextAttendance(
        const [],
        now: now,
      );

      expect(
        decision,
        isA<AttendancePolicyRecord>().having(
          (decision) => decision.type,
          'type',
          AttendanceType.arrival,
        ),
      );
    });

    test('등원 후 20분 이내 -> 중복', () {
      final decision = AttendanceService.decideNextAttendance([
        record(AttendanceType.arrival, const Duration(minutes: 19)),
      ], now: now);

      expect(
        decision,
        isA<AttendancePolicyDuplicate>().having(
          (decision) => decision.lastType,
          'lastType',
          AttendanceType.arrival,
        ),
      );
    });

    test('등원 후 20분 이상 -> 하원 생성', () {
      final decision = AttendanceService.decideNextAttendance([
        record(AttendanceType.arrival, const Duration(minutes: 20)),
      ], now: now);

      expect(
        decision,
        isA<AttendancePolicyRecord>().having(
          (decision) => decision.type,
          'type',
          AttendanceType.departure,
        ),
      );
    });

    test('등원+하원 후 재태깅 -> 완료 처리', () {
      final decision = AttendanceService.decideNextAttendance([
        record(AttendanceType.departure, const Duration(minutes: 1)),
        record(AttendanceType.arrival, const Duration(hours: 3)),
      ], now: now);

      expect(decision, isA<AttendancePolicyCompleted>());
    });
  });
}
