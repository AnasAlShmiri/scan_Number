import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/scan_record.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';

class LiveScannerScreen extends StatefulWidget {
  const LiveScannerScreen({super.key});

  @override
  State<LiveScannerScreen> createState() => _LiveScannerScreenState();
}

class _LiveScannerScreenState extends State<LiveScannerScreen>
    with WidgetsBindingObserver {
  static const _frameInterval = Duration(milliseconds: 500);
  static const _saveCooldown = Duration(milliseconds: 1400);
  static const _requiredStableReads = 2;

  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final _storageService = StorageService();

  CameraController? _controller;
  CameraDescription? _camera;
  List<ScanRecord> _records = [];

  bool _initializing = true;
  bool _processingFrame = false;
  bool _flashOn = false;
  String? _errorMessage;

  String? _detectedLong;
  String? _detectedShort;
  String? _candidateKey;
  int _candidateHits = 0;
  String? _lastSavedKey;
  String _statusText = 'مرّر البطاقة داخل المربع وسيتم المسح تلقائيًا';
  int _sessionSaved = 0;

  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

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

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('لم يتم العثور على كاميرا في الجهاز.');
      }

      final backCameras = cameras
          .where((camera) => camera.lensDirection == CameraLensDirection.back)
          .toList();
      final selectedCamera =
          backCameras.isNotEmpty ? backCameras.first : cameras.first;

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
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
    if (_processingFrame || !mounted) {
      return;
    }

    final now = DateTime.now();
    if (now.isBefore(_cooldownUntil) ||
        now.difference(_lastFrameAt) < _frameInterval) {
      return;
    }

    _processingFrame = true;
    _lastFrameAt = now;
    unawaited(_processCameraImage(image));
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        return;
      }

      final recognizedText = await _recognizer.processImage(inputImage);
      final parsed = OcrService.extractFromRawText(recognizedText.text);

      if (!mounted) {
        return;
      }

      setState(() {
        _detectedLong = parsed.longNumber;
        _detectedShort = parsed.shortNumber;
        if (!parsed.isComplete) {
          _statusText = 'ثبّت البطاقة قليلًا داخل المربع';
        }
      });

      if (!parsed.isComplete) {
        _candidateKey = null;
        _candidateHits = 0;
        return;
      }

      final longNumber = parsed.longNumber!;
      final shortNumber = parsed.shortNumber!;
      final key = '$longNumber|$shortNumber';

      if (key == _lastSavedKey) {
        return;
      }

      if (_candidateKey == key) {
        _candidateHits++;
      } else {
        _candidateKey = key;
        _candidateHits = 1;
      }

      if (mounted) {
        setState(() {
          _statusText =
              'تم التعرف على الرقمين ($_candidateHits/$_requiredStableReads)';
        });
      }

      if (_candidateHits >= _requiredStableReads) {
        await _saveDetectedCard(longNumber, shortNumber, key);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statusText = 'استمر في تمرير البطاقة داخل المربع';
        });
      }
    } finally {
      _processingFrame = false;
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
        rotationCompensation =
            (sensorOrientation + rotationCompensation) % 360;
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

  Future<void> _saveDetectedCard(
    String longNumber,
    String shortNumber,
    String key,
  ) async {
    final duplicate = _records.any(
      (record) => record.longNumber == longNumber,
    );

    _candidateKey = null;
    _candidateHits = 0;
    _lastSavedKey = key;
    _cooldownUntil = DateTime.now().add(_saveCooldown);

    if (duplicate) {
      if (mounted) {
        setState(() {
          _statusText = 'هذه البطاقة محفوظة مسبقًا';
        });
      }
      await HapticFeedback.selectionClick();
      return;
    }

    final record = ScanRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      longNumber: longNumber,
      shortNumber: shortNumber,
      createdAt: DateTime.now(),
    );

    _records = [record, ..._records];
    await _storageService.saveRecords(_records);
    await HapticFeedback.mediumImpact();

    if (!mounted) {
      return;
    }

    setState(() {
      _sessionSaved++;
      _statusText = '✓ تم الحفظ تلقائيًا — مرّر البطاقة التالية';
    });
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
    await _disposeCamera();
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
              Expanded(child: _buildCameraArea()),
              _buildStatusArea(),
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
            onPressed: _closeScanner,
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
              const Icon(Icons.camera_alt_outlined,
                  color: Colors.white70, size: 56),
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
            ColoredBox(
              color: Colors.black,
              child: CameraPreview(controller),
            ),
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
                      BoxShadow(
                        color: Colors.black45,
                        blurRadius: 8,
                      ),
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
                              borderRadius:
                                  BorderRadius.all(Radius.circular(10)),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
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
          const SizedBox(height: 10),
          const Text(
            'لا تحتاج إلى التصوير أو الضغط على زر. ثبّت البطاقة لحظة قصيرة فقط.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _DetectedValue extends StatelessWidget {
  const _DetectedValue({
    required this.title,
    required this.value,
  });

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
