import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scan_record.dart';

class ExcelExportService {
  Future<File> createExcelFile(List<ScanRecord> records) async {
    final excel = Excel.createExcel();
    const sheetName = 'البطاقات';

    final sheet = excel[sheetName];

    sheet.appendRow([
      TextCellValue('الرقم الطويل'),
      TextCellValue('الرقم القصير'),
    ]);

    for (final record in records) {
      sheet.appendRow([
        TextCellValue(record.longNumber),
        TextCellValue(record.shortNumber),
      ]);
    }

    if (excel.tables.containsKey('Sheet1') && excel.tables.length > 1) {
      excel.delete('Sheet1');
    }
    excel.setDefaultSheet(sheetName);

    final bytes = excel.save();
    if (bytes == null) {
      throw StateError('تعذر إنشاء ملف Excel');
    }

    final directory = await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final fileName =
        'scan_numbers_${_two(now.year % 100)}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.xlsx';

    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> shareFile(File file) async {
    await SharePlus.instance.share(
      ShareParams(
        title: 'تصدير أرقام البطاقات',
        text: 'ملف Excel يحتوي على جميع البطاقات الممسوحة.',
        files: [XFile(file.path)],
      ),
    );
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}
