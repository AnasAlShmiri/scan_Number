import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/scan_record.dart';
import '../services/excel_export_service.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _picker = ImagePicker();
  final _ocrService = OcrService();
  final _storageService = StorageService();
  final _excelService = ExcelExportService();

  List<ScanRecord> _records = [];
  bool _loading = true;
  bool _scanning = false;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _ocrService.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    final records = await _storageService.loadRecords();
    if (!mounted) {
      return;
    }

    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<ImageSource?> _chooseImageSource() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'اختر طريقة المسح',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('فتح الكاميرا'),
                  subtitle: const Text('صوّر البطاقة مباشرة'),
                  onTap: () => Navigator.pop(context, ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('اختيار صورة'),
                  subtitle: const Text('استخدم صورة محفوظة في الهاتف'),
                  onTap: () => Navigator.pop(context, ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _scanCard() async {
    if (_scanning) {
      return;
    }

    final source = await _chooseImageSource();
    if (source == null) {
      return;
    }

    final image = await _picker.pickImage(
      source: source,
      imageQuality: 100,
      maxWidth: 2400,
      preferredCameraDevice: CameraDevice.rear,
    );

    if (image == null || !mounted) {
      return;
    }

    setState(() => _scanning = true);

    try {
      final result = await _ocrService.scanImage(image.path);

      if (!mounted) {
        return;
      }

      setState(() => _scanning = false);

      final record = await _showRecordDialog(
        initialLong: result.longNumber ?? '',
        initialShort: result.shortNumber ?? '',
        rawText: result.rawText,
      );

      if (record != null) {
        await _addRecord(record);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      _showMessage(
        'تعذر قراءة الصورة. حاول التصوير بإضاءة جيدة وبشكل مستقيم.',
        isError: true,
      );
    } finally {
      if (mounted && _scanning) {
        setState(() => _scanning = false);
      }
    }
  }

  Future<ScanRecord?> _showRecordDialog({
    required String initialLong,
    required String initialShort,
    required String rawText,
    ScanRecord? existing,
  }) async {
    final formKey = GlobalKey<FormState>();
    final longController = TextEditingController(text: initialLong);
    final shortController = TextEditingController(text: initialShort);

    final result = await showDialog<ScanRecord>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text(existing == null ? 'مراجعة الأرقام' : 'تعديل السجل'),
            content: SizedBox(
              width: 420,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'راجع الرقمين قبل الحفظ. يمكنك تعديل أي رقم أخطأ OCR في قراءته.',
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: longController,
                        keyboardType: TextInputType.number,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(11),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'الرقم الطويل',
                          hintText: '00436434838',
                          prefixIcon: Icon(Icons.confirmation_number_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.length != 11) {
                            return 'يجب أن يتكون الرقم الطويل من 11 رقمًا';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: shortController,
                        keyboardType: TextInputType.number,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'الرقم القصير',
                          hintText: '228790',
                          prefixIcon: Icon(Icons.pin_outlined),
                        ),
                        validator: (value) {
                          if (value == null || value.length != 6) {
                            return 'يجب أن يتكون الرقم القصير من 6 أرقام';
                          }
                          return null;
                        },
                      ),
                      if (rawText.trim().isEmpty) ...[
                        const SizedBox(height: 12),
                        const Row(
                          children: [
                            Icon(Icons.info_outline, size: 18),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'لم يتعرف OCR على أرقام واضحة. أدخل الرقمين يدويًا.',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: () {
                  if (!formKey.currentState!.validate()) {
                    return;
                  }

                  Navigator.pop(
                    dialogContext,
                    ScanRecord(
                      id: existing?.id ??
                          DateTime.now().microsecondsSinceEpoch.toString(),
                      longNumber: longController.text,
                      shortNumber: shortController.text,
                      createdAt: existing?.createdAt ?? DateTime.now(),
                    ),
                  );
                },
                icon: const Icon(Icons.check),
                label: Text(existing == null ? 'حفظ' : 'تحديث'),
              ),
            ],
          ),
        );
      },
    );

    longController.dispose();
    shortController.dispose();
    return result;
  }

  Future<void> _addRecord(ScanRecord record) async {
    final duplicate = _records.any(
      (item) => item.longNumber == record.longNumber,
    );

    if (duplicate) {
      _showMessage('هذا الرقم موجود مسبقًا ولم تتم إضافته.', isError: true);
      return;
    }

    setState(() => _records = [record, ..._records]);
    await _storageService.saveRecords(_records);

    if (mounted) {
      _showMessage('تم حفظ البطاقة مؤقتًا داخل التطبيق.');
    }
  }

  Future<void> _editRecord(ScanRecord record) async {
    final updated = await _showRecordDialog(
      initialLong: record.longNumber,
      initialShort: record.shortNumber,
      rawText: '',
      existing: record,
    );

    if (updated == null) {
      return;
    }

    final duplicate = _records.any(
      (item) =>
          item.id != updated.id && item.longNumber == updated.longNumber,
    );

    if (duplicate) {
      _showMessage('يوجد سجل آخر بنفس الرقم الطويل.', isError: true);
      return;
    }

    final next = _records
        .map((item) => item.id == updated.id ? updated : item)
        .toList();

    setState(() => _records = next);
    await _storageService.saveRecords(_records);

    if (mounted) {
      _showMessage('تم تحديث السجل.');
    }
  }

  Future<void> _deleteRecord(ScanRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف السجل'),
          content: const Text('هل تريد حذف هذه البطاقة من القائمة؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(
      () => _records = _records.where((item) => item.id != record.id).toList(),
    );
    await _storageService.saveRecords(_records);
  }

  Future<void> _clearAll() async {
    if (_records.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('مسح جميع السجلات'),
          content: const Text(
            'سيتم حذف جميع الأرقام المحفوظة مؤقتًا من التطبيق. هل أنت متأكد؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('مسح الكل'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) {
      return;
    }

    setState(() => _records = []);
    await _storageService.clearRecords();

    if (mounted) {
      _showMessage('تم مسح جميع السجلات.');
    }
  }

  Future<void> _exportExcel() async {
    if (_records.isEmpty || _exporting) {
      return;
    }

    setState(() => _exporting = true);

    try {
      final file = await _excelService.createExcelFile(
        _records.reversed.toList(),
      );

      if (!mounted) {
        return;
      }

      _showMessage('تم إنشاء ملف Excel بنجاح.');
      await _excelService.shareFile(file);
    } catch (_) {
      if (mounted) {
        _showMessage('حدث خطأ أثناء إنشاء ملف Excel.', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor:
              isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ماسح أرقام البطاقات'),
        centerTitle: true,
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              tooltip: 'مسح جميع السجلات',
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      _HeaderCard(
                        count: _records.length,
                        onScan: _scanCard,
                        scanning: _scanning,
                      ),
                      Expanded(
                        child: _records.isEmpty
                            ? const _EmptyState()
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                itemCount: _records.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final record = _records[index];
                                  return _RecordCard(
                                    index: _records.length - index,
                                    record: record,
                                    onEdit: () => _editRecord(record),
                                    onDelete: () => _deleteRecord(record),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: FilledButton.icon(
                            onPressed: _records.isEmpty || _exporting
                                ? null
                                : _exportExcel,
                            icon: _exporting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.table_view_outlined),
                            label: Text(
                              _exporting
                                  ? 'جاري إنشاء الملف...'
                                  : 'تصدير ${_records.length} سجل إلى Excel',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_scanning)
            ColoredBox(
              color: Colors.black.withValues(alpha: 0.22),
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('جاري قراءة أرقام البطاقة...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.count,
    required this.onScan,
    required this.scanning,
  });

  final int count;
  final VoidCallback onScan;
  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        elevation: 0,
        color: colors.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(
                  Icons.document_scanner_outlined,
                  color: colors.onPrimary,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'السجلات المحفوظة مؤقتًا',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count بطاقة',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: scanning ? null : onScan,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('مسح'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.index,
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final ScanRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            CircleAvatar(
              child: Text('$index'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'الرقم الطويل',
                    style: TextStyle(fontSize: 12),
                  ),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: SelectableText(
                      record.longNumber,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Text(
                        'الرقم القصير: ',
                        style: TextStyle(fontSize: 12),
                      ),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: SelectableText(
                          record.shortNumber,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  onEdit();
                } else if (value == 'delete') {
                  onDelete();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(Icons.edit_outlined),
                      SizedBox(width: 8),
                      Text('تعديل'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline),
                      SizedBox(width: 8),
                      Text('حذف'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.credit_card_off_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد بطاقات محفوظة بعد',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'اضغط "مسح" وصوّر البطاقة. سيحاول التطبيق استخراج الرقم الطويل المكوّن من 11 رقمًا والرقم القصير المكوّن من 6 أرقام.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
