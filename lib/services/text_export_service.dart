import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';

class TextExportService {
  /// One card per line, with both numbers kept as text (including leading zeros).
  String formatRecords(List<ScanRecord> records) {
    final lines = [
      'الرقم الطويل\tالرقم القصير',
      ...records.map((record) => '${record.longNumber}\t${record.shortNumber}'),
    ];
    return '${lines.join('\r\n')}\r\n';
  }

  Future<File> createTextFile(List<ScanRecord> records) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(
      '${directory.path}/scan_numbers_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    // A UTF-8 BOM keeps the Arabic headings readable in Windows text editors.
    await file.writeAsBytes([
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(formatRecords(records)),
    ], flush: true);
    return file;
  }

  Future<void> shareFile(File file) async {
    await SharePlus.instance.share(
      ShareParams(
        title: 'تصدير أرقام البطاقات',
        text: 'ملف نصي يحتوي على جميع البطاقات الممسوحة.',
        files: [XFile(file.path, mimeType: 'text/plain')],
      ),
    );
  }
}
