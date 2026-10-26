import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/scan_record.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';
import '../services/text_export_service.dart';

class LiveScannerScreen extends StatefulWidget {
  const LiveScannerScreen({super.key});

  @override
  State<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends State<LiveScannerScreen>
    with WidgetsBindingObserver {
  // Process fresh frames frequently, while keeping at most one OCR task active.
  static const _frameInterval = Duration(milliseconds: 120);
  static const _requiredStableReads = 2;

  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _storageService = StorageService();
  final _textService = TextExportService();

  CameraController? _controller;
  CameraDescription? _camera;
  List<ScanRecord> _records = [];
  final Set<String> _savedLongNumbers = {};

  bool _initializing = true;
  bool _processingFrame = false;
  bool _flashOn = false;
  bool _paused = false;
  bool _exporting = false;
  bool _closing = false;
  Future<void>? _frameTask;
  String? _errorMessage;

  String? _detectedLong;
  String? _detectedShort;
  String? _candidateKey;
  int _candidateHits = 0;
  String _statusText = 'مرّر البطاقة داخل المربع وسيتم المسح تلقائيًا';
  int _sessionSaved = 0;

  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Map<DeviceOrientation, int> _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (_controller != null) {
        unawaited(_disposeCamera());
      }
      return;
    }

    if (state == AppLifecycleState.resumed && _controller == null) {
      unawaited(_initializeCamera());
    }
  }

  Future<void> _initializeCamera() async {
    if (_controller != null) {
      await _disposeCamera();
    }
    if (mounted) {
      setState(() {
        _initializing = true;
        _errorMessage = null;
      });
    }

    try {
      _records = await _storageService.loadRecords();
      _savedLongNumbers
        ..clear()
        ..addAll(_records.map((record) => record.longNumber));

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('لم يتم العثور على كاميرا في الجهاز.');
      }

      final backCameras = cameras
          .where((camera) => camera.lensDirection == CameraLensDirection.back)
          .toList();
      final selectedCamera = backCameras.isNotEmpty
          ? backCameras.first
          : cameras.first;

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {
        // Some devices do not expose focus-mode control.
      }

      _camera = selectedCamera;
      _controller = controller;

      await controller.startImageStream(_onCameraImage);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _initializing = false;
        _statusText = 'مرّر البطاقة داخل المربع وسيتم المسح تلقائيًا';
      });
    } on CameraException catch (error) {
      _setCameraError(_cameraErrorText(error));
    } catch (error) {
      _setCameraError('تعذر تشغيل الكاميرا: $error');
    }
  }

  void _setCameraError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _initializing = false;
      _errorMessage = message;
    });
  }

  String _cameraErrorText(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
        return 'تم رفض إذن الكاميرا. فعّل إذن الكاميرا للتطبيق ثم حاول مرة أخرى.';
      default:
        return 'تعذر تشغيل الكاميرا: ${error.description ?? error.code}';
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _controller;
    _controller = null;
    _camera = null;

    if (controller == null) {
      return;
    }

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // The stream may already be stopped by the platform.
    }

    await controller.dispose();
  }

  void _onCameraImage(CameraImage image) {
    if (_processingFrame || _paused || _closing || !mounted) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < _frameInterval) {
      return;
    }

    _processingFrame = true;
    _lastFrameAt = now;
    _frameTask = _processCameraImage(image);
    unawaited(_frameTask);
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _candidateKey = null;
        _candidateHits = 0;
        return;
      }

      final recognizedText = await _recognizer.processImage(inputImage);
      final parsed = OcrService.extractFromRawText(recognizedText.text);

      if (!mounted || _paused || _closing) {
        return;
      }

      if (_detectedLong != parsed.longNumber ||
          _detectedShort != parsed.shortNumber) {
        setState(() {
          _detectedLong = parsed.longNumber;
          _detectedShort = parsed.shortNumber;
        });
      }

      if (!parsed.isComplete) {
        _candidateKey = null;
        _candidateHits = 0;
        _setStatusText('ثبّت البطاقة قليلًا داخل المربع');
        return;
      }

      final longNumber = parsed.longNumber!;
      final shortNumber = parsed.shortNumber!;
      final key = '$longNumber|$shortNumber';

      if (_savedLongNumbers.contains(longNumber)) {
        _candidateKey = null;
        _candidateHits = 0;
        _setStatusText('هذه البطاقة محفوظة — مرّر البطاقة التالية');
        return;
      }

      if (_candidateKey == key) {
        _candidateHits++;
      } else {
        _candidateKey = key;
        _candidateHits = 1;
      }

      _setStatusText(
        'تم التعرف على الرقمين ($_candidateHits/$_requiredStableReads)',
      );

      if (_candidateHits >= _requiredStableReads) {
        await _saveDetectedCard(longNumber, shortNumber);
      }
    } catch (_) {
      _candidateKey = null;
      _candidateHits = 0;
      _setStatusText('استمر في تمرير البطاقة داخل المربع');
    } finally {
      _processingFrame = false;
    }
  }

  void _setStatusText(String text) {
    if (mounted && _statusText != text) {
      setState(() => _statusText = text);
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _camera;
    final controller = _controller;
    if (camera == null || controller == null) {
      return null;
    }

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) {
        return null;
      }

      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }

      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }

    if (rotation == null || image.planes.length != 1) {
      return null;
    }

    final plane = image.planes.first;

    // CameraX can report yuv420 while delivering NV21 bytes when NV21 was
    // requested. ML Kit needs the real byte layout, so Android is forced to
    // NV21 here. iOS uses BGRA8888.
    final format = Platform.isAndroid
        ? InputImageFormat.nv21
        : InputImageFormatValue.fromRawValue(image.format.raw);

    if (format == null ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _saveDetectedCard(String longNumber, String shortNumber) async {
    _candidateKey = null;
    _candidateHits = 0;

    final record = ScanRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      longNumber: longNumber,
      shortNumber: shortNumber,
      createdAt: DateTime.now(),
    );

    List<ScanRecord> savedRecords;
    try {
      // Append to the persisted batch so opening the scanner never replaces it.
      savedRecords = await _storageService.addRecord(record);
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusText =
              'تعذر حفظ البطاقة. ثبّتها أمام الكاميرا لإعادة المحاولة';
        });
      }
      return;
    }

    // Successful saves are remembered immediately, so the next card can be
    // scanned without a timed cooldown or repeated storage reads for this card.
    _savedLongNumbers.addAll(savedRecords.map((record) => record.longNumber));
    final added = savedRecords.any((item) => item.id == record.id);

    if (!mounted) {
      return;
    }

    setState(() {
      _records = savedRecords;
      if (added) {
        _sessionSaved++;
      }
      _statusText = added
          ? '✓ أُضيفت البطاقة إلى القائمة — مرّر البطاقة التالية'
          : 'هذه البطاقة محفوظة مسبقًا — مرّر البطاقة التالية';
    });
    // Feedback is optional; its failure must not make a successful save fail.
    unawaited(HapticFeedback.mediumImpact().catchError((Object _) {}));
  }

  void _toggleScanning() {
    setState(() {
      _paused = !_paused;
      _candidateKey = null;
      _candidateHits = 0;
      _statusText = _paused
          ? 'المسح متوقف مؤقتًا — البطاقات محفوظة في القائمة'
          : 'مرّر البطاقة التالية وسيتم حفظها تلقائيًا';
    });
  }

  Future<void> _exportText() async {
    if (_records.isEmpty || _exporting || _closing) {
      return;
    }

    final wasPaused = _paused;
    setState(() {
      _exporting = true;
      _paused = true;
      _candidateKey = null;
      _candidateHits = 0;
    });
    try {
      // Include a save that was already in progress before export was tapped.
      await _frameTask;
      final file = await _textService.createTextFile(
        _records.reversed.toList(),
      );
      if (!mounted || _closing) {
        return;
      }
      await _textService.shareFile(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر تصدير الملف النصي. حاول مرة أخرى.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _paused = wasPaused;
          _statusText = wasPaused
              ? 'المسح متوقف مؤقتًا — البطاقات محفوظة في القائمة'
              : 'مرّر البطاقة التالية وسيتم حفظها تلقائيًا';
        });
      }
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      final next = !_flashOn;
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) {
        setState(() => _flashOn = next);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusText = 'الفلاش غير متاح على هذه الكاميرا';
        });
      }
    }
  }

  Future<void> _closeScanner() async {
    if (_closing || _exporting) {
      return;
    }
    setState(() => _closing = true);
    await _disposeCamera();
    await _frameTask;
    if (mounted) {
      Navigator.pop(context, _sessionSaved);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeCamera());
    unawaited(_recognizer.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_closeScanner());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              Expanded(flex: 3, child: _buildCameraArea()),
              _buildStatusArea(),
              Expanded(flex: 2, child: _buildSavedRecords()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: _closing || _exporting ? null : _closeScanner,
            color: Colors.white,
            icon: const Icon(Icons.arrow_back),
            tooltip: 'رجوع',
          ),
          const Expanded(
            child: Text(
              'المسح المباشر',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            onPressed: _exporting || _closing ? null : _toggleScanning,
            color: Colors.white,
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            tooltip: _paused ? 'استئناف المسح التلقائي' : 'إيقاف المسح مؤقتًا',
          ),
          IconButton(
            onPressed: _toggleFlash,
            color: _flashOn ? Colors.amber : Colors.white,
            icon: Icon(_flashOn ? Icons.flash_on : Icons.flash_off),
            tooltip: 'الفلاش',
          ),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    if (_initializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                color: Colors.white70,
                size: 56,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _initializeCamera,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Colors.black, child: CameraPreview(controller)),
            Container(color: Colors.black.withValues(alpha: 0.08)),
            Center(
              child: FractionallySizedBox(
                widthFactor: 0.88,
                heightFactor: 0.42,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _detectedLong != null && _detectedShort != null
                          ? Colors.greenAccent
                          : Colors.white,
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 8),
                    ],
                  ),
                  child: Stack(
                    children: [
                      const Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.all(
                                Radius.circular(10),
                              ),
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Text(
                                'ضع الرقمين داخل هذا المربع',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: Container(
                          height: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 18),
                          color: Colors.greenAccent.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Text(
                    'تم الحفظ: $_sessionSaved',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusArea() {
    final complete = _detectedLong != null && _detectedShort != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF111315),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _statusText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: complete ? Colors.greenAccent : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DetectedValue(
                  title: 'الرقم الطويل',
                  value: _detectedLong ?? '-----------',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _DetectedValue(
                  title: 'الرقم القصير',
                  value: _detectedShort ?? '------',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSavedRecords() {
    return ColoredBox(
      color: const Color(0xFF111315),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'البطاقات المحفوظة (${_records.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _records.isEmpty || _exporting || _closing
                      ? null
                      : _exportText,
                  icon: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.description_outlined),
                  label: const Text('تصدير TXT'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _records.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'وجّه الكاميرا نحو الكرت. ستُضاف كل بطاقة هنا تلقائيًا دون حذف السابقة.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    itemCount: _records.length,
                    itemBuilder: (context, index) {
                      final record = _records[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: Colors.greenAccent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${_records.length - index}',
                              style: const TextStyle(color: Colors.white60),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                record.longNumber,
                                textDirection: TextDirection.ltr,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                record.shortNumber,
                                textDirection: TextDirection.ltr,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetectedValue extends StatelessWidget {
  const _DetectedValue({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Column(
          children: [
            Text(
              title,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
