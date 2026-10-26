import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scan_number/models/scan_record.dart';
import 'package:scan_number/services/text_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = TextExportService();
  final records = [
    ScanRecord(
      id: '1',
      longNumber: '00436434838',
      shortNumber: '228790',
      createdAt: DateTime(2026, 1, 1),
    ),
    ScanRecord(
      id: '2',
      longNumber: '00436434839',
      shortNumber: '000123',
      createdAt: DateTime(2026, 1, 1),
    ),
  ];

  test('text export keeps every card on its own line and preserves zeros', () {
    expect(
      service.formatRecords(records),
      'الرقم الطويل\tالرقم القصير\r\n'
      '00436434838\t228790\r\n'
      '00436434839\t000123\r\n',
    );
  });

  test(
    'writes a readable UTF-8 text file without modifying the batch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'scan_number_test_',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return directory.path;
        }
        throw MissingPluginException();
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });

      final file = await service.createTextFile(records);
      final bytes = await file.readAsBytes();
      expect(file.path, endsWith('.txt'));
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(utf8.decode(bytes.sublist(3)), service.formatRecords(records));
      expect(records.map((record) => record.id), ['1', '2']);
    },
  );
}
