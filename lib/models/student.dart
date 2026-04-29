import 'package:cloud_firestore/cloud_firestore.dart';

class Student {
  final String id;
  final String name;
  final String attendanceCardId;
  final String? grade;

  const Student({
    required this.id,
    required this.name,
    required this.attendanceCardId,
    this.grade,
  });

  factory Student.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Student(
      id: doc.id,
      name: data['name'] as String? ?? '이름 없음',
      attendanceCardId: data['attendanceCardId'] as String? ?? '',
      grade: data['grade'] as String?,
    );
  }
}
