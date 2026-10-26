import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scan_number/models/scan_record.dart';
import 'package:scan_number/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ScanRecord record(String id, String longNumber, String shortNumber) {
    return ScanRecord(
      id: id,
      longNumber: longNumber,
      shortNumber: shortNumber,
      createdAt: DateTime(2026, 1, 1),
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new scans accumulate and survive reopening the scanner', () async {
    final firstSession = StorageService();
    await firstSession.addRecord(record('1', '00436434838', '228790'));
    await firstSession.addRecord(record('2', '00436434839', '228791'));

    // A fresh scanner instance must append to the previous session's cards.
    final nextSession = StorageService();
    await nextSession.addRecord(record('3', '00436434840', '000123'));

    final saved = await StorageService().loadRecords();
    expect(saved.map((item) => item.id), ['3', '2', '1']);
    expect(saved.last.longNumber, '00436434838');
    expect(saved.first.shortNumber, '000123');
  });

  test(
    'repeated scans of the same card do not replace or duplicate it',
    () async {
      final storage = StorageService();
      await storage.addRecord(record('1', '00436434838', '228790'));
      await storage.addRecord(record('2', '00436434839', '228791'));

      final saved = await storage.addRecord(
        record('3', '00436434838', '999999'),
      );

      expect(saved, hasLength(2));
      expect(saved.last.id, '1');
      expect(saved.last.shortNumber, '228790');
      expect((await storage.loadRecords()).map((item) => item.id), ['2', '1']);
    },
  );
}
