class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.longNumber,
    required this.shortNumber,
    required this.createdAt,
  });

  final String id;
  final String longNumber;
  final String shortNumber;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'longNumber': longNumber,
      'shortNumber': shortNumber,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory ScanRecord.fromJson(Map<String, dynamic> json) {
    return ScanRecord(
      id: json['id'] as String,
      longNumber: json['longNumber'] as String,
      shortNumber: json['shortNumber'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}
