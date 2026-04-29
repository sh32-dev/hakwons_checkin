import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/attendance_record.dart';
import '../models/student.dart';

sealed class AttendanceResult {}

class AttendanceSuccess extends AttendanceResult {
  final Student student;
  final AttendanceType type;
  AttendanceSuccess({required this.student, required this.type});
}

class AttendanceDuplicate extends AttendanceResult {
  final Student student;
  final AttendanceType lastType;
  AttendanceDuplicate({required this.student, required this.lastType});
}

class AttendanceUnknownCard extends AttendanceResult {
  final String uid;
  AttendanceUnknownCard({required this.uid});
}

class AttendanceError extends AttendanceResult {
  final String message;
  AttendanceError({required this.message});
}

class AttendanceService {
  static const _duplicateWindow = Duration(minutes: 20);
  static final _firestore = FirebaseFirestore.instance;
  static final _dateFormat = DateFormat('yyyy-MM-dd');

  static Future<AttendanceResult> processTag({
    required String attendanceCardId,
    required String academyId,
    required String actorRole,
  }) async {
    try {
      // 1. attendanceCardId + academyId로 학생 조회 (복합 인덱스 필요)
      final studentSnap = await _firestore
          .collection('students')
          .where('academyId', isEqualTo: academyId)
          .where('attendanceCardId', isEqualTo: attendanceCardId)
          .limit(1)
          .get();

      if (studentSnap.docs.isEmpty) {
        return AttendanceUnknownCard(uid: attendanceCardId);
      }

      final student = Student.fromFirestore(studentSnap.docs.first);

      // 2. 오늘 날짜의 마지막 출결 기록 조회
      final today = _dateFormat.format(DateTime.now());
      final attendanceSnap = await _firestore
          .collection('attendance')
          .where('academyId', isEqualTo: academyId)
          .where('studentId', isEqualTo: student.id)
          .where('date', isEqualTo: today)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();

      AttendanceType nextType;

      if (attendanceSnap.docs.isEmpty) {
        // 오늘 첫 태깅 → 등원
        nextType = AttendanceType.arrival;
      } else {
        final last = AttendanceRecord.fromFirestore(attendanceSnap.docs.first);
        final elapsed = DateTime.now().difference(last.timestamp);

        // 20분 이내 재태깅 → 중복 무시
        if (elapsed < _duplicateWindow) {
          return AttendanceDuplicate(student: student, lastType: last.type);
        }

        // 이전 기록의 반대로 토글
        nextType = last.type == AttendanceType.arrival
            ? AttendanceType.departure
            : AttendanceType.arrival;
      }

      // 3. 출결 기록 저장
      await _firestore.collection('attendance').add({
        'studentId': student.id,
        'studentName': student.name,
        'academyId': academyId,
        'type': nextType == AttendanceType.arrival ? 'arrival' : 'departure',
        'status': nextType == AttendanceType.arrival ? 'present' : 'departed',
        'lastEditedByRole': actorRole == 'teacher' ? 'teacher' : 'director',
        'editedByAdmin': false,
        'source': 'checkin_app',
        'timestamp': FieldValue.serverTimestamp(),
        'date': today,
      });

      return AttendanceSuccess(student: student, type: nextType);
    } catch (e) {
      return AttendanceError(message: e.toString());
    }
  }
}
