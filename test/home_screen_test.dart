import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scan_number/main.dart';
import 'package:scan_number/models/scan_record.dart';
import 'package:scan_number/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exports the accumulated list to TXT without clearing it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.addRecord(
      ScanRecord(
        id: '1',
        longNumber: '00436434838',
        shortNumber: '228790',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    await storage.addRecord(
      ScanRecord(
        id: '2',
        longNumber: '00436434839',
        shortNumber: '000123',
        createdAt: DateTime(2026, 1, 1),
      ),
    );

    final directory = Directory.systemTemp.createTempSync('scan_number_ui_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    Map<dynamic, dynamic>? shared;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      return directory.path;
    });
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared = call.arguments as Map<dynamic, dynamic>;
      return 'saved';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMethodCallHandler(shareChannel, null);
      directory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(const ScanNumberApp());
    await tester.pumpAndSettle();
    expect(find.text('00436434838'), findsOneWidget);
    expect(find.text('00436434839'), findsOneWidget);

    await tester.tap(find.text('تصدير 2 بطاقة إلى ملف نصي TXT'));
    // File I/O must finish outside the test's fake async clock.
    for (var attempt = 0; shared == null && attempt < 100; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(shared, isNotNull);
    final paths = (shared!['paths'] as List).cast<String>();
    expect(paths.single, endsWith('.txt'));
    expect(shared!['mimeTypes'], ['text/plain']);
    final text = await tester.runAsync(() => File(paths.single).readAsString());
    expect(text, contains('00436434838\t228790\r\n00436434839\t000123'));
    expect((await storage.loadRecords()).length, 2);
    expect(find.text('00436434838'), findsOneWidget);
    expect(find.text('00436434839'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
