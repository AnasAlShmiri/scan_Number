import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class CardNumbersResult {
  const CardNumbersResult({
    required this.longNumber,
    required this.shortNumber,
    required this.rawText,
  });

  final String? longNumber;
  final String? shortNumber;
  final String rawText;

  bool get isComplete => longNumber != null && shortNumber != null;
}

class OcrService {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  Future<CardNumbersResult> scanImage(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    final recognizedText = await _recognizer.processImage(inputImage);
    return extractFromRawText(recognizedText.text);
  }

  Future<void> dispose() => _recognizer.close();

  static CardNumbersResult extractFromRawText(String rawText) {
    final longCandidates = <String>[];
    final shortCandidates = <String>[];

    final lines = rawText
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);

    for (final line in lines) {
      final normalizedDigits = _replaceArabicDigits(line);

      for (final match in RegExp(r'\d+').allMatches(normalizedDigits)) {
        _addCandidate(
          match.group(0)!,
          longCandidates: longCandidates,
          shortCandidates: shortCandidates,
        );
      }

      final digitsOnly = normalizedDigits.replaceAll(RegExp(r'[^0-9]'), '');
      _addCandidate(
        digitsOnly,
        longCandidates: longCandidates,
        shortCandidates: shortCandidates,
      );

      final actualDigitCount =
          RegExp(r'[0-9]').allMatches(normalizedDigits).length;
      if (actualDigitCount >= 4) {
        final corrected = _correctCommonOcrMistakes(normalizedDigits)
            .replaceAll(RegExp(r'[^0-9]'), '');

        _addCandidate(
          corrected,
          longCandidates: longCandidates,
          shortCandidates: shortCandidates,
        );
      }
    }

    return CardNumbersResult(
      longNumber: _pickLongNumber(longCandidates),
      shortNumber: shortCandidates.isEmpty ? null : shortCandidates.first,
      rawText: rawText,
    );
  }

  static void _addCandidate(
    String value, {
    required List<String> longCandidates,
    required List<String> shortCandidates,
  }) {
    if (value.length == 11 && !longCandidates.contains(value)) {
      longCandidates.add(value);
    }

    if (value.length == 6 && !shortCandidates.contains(value)) {
      shortCandidates.add(value);
    }
  }

  static String? _pickLongNumber(List<String> candidates) {
    if (candidates.isEmpty) {
      return null;
    }

    for (final candidate in candidates) {
      if (candidate.startsWith('00')) {
        return candidate;
      }
    }

    return candidates.first;
  }

  static String _replaceArabicDigits(String input) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';

    var result = input;
    for (var i = 0; i < 10; i++) {
      result = result
          .replaceAll(arabic[i], '$i')
          .replaceAll(persian[i], '$i');
    }
    return result;
  }

  static String _correctCommonOcrMistakes(String input) {
    return input
        .replaceAll(RegExp(r'[OoQqDd]'), '0')
        .replaceAll(RegExp(r'[IiLl|]'), '1')
        .replaceAll(RegExp(r'[Zz]'), '2')
        .replaceAll(RegExp(r'[Ss]'), '5')
        .replaceAll(RegExp(r'[Gg]'), '6')
        .replaceAll(RegExp(r'[Bb]'), '8');
  }
}
