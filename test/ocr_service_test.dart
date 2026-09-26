import 'package:flutter_test/flutter_test.dart';
import 'package:scan_number/services/ocr_service.dart';

void main() {
  group('OcrService.extractFromRawText', () {
    test('extracts the expected long and short card numbers', () {
      const text = '''
200
228790
00436434838
30
''';

      final result = OcrService.extractFromRawText(text);

      expect(result.longNumber, '00436434838');
      expect(result.shortNumber, '228790');
    });

    test('handles Arabic-Indic digits', () {
      const text = '''
٢٢٨٧٩٠
٠٠٤٣٦٤٣٤٨٣٨
''';

      final result = OcrService.extractFromRawText(text);

      expect(result.longNumber, '00436434838');
      expect(result.shortNumber, '228790');
    });

    test('corrects common OCR character mistakes', () {
      const text = '''
22879O
0043643483B
''';

      final result = OcrService.extractFromRawText(text);

      expect(result.longNumber, '00436434838');
      expect(result.shortNumber, '228790');
    });
  });
}
