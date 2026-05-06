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

class AttendanceCompleted extends AttendanceResult {
  final Student student;
  AttendanceCompleted({required this.student});
}

class AttendanceUnknownCard extends AttendanceResult {
  final String uid;
  AttendanceUnknownCard({required this.uid});
}

class AttendanceError extends AttendanceResult {
  final String message;
  AttendanceError({required this.message});
}

sealed class AttendancePolicyDecision {
  const AttendancePolicyDecision();
}

class AttendancePolicyRecord extends AttendancePolicyDecision {
  final AttendanceType type;
  const AttendancePolicyRecord(this.type);
}

class AttendancePolicyDuplicate extends AttendancePolicyDecision {
  final AttendanceType lastType;
  const AttendancePolicyDuplicate(this.lastType);
}

class AttendancePolicyCompleted extends AttendancePolicyDecision {
  const AttendancePolicyCompleted();
}

class AttendanceService {
  static const _duplicateWindow = Duration(minutes: 20);
  static const _firestoreTimeout = Duration(seconds: 10);
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
          .get()
          .timeout(_firestoreTimeout);

      if (studentSnap.docs.isEmpty) {
        return AttendanceUnknownCard(uid: attendanceCardId);
      }

      final student = await _withClassName(
        Student.fromFirestore(studentSnap.docs.first),
        academyId,
      );

      // 2. 오늘 날짜의 출결 기록 조회
      final today = _dateFormat.format(DateTime.now());
      final attendanceSnap = await _firestore
          .collection('attendance')
          .where('academyId', isEqualTo: academyId)
          .where('studentId', isEqualTo: student.id)
          .where('date', isEqualTo: today)
          .orderBy('timestamp', descending: true)
          .get()
          .timeout(_firestoreTimeout);

      AttendanceType nextType;

      if (attendanceSnap.docs.isEmpty) {
        // 오늘 첫 태깅 → 등원
        nextType = AttendanceType.arrival;
      } else {
        final records = attendanceSnap.docs
            .map(AttendanceRecord.fromFirestore)
            .toList(growable: false);

        switch (decideNextAttendance(records)) {
          case AttendancePolicyRecord(:final type):
            nextType = type;
          case AttendancePolicyDuplicate(:final lastType):
            return AttendanceDuplicate(student: student, lastType: lastType);
          case AttendancePolicyCompleted():
            return AttendanceCompleted(student: student);
        }
      }

      // 3. 출결 기록 저장
      await _firestore
          .collection('attendance')
          .add({
            'studentId': student.id,
            'studentName': student.name,
            if (_hasText(student.className))
              'studentClassName': student.className,
            'academyId': academyId,
            'type': nextType == AttendanceType.arrival
                ? 'arrival'
                : 'departure',
            'status': nextType == AttendanceType.arrival
                ? 'present'
                : 'departed',
            'lastEditedByRole': actorRole == 'teacher' ? 'teacher' : 'director',
            'editedByAdmin': false,
            'source': 'checkin_app',
            'timestamp': FieldValue.serverTimestamp(),
            'date': today,
          })
          .timeout(_firestoreTimeout);

      return AttendanceSuccess(student: student, type: nextType);
    } catch (e) {
      return AttendanceError(message: e.toString());
    }
  }

  static AttendancePolicyDecision decideNextAttendance(
    List<AttendanceRecord> records, {
    DateTime? now,
  }) {
    if (records.isEmpty) {
      return const AttendancePolicyRecord(AttendanceType.arrival);
    }

    final orderedRecords = [...records]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final last = orderedRecords.first;
    final hasDeparture = orderedRecords.any(
      (record) => record.type == AttendanceType.departure,
    );

    if (hasDeparture || last.type == AttendanceType.departure) {
      return const AttendancePolicyCompleted();
    }

    final elapsed = (now ?? DateTime.now()).difference(last.timestamp);
    if (elapsed < _duplicateWindow) {
      return AttendancePolicyDuplicate(last.type);
    }

    return const AttendancePolicyRecord(AttendanceType.departure);
  }

  static Future<Student> _withClassName(
    Student student,
    String academyId,
  ) async {
    final classId = student.classId?.trim();
    if (!_hasText(classId)) return student;

    try {
      final classDoc = await _firestore
          .collection('academies')
          .doc(academyId)
          .collection('classes')
          .doc(classId)
          .get()
          .timeout(_firestoreTimeout);
      final className = classDoc.data()?['name'] as String?;
      if (!_hasText(className)) return student;
      return student.copyWith(className: className!.trim());
    } catch (_) {
      return student;
    }
  }

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;
}
