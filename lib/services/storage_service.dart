import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/scan_record.dart';

class StorageService {
  static const _recordsKey = 'scan_number_records_v1';

  Future<List<ScanRecord>> loadRecords() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_recordsKey);

    if (raw == null || raw.isEmpty) {
      return [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (item) => ScanRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRecords(List<ScanRecord> records) async {
    final preferences = await SharedPreferences.getInstance();
    final payload = jsonEncode(
      records.map((record) => record.toJson()).toList(),
    );
    await preferences.setString(_recordsKey, payload);
  }

  Future<void> clearRecords() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_recordsKey);
  }
}
