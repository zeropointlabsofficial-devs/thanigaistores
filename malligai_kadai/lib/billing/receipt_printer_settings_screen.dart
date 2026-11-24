import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'billing_gateway.dart';
import 'receipt_printer.dart';

class ReceiptPrinterSettingsScreen extends StatefulWidget {
  const ReceiptPrinterSettingsScreen({super.key, required this.gateway});

  final ReceiptPrinterGateway gateway;

  @override
  State<ReceiptPrinterSettingsScreen> createState() =>
      _ReceiptPrinterSettingsScreenState();
}

class _ReceiptPrinterSettingsScreenState
    extends State<ReceiptPrinterSettingsScreen> {
  List<InstalledReceiptPrinter> _printers = [];
  ReceiptPrinterSettings? _settings;
  String? _rollSelectedUrl;
  String? _a4SelectedUrl;
  int _paperWidthMm = ReceiptPrinterSettings.defaultPaperWidthMm;
  double _printableWidthMm = ReceiptPrinterSettings.defaultPrintableWidthMm;
  final TextEditingController _printableWidthController = TextEditingController(
    text: '72.0',
  );
  String _a4Orientation = 'portrait';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.gateway.loadSettings();
      final printers = await widget.gateway.listPrinters();
      if (!mounted) return;
      final savedRollExists = printers.any(
        (printer) => printer.url == settings?.printerUrl,
      );
      final savedA4Exists = printers.any(
        (printer) => printer.url == settings?.a4PrinterUrl,
      );
      final rollPrinterUrl = savedRollExists ? settings!.printerUrl : null;
      final a4PrinterUrl = savedA4Exists ? settings!.a4PrinterUrl : null;
      setState(() {
        _settings = settings;
        _printers = printers;
        _rollSelectedUrl = rollPrinterUrl;
        _a4SelectedUrl = a4PrinterUrl;
        _paperWidthMm = settings?.paperWidthMm ?? 80;
        _printableWidthMm =
            settings?.targetPrintableWidthMm ??
            ReceiptPrinterSettings.defaultPrintableWidthMm;
        _printableWidthController.text = _printableWidthMm.toStringAsFixed(1);
        _a4Orientation = settings?.a4Orientation ?? 'portrait';
        _loading = false;
      });
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not read installed Windows printers.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final printableWidthMm = double.tryParse(
      _printableWidthController.text.trim(),
    );
    if (printableWidthMm == null ||
        !printableWidthMm.isFinite ||
        printableWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        printableWidthMm > _paperWidthMm) {
      setState(
        () => _error =
            'Enter a printable target width from ${ReceiptPrinterSettings.minimumPrintableWidthMm.toStringAsFixed(0)} to $_paperWidthMm mm.',
      );
      return;
    }
    final rollSelected = _printers.where(
      (printer) => printer.url == _rollSelectedUrl,
    );
    final a4Selected = _printers.where(
      (printer) => printer.url == _a4SelectedUrl,
    );
    if (rollSelected.isEmpty) {
      setState(() => _error = 'Select an installed Roll/Thermal printer.');
      return;
    }
    if (a4Selected.isEmpty) {
      setState(() => _error = 'Select an installed A4 printer.');
      return;
    }
    if (!rollSelected.first.isAvailable) {
      setState(
        () => _error =
            'The selected Roll/Thermal printer is unavailable or offline.',
      );
      return;
    }
    if (!a4Selected.first.isAvailable) {
      setState(
        () => _error = 'The selected A4 printer is unavailable or offline.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rollPrinter = rollSelected.first;
      final a4Printer = a4Selected.first;
      final settings = ReceiptPrinterSettings(
        printerName: rollPrinter.name,
        printerUrl: rollPrinter.url,
        paperWidthMm: _paperWidthMm,
        printableWidthMm: printableWidthMm,
        a4Invoices: true,
        a4PrinterName: a4Printer.name,
        a4PrinterUrl: a4Printer.url,
        a4Orientation: _a4Orientation,
      );
      await widget.gateway.saveSettings(settings);
      if (mounted) {
        setState(() => _settings = settings);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Printer settings saved locally.'),
          ),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save local printer settings.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _printableWidthController.dispose();
    super.dispose();
  }

  Future<void> _printTest() async {
    const testInvoice = SavedInvoice(
      invoiceNumber: 'PRINTER-TEST',
      cashierName: 'Test mode',
      subtotal: '68.00',
      discountAmount: '5.00',
      taxableAmount: '63.00',
      cgstAmount: '1.58',
      sgstAmount: '1.57',
      totalTax: '3.15',
      gstEnabled: true,
      grandTotal: '66.15',
      createdAt: '2026-01-01T12:00:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'Basmati Rice',
          sku: 'TEST-RICE',
          unit: 'kg',
          unitPrice: '25.00',
          quantity: '2',
          lineTotal: '50.00',
        ),
        SavedInvoiceItem(
          productName: 'Organic Traditional Appalam Papad Special Pack XL',
          sku: 'TEST-APPALAM',
          unit: 'pack',
          unitPrice: '12.00',
          quantity: '1',
          lineTotal: '12.00',
        ),
        SavedInvoiceItem(
          productName: 'Tea Powder',
          sku: 'TEST-TEA',
          unit: 'packet',
          unitPrice: '2.00',
          quantity: '3',
          lineTotal: '6.00',
        ),
      ],
      payments: [
        InvoicePayment(method: 'cash', amount: '20.00'),
        InvoicePayment(method: 'upi', amount: '46.15'),
      ],
      replayed: false,
    );
    try {
      final completed = await widget.gateway.printReceipt(
        testInvoice,
        testMode: true,
        a4Invoice: false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completed
                  ? 'Test receipt sent. It is not a sale.'
                  : 'Test print was cancelled.',
            ),
          ),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the printer test receipt.');
      }
    }
  }

  Future<void> _printA4Test() async {
    const testInvoice = SavedInvoice(
      invoiceNumber: 'A4-PRINTER-TEST',
      cashierName: 'Test mode',
      subtotal: '4660.00',
      grandTotal: '4660.00',
      taxableAmount: '4435.72',
      cgstAmount: '110.89',
      sgstAmount: '110.89',
      igstAmount: '0.00',
      totalTax: '221.78',
      gstEnabled: true,
      shopStateCode: '33',
      saleStateCode: '33',
      invoiceType: 'bulk',
      customerName: 'Printer Test Customer',
      customerAddress: 'Test Address',
      placeOfSupply: '33-Tamil Nadu',
      businessName: 'Thanigai Stores',
      businessAddress: '312, NORTH RAJ STREET TIRUVALLUR',
      businessPhone: '7200412487',
      gstin: '33AOPTB5179P1Z4',
      createdAt: '2026-01-01T12:00:00.000Z',
      items: [
        SavedInvoiceItem(
          productName: 'A4 Printer Test Item',
          sku: 'TEST-A4',
          unit: 'piece',
          unitPrice: '4660.00',
          quantity: '1',
          lineTotal: '4660.00',
          hsnCode: '999999',
          gstRate: '5.00',
          taxableAmount: '4435.72',
          cgstAmount: '110.89',
          sgstAmount: '110.89',
        ),
      ],
      payments: [InvoicePayment(method: 'cash', amount: '4660.00')],
      replayed: false,
    );
    try {
      final completed = await widget.gateway.printReceipt(
        testInvoice,
        testMode: true,
        a4Invoice: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              completed
                  ? 'A4 test invoice sent. It is not a sale.'
                  : 'A4 test print was cancelled.',
            ),
          ),
        );
      }
    } on ReceiptPrinterFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the A4 printer test.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Printer settings'),
        actions: [
          IconButton(
            key: const Key('refreshReceiptPrintersButton'),
            tooltip: 'Refresh installed printers',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        const Text(
                          'Choose a printer installed in Windows. Printing uses its driver; no USB or ESC/POS protocol is assumed.',
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Paper roll size and printable layout width are separate. The 72 mm RTP-81 value is a target based on the advertised print width, not a verified Windows driver area. Adjust this target after installing the printer and checking its paper form.',
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: const Key('rollPrinterDropdown'),
                          initialValue: _rollSelectedUrl,
                          decoration: const InputDecoration(
                            labelText: 'Normal Bill Printer',
                            border: OutlineInputBorder(),
                          ),
                          items: _printers
                              .map(
                                (printer) => DropdownMenuItem(
                                  value: printer.url,
                                  child: Text(
                                    '${printer.name}'
                                    '${printer.isDefault ? ' (default)' : ''}'
                                    '${printer.isAvailable ? '' : ' (offline/unavailable)'}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (value) =>
                                    setState(() => _rollSelectedUrl = value),
                        ),
                        if (_printers.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              'No Windows printers were found. Install the manufacturer driver and refresh this list.',
                            ),
                          ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          key: const Key('receiptPaperWidthDropdown'),
                          initialValue: _paperWidthMm,
                          decoration: const InputDecoration(
                            labelText: 'Receipt paper roll size',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 58, child: Text('58 mm')),
                            DropdownMenuItem(value: 80, child: Text('80 mm')),
                          ],
                          onChanged: _saving
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setState(() {
                                      _paperWidthMm = value;
                                      if (_printableWidthMm > value) {
                                        _printableWidthMm =
                                            value.toDouble() - 8;
                                        _printableWidthController.text =
                                            _printableWidthMm.toStringAsFixed(
                                              1,
                                            );
                                      }
                                    });
                                  }
                                },
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('receiptPrintableWidthField'),
                          controller: _printableWidthController,
                          enabled: !_saving,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'^\d{0,2}(?:\.\d?)?$'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Printable layout target (mm)',
                            helperText: 'Default 72 mm is an advertised target, not measured driver printable width.',
                            suffixText: 'mm',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) {
                            final parsed = double.tryParse(value);
                            if (parsed != null && parsed.isFinite) {
                              setState(() => _printableWidthMm = parsed);
                            }
                          },
                        ),
                        DropdownButtonFormField<String>(
                          key: const Key('a4PrinterDropdown'),
                          initialValue: _a4SelectedUrl,
                          decoration: const InputDecoration(
                            labelText: 'Bulk Order Printer',
                            border: OutlineInputBorder(),
                          ),
                          items: _printers
                              .map(
                                (printer) => DropdownMenuItem(
                                  value: printer.url,
                                  child: Text(
                                    '${printer.name}'
                                    '${printer.isDefault ? ' (default)' : ''}'
                                    '${printer.isAvailable ? '' : ' (offline/unavailable)'}',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (value) =>
                                    setState(() => _a4SelectedUrl = value),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: const Key('a4OrientationDropdown'),
                          initialValue: _a4Orientation,
                          decoration: const InputDecoration(
                            labelText: 'A4 Paper Orientation',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'portrait',
                              child: Text('A4 Portrait'),
                            ),
                            DropdownMenuItem(
                              value: 'landscape',
                              child: Text('A4 Landscape'),
                            ),
                          ],
                          onChanged: _saving
                              ? null
                              : (value) => setState(
                                  () => _a4Orientation = value ?? 'portrait',
                                ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _settings == null
                              ? 'Settings are stored on this Windows PC.'
                              : 'Roll: ${_settings!.printerName} (${_settings!.paperWidthMm} mm / ${_settings!.targetPrintableWidthMm.toStringAsFixed(1)} mm target).\n'
                                    'A4: ${_settings!.a4PrinterName ?? 'Not selected'} (${_settings!.a4Orientation}).',
                        ),
                        const SizedBox(height: 16),
                        if (_error != null) ...[
                          Text(
                            _error!,
                            key: const Key('receiptPrinterError'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        FilledButton(
                          key: const Key('saveReceiptPrinterSettingsButton'),
                          onPressed: _saving || _printers.isEmpty
                              ? null
                              : _save,
                          child: Text(
                            _saving ? 'Saving…' : 'Save printer settings',
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('printTestReceiptButton'),
                          onPressed: _saving || _settings == null
                              ? null
                              : _printTest,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Test Normal Bill Printer'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('printTestA4InvoiceButton'),
                          onPressed: _saving || _settings == null
                              ? null
                              : _printA4Test,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Test Bulk Order Printer'),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
