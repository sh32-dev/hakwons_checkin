import 'package:cloud_firestore/cloud_firestore.dart';

class Student {
  final String id;
  final String name;
  final String attendanceCardId;
  final String? grade;
  final String? classId;
  final String? className;

  const Student({
    required this.id,
    required this.name,
    required this.attendanceCardId,
    this.grade,
    this.classId,
    this.className,
  });

  factory Student.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return Student(
      id: doc.id,
      name: data['name'] as String? ?? '이름 없음',
      attendanceCardId: data['attendanceCardId'] as String? ?? '',
      grade: data['grade'] as String?,
      classId: data['classId'] as String?,
    );
  }

  Student copyWith({
    String? id,
    String? name,
    String? attendanceCardId,
    String? grade,
    String? classId,
    String? className,
  }) {
    return Student(
      id: id ?? this.id,
      name: name ?? this.name,
      attendanceCardId: attendanceCardId ?? this.attendanceCardId,
      grade: grade ?? this.grade,
      classId: classId ?? this.classId,
      className: className ?? this.className,
    );
  }
}
