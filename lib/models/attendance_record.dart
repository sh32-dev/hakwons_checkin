import 'package:cloud_firestore/cloud_firestore.dart';

enum AttendanceType { arrival, departure }

extension AttendanceTypeLabel on AttendanceType {
  String get label => this == AttendanceType.arrival ? '등원' : '하원';
}

class AttendanceRecord {
  final String id;
  final String studentId;
  final String studentName;
  final AttendanceType type;
  final DateTime timestamp;
  final String date;

  const AttendanceRecord({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.type,
    required this.timestamp,
    required this.date,
  });

  factory AttendanceRecord.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return AttendanceRecord(
      id: doc.id,
      studentId: data['studentId'] as String,
      studentName: data['studentName'] as String,
      type: data['type'] == 'arrival'
          ? AttendanceType.arrival
          : AttendanceType.departure,
      timestamp: (data['timestamp'] as Timestamp).toDate(),
      date: data['date'] as String,
    );
  }
}
