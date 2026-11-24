import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../branding/shop_logo.dart';
import '../products/product_gateway.dart';
import 'billing_gateway.dart';
import 'receipt_formatter.dart';

BigInt _a4Cents(String value) {
  final parts = value.trim().split('.');
  if (parts.isEmpty || !RegExp(r'^\d+$').hasMatch(parts.first)) {
    return BigInt.zero;
  }
  return BigInt.parse(parts.first) * BigInt.from(100) +
      BigInt.parse(
        parts.length > 1 ? parts[1].padRight(2, '0').substring(0, 2) : '00',
      );
}

String _a4Money(BigInt cents) =>
    '${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';

String _a4FormatQuantity(String value) {
  final fraction = value.split('.');
  if (fraction.length < 2) return fraction.first;
  return '${fraction.first}.${fraction[1].replaceFirst(RegExp(r'0+$'), '')}'
      .replaceFirst(RegExp(r'\.$'), '');
}

String _a4FormatDateTime(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return value;
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$day-$month-$year, $hour:$minute';
}

String _a4AmountInWords(String amount) {
  final cents = _a4Cents(amount);
  final rupees = cents ~/ BigInt.from(100);
  final paise = cents % BigInt.from(100);
  String underThousand(int value) {
    const ones = [
      '',
      'One',
      'Two',
      'Three',
      'Four',
      'Five',
      'Six',
      'Seven',
      'Eight',
      'Nine',
      'Ten',
      'Eleven',
      'Twelve',
      'Thirteen',
      'Fourteen',
      'Fifteen',
      'Sixteen',
      'Seventeen',
      'Eighteen',
      'Nineteen',
    ];
    const tens = [
      '',
      '',
      'Twenty',
      'Thirty',
      'Forty',
      'Fifty',
      'Sixty',
      'Seventy',
      'Eighty',
      'Ninety',
    ];
    if (value < 20) return ones[value];
    if (value < 100) {
      return '${tens[value ~/ 10]}${value % 10 == 0 ? '' : ' ${ones[value % 10]}'}';
    }
    return '${ones[value ~/ 100]} Hundred${value % 100 == 0 ? '' : ' ${underThousand(value % 100)}'}';
  }

  String words(BigInt value) {
    if (value == BigInt.zero) return 'Zero';
    final crore = value ~/ BigInt.from(10000000);
    final lakh = (value % BigInt.from(10000000)) ~/ BigInt.from(100000);
    final thousand = (value % BigInt.from(100000)) ~/ BigInt.from(1000);
    final rest = value % BigInt.from(1000);
    final parts = <String>[];
    if (crore > BigInt.zero) {
      parts.add('${underThousand(crore.toInt())} Crore');
    }
    if (lakh > BigInt.zero) {
      parts.add('${underThousand(lakh.toInt())} Lakh');
    }
    if (thousand > BigInt.zero) {
      parts.add('${underThousand(thousand.toInt())} Thousand');
    }
    if (rest > BigInt.zero) {
      parts.add(underThousand(rest.toInt()));
    }
    return parts.join(' ');
  }

  final result = 'Rupees ${words(rupees)}';
  if (paise == BigInt.zero) return '$result Only';
  return '$result and ${words(paise)} Paise Only';
}

class InstalledReceiptPrinter {
  const InstalledReceiptPrinter({
    required this.name,
    required this.url,
    required this.isAvailable,
    required this.isDefault,
  });

  final String name;
  final String url;
  final bool isAvailable;
  final bool isDefault;
}

class ReceiptPrinterSettings {
  const ReceiptPrinterSettings({
    required this.printerName,
    required this.printerUrl,
    required this.paperWidthMm,
    this.printableWidthMm,
    this.a4Invoices = false,
    this.a4PrinterName,
    this.a4PrinterUrl,
    this.a4Orientation = 'portrait',
  });

  static const defaultPaperWidthMm = 80;
  static const defaultPrintableWidthMm = 72.0;
  static const minimumPrintableWidthMm = 40.0;

  final String printerName;
  final String printerUrl;
  final int paperWidthMm;
  final double? printableWidthMm;
  final bool a4Invoices;
  final String? a4PrinterName;
  final String? a4PrinterUrl;
  final String a4Orientation;

  double get targetPrintableWidthMm =>
      printableWidthMm ?? (paperWidthMm - 8).toDouble();
}

class ReceiptPrinterFailure implements Exception {
  const ReceiptPrinterFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ReceiptPrinterGateway {
  Future<List<InstalledReceiptPrinter>> listPrinters();
  Future<ReceiptPrinterSettings?> loadSettings();
  Future<void> saveSettings(ReceiptPrinterSettings settings);
  Future<Uint8List> buildPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool a4Invoice = false,
    bool a4Preview = false,
  });
  Future<bool> printReceipt(
    SavedInvoice invoice, {
    bool testMode = false,
    bool? a4Invoice,
    void Function(String notice)? onPrintNotice,
  });
}

class WindowsReceiptPrinterGateway implements ReceiptPrinterGateway {
  WindowsReceiptPrinterGateway({SharedPreferencesAsync? preferences})
    : _providedPreferences = preferences;

  static const _printerNameKey = 'receipt_printer_name';
  static const _printerUrlKey = 'receipt_printer_url';
  static const _paperWidthKey = 'receipt_paper_width_mm';
  static const _printableWidthKey = 'receipt_printable_width_mm';
  static const _a4InvoicesKey = 'receipt_a4_invoices';
  static const _a4PrinterNameKey = 'receipt_a4_printer_name';
  static const _a4PrinterUrlKey = 'receipt_a4_printer_url';
  static const _a4OrientationKey = 'receipt_a4_orientation';

  final SharedPreferencesAsync? _providedPreferences;
  late final SharedPreferencesAsync _preferences =
      _providedPreferences ?? SharedPreferencesAsync();

  @override
  Future<List<InstalledReceiptPrinter>> listPrinters() async {
    final capabilities = await Printing.info();
    if (!capabilities.canListPrinters) {
      throw const ReceiptPrinterFailure(
        'This Windows printing service cannot list installed printers.',
      );
    }
    try {
      final List<Printer> printers;
      try {
        printers = await Printing.listPrinters();
      } on PlatformException catch (error) {
        throw ReceiptPrinterFailure(
          'Windows could not list installed printers: ${error.message ?? error.code}. Install a printer and retry.',
        );
      }
      return printers
          .map(
            (printer) => InstalledReceiptPrinter(
              name: printer.name,
              url: printer.url,
              isAvailable: printer.isAvailable,
              isDefault: printer.isDefault,
            ),
          )
          .toList(growable: false);
    } on PlatformException catch (error) {
      throw ReceiptPrinterFailure(
        'Windows could not read its installed printers: ${error.message ?? error.code}.',
      );
    }
  }

  void _drawCenteredLogo(
    ui.Canvas canvas,
    ui.Image logo,
    double canvasWidth,
    double maxWidth,
    double maxHeight,
    double top,
  ) {
    final scale = math.min(maxWidth / logo.width, maxHeight / logo.height);
    final width = logo.width * scale;
    final height = logo.height * scale;
    final destination = ui.Rect.fromLTWH(
      (canvasWidth - width) / 2,
      top + (maxHeight - height) / 2,
      width,
      height,
    );
    canvas.drawImageRect(
      logo,
      ui.Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      destination,
      ui.Paint(),
    );
  }

  @override
  Future<ReceiptPrinterSettings?> loadSettings() async {
    final printerName = await _preferences.getString(_printerNameKey);
    final printerUrl = await _preferences.getString(_printerUrlKey);
    final paperWidthMm = await _preferences.getInt(_paperWidthKey);
    if (printerName == null || printerUrl == null || paperWidthMm == null) {
      return null;
    }
    if (printerName.isEmpty ||
        printerUrl.isEmpty ||
        (paperWidthMm != 58 && paperWidthMm != 80)) {
      throw const ReceiptPrinterFailure(
        'Saved receipt printer settings are invalid. Choose the printer again.',
      );
    }
    final printableWidthMm =
        await _preferences.getDouble(_printableWidthKey) ??
        (paperWidthMm - 8).toDouble();
    if (!printableWidthMm.isFinite ||
        printableWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        printableWidthMm > paperWidthMm) {
      throw const ReceiptPrinterFailure(
        'Saved printable receipt width is invalid. Adjust it in receipt printer settings.',
      );
    }
    return ReceiptPrinterSettings(
      printerName: printerName,
      printerUrl: printerUrl,
      paperWidthMm: paperWidthMm,
      printableWidthMm: printableWidthMm,
      a4Invoices: await _preferences.getBool(_a4InvoicesKey) ?? false,
      a4PrinterName: await _preferences.getString(_a4PrinterNameKey),
      a4PrinterUrl: await _preferences.getString(_a4PrinterUrlKey),
      a4Orientation:
          await _preferences.getString(_a4OrientationKey) ?? 'portrait',
    );
  }

  @override
  Future<void> saveSettings(ReceiptPrinterSettings settings) async {
    if (settings.printerName.isEmpty ||
        settings.printerUrl.isEmpty ||
        (settings.paperWidthMm != 58 && settings.paperWidthMm != 80) ||
        !settings.targetPrintableWidthMm.isFinite ||
        settings.targetPrintableWidthMm <
            ReceiptPrinterSettings.minimumPrintableWidthMm ||
        settings.targetPrintableWidthMm > settings.paperWidthMm) {
      throw const ReceiptPrinterFailure(
        'Choose a printer, roll size, and printable width within the roll.',
      );
    }
    await _preferences.setString(_printerNameKey, settings.printerName);
    await _preferences.setString(_printerUrlKey, settings.printerUrl);
    await _preferences.setInt(_paperWidthKey, settings.paperWidthMm);
    await _preferences.setDouble(
      _printableWidthKey,
      settings.targetPrintableWidthMm,
    );
    await _preferences.setBool(_a4InvoicesKey, settings.a4Invoices);
    if (settings.a4PrinterName != null) {
      await _preferences.setString(_a4PrinterNameKey, settings.a4PrinterName!);
    }
    if (settings.a4PrinterUrl != null) {
      await _preferences.setString(_a4PrinterUrlKey, settings.a4PrinterUrl!);
    }
    await _preferences.setString(_a4OrientationKey, settings.a4Orientation);
  }

  @override
  Future<Uint8List> buildPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool a4Invoice = false,
    bool a4Preview = false,
  }) async {
    if (a4Invoice) {
      ReceiptPrinterSettings? settings;
      try {
        settings = await loadSettings();
      } on ReceiptPrinterFailure {
        settings = null;
      } catch (_) {
        settings = null;
      }
      return _buildExactA4Pdf(
        invoice,
        testMode,
        orientation: invoice.invoiceType == 'bulk'
            ? settings?.a4Orientation ?? 'portrait'
            : 'portrait',
      );
    }
    if (a4Preview) {
      return _buildNormalA4ReceiptPreview(
        invoice,
        testMode,
        paperWidthMm: paperWidthMm,
        printableWidthMm: printableWidthMm,
      );
    }
    final receipt = await _buildReceiptPdf(
      invoice,
      paperWidthMm: paperWidthMm,
      printableWidthMm: printableWidthMm,
      testMode: testMode,
    );
    return receipt.bytes;
  }

  Future<({Uint8List bytes, PdfPageFormat format})> _buildReceiptPdf(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    required bool testMode,
  }) async {
    final contentWidthMm =
        printableWidthMm ??
        math.min(
          ReceiptPrinterSettings.defaultPrintableWidthMm,
          (paperWidthMm - 8).toDouble(),
        );
    if (!contentWidthMm.isFinite ||
        contentWidthMm < ReceiptPrinterSettings.minimumPrintableWidthMm ||
        contentWidthMm > paperWidthMm) {
      throw ArgumentError.value(printableWidthMm, 'printableWidthMm');
    }
    final lines = ReceiptFormatter.format(
      invoice,
      paperWidthMm: paperWidthMm,
      printableWidthMm: contentWidthMm,
      testMode: testMode,
    );
    final sideMarginMm = (paperWidthMm - contentWidthMm) / 2;
    final format = PdfPageFormat(
      paperWidthMm * PdfPageFormat.mm,
      1000 * PdfPageFormat.mm,
      marginLeft: sideMarginMm * PdfPageFormat.mm,
      marginRight: sideMarginMm * PdfPageFormat.mm,
      marginTop: 3 * PdfPageFormat.mm,
      marginBottom: 3 * PdfPageFormat.mm,
    );
    final document = pw.Document();
    const renderScale = 3.0;
    final titleBuilder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: 'Arial',
              fontSize: contentWidthMm * 0.2375 * renderScale,
              height: 1.05,
              fontWeight: ui.FontWeight.bold,
              textAlign: ui.TextAlign.center,
              textDirection: ui.TextDirection.ltr,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: const ui.Color(0xFF000000),
              fontWeight: ui.FontWeight.bold,
            ),
          )
          ..addText('${lines.first.trim()}\n');
    final titleParagraph = titleBuilder.build()
      ..layout(
        ui.ParagraphConstraints(width: format.availableWidth * renderScale),
      );
    final paragraphBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontFamily: 'Consolas',
        fontSize: 7.8 * renderScale,
        height: 1.25,
        textDirection: ui.TextDirection.ltr,
      ),
    );
    for (var index = 1; index < lines.length; index += 1) {
      final isTotal = lines[index].startsWith('TOTAL');
      paragraphBuilder
        ..pushStyle(
          ui.TextStyle(
            color: const ui.Color(0xFF000000),
            fontSize: isTotal ? 9.2 * renderScale : 7.8 * renderScale,
            fontWeight: isTotal ? ui.FontWeight.bold : ui.FontWeight.normal,
          ),
        )
        ..addText(lines[index])
        ..pop();
      if (index < lines.length - 1) paragraphBuilder.addText('\n');
    }
    final paragraph = paragraphBuilder.build()
      ..layout(
        ui.ParagraphConstraints(width: format.availableWidth * renderScale),
      );
    final logoData = await loadShopLogoBytes(
      'assets/thanigai_stores_receipt_logo_transparent.png',
    );
    final logoCodec = await ui.instantiateImageCodec(logoData);
    final logoFrame = await logoCodec.getNextFrame();
    final logo = logoFrame.image;
    final logoMaxWidth = math.min(
      (paperWidthMm - 12) * PdfPageFormat.mm * renderScale,
      48 * PdfPageFormat.mm * renderScale,
    );
    const logoMaxHeight = 24 * PdfPageFormat.mm * renderScale;
    const logoGap = 1 * PdfPageFormat.mm * renderScale;
    const titleGap = 2 * PdfPageFormat.mm * renderScale;
    final titleTop = logoMaxHeight + logoGap;
    final bodyTop = titleTop + titleParagraph.height + titleGap;
    final contentHeight = (bodyTop + paragraph.height) / renderScale;
    final pageFormat = format.copyWith(
      height: contentHeight + format.marginTop + format.marginBottom,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    _drawCenteredLogo(
      canvas,
      logo,
      format.availableWidth * renderScale,
      logoMaxWidth,
      logoMaxHeight,
      0,
    );
    canvas
      ..drawParagraph(titleParagraph, ui.Offset(0, titleTop))
      ..drawParagraph(paragraph, ui.Offset(0, bodyTop));
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (format.availableWidth * renderScale).ceil(),
      (bodyTop + paragraph.height).ceil(),
    );
    logo.dispose();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (png == null) {
      throw const ReceiptPrinterFailure(
        'The receipt preview could not be rendered on this Windows PC.',
      );
    }
    final receiptImage = pw.MemoryImage(png.buffer.asUint8List());
    document.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.fromLTRB(
          sideMarginMm * PdfPageFormat.mm,
          3 * PdfPageFormat.mm,
          sideMarginMm * PdfPageFormat.mm,
          3 * PdfPageFormat.mm,
        ),
        build: (_) => pw.SizedBox(
          width: pageFormat.availableWidth,
          child: pw.Image(
            receiptImage,
            width: pageFormat.availableWidth,
            height: contentHeight,
          ),
        ),
      ),
    );
    return (bytes: await document.save(), format: pageFormat);
  }

  String _stateName(String code) => switch (code) {
    '33' => 'Tamil Nadu',
    '32' => 'Kerala',
    '29' => 'Karnataka',
    '27' => 'Maharashtra',
    '07' => 'Delhi',
    '01' => 'Jammu and Kashmir',
    _ => code,
  };

  Future<Uint8List> _buildNormalA4ReceiptPreview(
    SavedInvoice invoice,
    bool testMode, {
    required int paperWidthMm,
    double? printableWidthMm,
  }) async {
    final logoData = await loadShopLogoBytes(
      'assets/thanigai_stores_receipt_logo_transparent.png',
    );
    final fallbackFont = pw.Font.ttf(
      ByteData.sublistView(
        File(r'C:\Windows\Fonts\arial.ttf').readAsBytesSync(),
      ),
    );
    final monoFont = pw.Font.courier();
    final monoBoldFont = pw.Font.courierBold();
    final logo = pw.MemoryImage(logoData);
    final document = pw.Document();
    pw.Widget pair(
      String label,
      String value, {
      bool bold = false,
      double fontSize = 11,
    }) => pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(
            label,
            style: pw.TextStyle(
              font: bold ? monoBoldFont : monoFont,
              fontFallback: [fallbackFont],
              fontSize: fontSize,
            ),
          ),
        ),
        pw.Text(
          value,
          textAlign: pw.TextAlign.right,
          softWrap: false,
          style: pw.TextStyle(
            font: bold ? monoBoldFont : monoFont,
            fontFallback: [fallbackFont],
            fontSize: fontSize,
          ),
        ),
      ],
    );
    pw.Widget dashed() => pw.Container(
      width: double.infinity,
      child: pw.Divider(
        height: 1,
        thickness: 0.7,
        borderStyle: pw.BorderStyle.dashed,
      ),
    );
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        build: (context) => pw.Center(
          child: pw.Container(
            width: double.infinity,
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Center(
                  child: pw.Image(
                    logo,
                    width: 58 * PdfPageFormat.mm,
                    height: 36 * PdfPageFormat.mm,
                    fit: pw.BoxFit.contain,
                  ),
                ),
                pw.SizedBox(height: 2 * PdfPageFormat.mm),
                pw.Center(
                  child: pw.Text(
                    'THANIGAI STORES',
                    style: pw.TextStyle(
                      font: monoBoldFont,
                      fontFallback: [fallbackFont],
                      fontSize: 24,
                    ),
                  ),
                ),
                pw.SizedBox(height: 8 * PdfPageFormat.mm),
                dashed(),
                pw.SizedBox(height: 5 * PdfPageFormat.mm),
                pair('Bill No:', '#${invoice.invoiceNumber}', fontSize: 14),
                pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
                pair(
                  'Date:',
                  _a4FormatDateTime(invoice.createdAt),
                  fontSize: 14,
                ),
                pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
                pair('Cashier:', invoice.cashierName, fontSize: 14),
                pw.SizedBox(height: 6 * PdfPageFormat.mm),
                dashed(),
                pw.SizedBox(height: 6 * PdfPageFormat.mm),
                pw.Table(
                  columnWidths: {
                    0: const pw.FlexColumnWidth(5),
                    1: const pw.FlexColumnWidth(1),
                    2: const pw.FlexColumnWidth(1.7),
                    3: const pw.FlexColumnWidth(1.8),
                  },
                  children: [
                    pw.TableRow(
                      children: [
                        pw.Text(
                          'Item',
                          style: pw.TextStyle(
                            font: monoBoldFont,
                            fontFallback: [fallbackFont],
                            fontSize: 14,
                          ),
                        ),
                        pw.Text(
                          'Qty',
                          textAlign: pw.TextAlign.right,
                          softWrap: false,
                          style: pw.TextStyle(
                            font: monoBoldFont,
                            fontFallback: [fallbackFont],
                            fontSize: 14,
                          ),
                        ),
                        pw.Text(
                          'Price',
                          textAlign: pw.TextAlign.right,
                          softWrap: false,
                          style: pw.TextStyle(
                            font: monoBoldFont,
                            fontFallback: [fallbackFont],
                            fontSize: 14,
                          ),
                        ),
                        pw.Text(
                          'Total',
                          textAlign: pw.TextAlign.right,
                          softWrap: false,
                          style: pw.TextStyle(
                            font: monoBoldFont,
                            fontFallback: [fallbackFont],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    for (final item in invoice.items)
                      pw.TableRow(
                        verticalAlignment: pw.TableCellVerticalAlignment.full,
                        children: [
                          pw.Text(
                            item.productName,
                            style: pw.TextStyle(
                              font: monoFont,
                              fontFallback: [fallbackFont],
                              fontSize: 14,
                            ),
                          ),
                          pw.Text(
                            item.quantity,
                            textAlign: pw.TextAlign.right,
                            softWrap: false,
                            style: pw.TextStyle(
                              font: monoFont,
                              fontFallback: [fallbackFont],
                              fontSize: 14,
                            ),
                          ),
                          pw.Text(
                            '₹${item.unitPrice}',
                            textAlign: pw.TextAlign.right,
                            softWrap: false,
                            style: pw.TextStyle(
                              font: monoFont,
                              fontFallback: [fallbackFont],
                              fontSize: 14,
                            ),
                          ),
                          pw.Text(
                            '₹${item.lineTotal}',
                            textAlign: pw.TextAlign.right,
                            softWrap: false,
                            style: pw.TextStyle(
                              font: monoFont,
                              fontFallback: [fallbackFont],
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                pw.SizedBox(height: 5 * PdfPageFormat.mm),
                dashed(),
                pw.SizedBox(height: 5 * PdfPageFormat.mm),
                pair('Subtotal', '₹${invoice.subtotal}', fontSize: 15),
                if (invoice.gstEnabled) ...[
                  pw.SizedBox(height: 3 * PdfPageFormat.mm),
                  pair('GST', '₹${invoice.totalTax}', fontSize: 15),
                ],
                pw.SizedBox(height: 5 * PdfPageFormat.mm),
                pair(
                  'TOTAL',
                  '₹${invoice.grandTotal}',
                  bold: true,
                  fontSize: 19,
                ),
                pw.SizedBox(height: 3 * PdfPageFormat.mm),
                pair('Total Items', '${invoice.items.length}', fontSize: 14),
                pw.SizedBox(height: 3 * PdfPageFormat.mm),
                pair(
                  'Payment method',
                  invoice.payments.isEmpty
                      ? 'Not recorded'
                      : invoice.payments
                            .map(
                              (payment) =>
                                  '${payment.method.toUpperCase()} ₹${payment.amount}',
                            )
                            .join(' + '),
                  fontSize: 14,
                ),
                pw.SizedBox(height: 6 * PdfPageFormat.mm),
                dashed(),
                pw.SizedBox(height: 6 * PdfPageFormat.mm),
                pw.Center(
                  child: pw.Text(
                    testMode
                        ? 'PRINTER TEST ONLY'
                        : 'THANK YOU! VISIT US AGAIN!',
                    style: pw.TextStyle(
                      font: monoBoldFont,
                      fontFallback: [fallbackFont],
                      fontSize: 16,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2.5 * PdfPageFormat.mm),
                pw.Center(
                  child: pw.Text(
                    'Developed By ZEROPOINT LABS',
                    style: pw.TextStyle(
                      font: monoFont,
                      fontFallback: [fallbackFont],
                      fontSize: 12,
                    ),
                  ),
                ),
                pw.SizedBox(height: 0.8 * PdfPageFormat.mm),
                pw.Center(
                  child: pw.Text(
                    'www.zeropointlabs.in',
                    style: pw.TextStyle(
                      font: monoFont,
                      fontFallback: [fallbackFont],
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return document.save();
  }

  Future<Uint8List> _buildExactA4Pdf(
    SavedInvoice invoice,
    bool testMode, {
    String orientation = 'portrait',
  }) async {
    final baseFont = pw.Font.ttf(
      ByteData.sublistView(
        File(r'C:\Windows\Fonts\arial.ttf').readAsBytesSync(),
      ),
    );
    final boldFont = pw.Font.ttf(
      ByteData.sublistView(
        File(r'C:\Windows\Fonts\arialbd.ttf').readAsBytesSync(),
      ),
    );
    final italicFont = pw.Font.ttf(
      ByteData.sublistView(
        File(r'C:\Windows\Fonts\ariali.ttf').readAsBytesSync(),
      ),
    );
    final logo = invoice.invoiceType == 'bulk'
        ? null
        : pw.MemoryImage(
            await loadShopLogoBytes('assets/thanigai_stores_receipt_logo.png'),
          );
    const sellerName = 'THANIGAI STORES';
    const border = pw.BorderSide(width: 0.55, color: PdfColors.black);
    final document = pw.Document(
      theme: pw.ThemeData.withFont(
        base: baseFont,
        bold: boldFont,
        italic: italicFont,
      ),
    );
    pw.Widget textCell(
      String text, {
      pw.TextAlign align = pw.TextAlign.left,
      pw.FontWeight? weight,
      double size = 8,
      pw.EdgeInsets padding = const pw.EdgeInsets.all(4),
    }) => pw.Padding(
      padding: padding,
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: PdfColors.black,
        ),
      ),
    );

    pw.TableRow itemHeader() => pw.TableRow(
      decoration: const pw.BoxDecoration(border: pw.Border(bottom: border)),
      children: [
        textCell(
          'HSN/SAC',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'Item Name',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'Quantity',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'Unit',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'Net Rate',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'GST %',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'GST Amount',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
        textCell(
          'Amount',
          align: pw.TextAlign.center,
          weight: pw.FontWeight.bold,
          size: 7,
        ),
      ],
    );

    final itemRows = <pw.TableRow>[itemHeader()];
    for (final item in invoice.items) {
      final gstAmount = item.igstAmount != '0.00'
          ? item.igstAmount
          : _a4Money(_a4Cents(item.cgstAmount) + _a4Cents(item.sgstAmount));
      itemRows.add(
        pw.TableRow(
          children: [
            textCell(item.hsnCode),
            textCell(item.productName),
            textCell(
              _a4FormatQuantity(item.quantity),
              align: pw.TextAlign.center,
            ),
            textCell(displayProductUnit(item.unit), align: pw.TextAlign.center),
            textCell(item.unitPrice, align: pw.TextAlign.right),
            textCell('${item.gstRate}%', align: pw.TextAlign.right),
            textCell(gstAmount, align: pw.TextAlign.right),
            textCell(
              _a4Money(_a4Cents(item.lineTotal)),
              align: pw.TextAlign.right,
            ),
          ],
        ),
      );
    }
    while (itemRows.length < 5) {
      itemRows.add(
        pw.TableRow(children: List.generate(8, (_) => pw.SizedBox(height: 20))),
      );
    }
    final totalQuantity = invoice.items
        .fold<double>(
          0,
          (sum, item) => sum + (double.tryParse(item.quantity) ?? 0),
        )
        .toStringAsFixed(3)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    itemRows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(border: pw.Border(top: border)),
        children: [
          pw.SizedBox(),
          textCell(
            'Total',
            weight: pw.FontWeight.bold,
            align: pw.TextAlign.left,
          ),
          textCell(
            totalQuantity,
            align: pw.TextAlign.center,
            weight: pw.FontWeight.bold,
          ),
          pw.SizedBox(),
          pw.SizedBox(),
          pw.SizedBox(),
          textCell(
            _a4Money(_a4Cents(invoice.totalTax)),
            align: pw.TextAlign.right,
            weight: pw.FontWeight.bold,
          ),
          textCell(
            _a4Money(_a4Cents(invoice.grandTotal)),
            align: pw.TextAlign.right,
            weight: pw.FontWeight.bold,
          ),
        ],
      ),
    );

    final hsnMap = <({String hsn, String rate}), Map<String, BigInt>>{};
    for (final item in invoice.items) {
      final hsn = item.hsnCode.isEmpty ? '-' : item.hsnCode;
      final key = (hsn: hsn, rate: item.gstRate);
      final row = hsnMap.putIfAbsent(
        key,
        () => {
          'taxable': BigInt.zero,
          'cgst': BigInt.zero,
          'sgst': BigInt.zero,
          'igst': BigInt.zero,
        },
      );
      row['taxable'] = row['taxable']! + _a4Cents(item.taxableAmount);
      row['cgst'] = row['cgst']! + _a4Cents(item.cgstAmount);
      row['sgst'] = row['sgst']! + _a4Cents(item.sgstAmount);
      row['igst'] = row['igst']! + _a4Cents(item.igstAmount);
    }

    final isInterstate = _a4Cents(invoice.igstAmount) > BigInt.zero;
    pw.Widget gstTable() {
      if (isInterstate) {
        return pw.Table(
          border: pw.TableBorder.all(width: 0.55),
          columnWidths: const {
            0: pw.FlexColumnWidth(2),
            1: pw.FlexColumnWidth(2),
            2: pw.FlexColumnWidth(1),
            3: pw.FlexColumnWidth(1),
            4: pw.FlexColumnWidth(2),
          },
          children: [
            pw.TableRow(
              children: [
                textCell(
                  'HSN/SAC',
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.center,
                  size: 7,
                ),
                textCell(
                  'Taxable Amount',
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.center,
                  size: 7,
                ),
                textCell(
                  'IGST Rate',
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.center,
                  size: 7,
                ),
                textCell(
                  'IGST Amount',
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.center,
                  size: 7,
                ),
                textCell(
                  'Total Tax Amount',
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.center,
                  size: 7,
                ),
              ],
            ),
            ...hsnMap.entries.map((entry) {
              final tax = entry.value;
              return pw.TableRow(
                children: [
                  textCell(entry.key.hsn),
                  textCell(
                    _a4Money(tax['taxable']!),
                    align: pw.TextAlign.right,
                  ),
                  textCell('${entry.key.rate}%', align: pw.TextAlign.right),
                  textCell(_a4Money(tax['igst']!), align: pw.TextAlign.right),
                  textCell(_a4Money(tax['igst']!), align: pw.TextAlign.right),
                ],
              );
            }),
            pw.TableRow(
              children: [
                textCell('Total', weight: pw.FontWeight.bold),
                textCell(
                  _a4Money(_a4Cents(invoice.taxableAmount)),
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.right,
                ),
                textCell('', weight: pw.FontWeight.bold),
                textCell(
                  _a4Money(_a4Cents(invoice.igstAmount)),
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.right,
                ),
                textCell(
                  _a4Money(_a4Cents(invoice.igstAmount)),
                  weight: pw.FontWeight.bold,
                  align: pw.TextAlign.right,
                ),
              ],
            ),
          ],
        );
      }

      final topHeader = pw.Table(
        border: pw.TableBorder.all(width: 0.55),
        columnWidths: const {
          0: pw.FlexColumnWidth(2),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(2),
          3: pw.FlexColumnWidth(2),
          4: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(
            children: [
              textCell(
                'HSN/SAC',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'Taxable Amount',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'CGST',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'SGST',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'Total Tax Amount',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
            ],
          ),
        ],
      );
      final subHeader = pw.Table(
        border: pw.TableBorder.all(width: 0.55),
        columnWidths: const {
          0: pw.FlexColumnWidth(2),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1),
          4: pw.FlexColumnWidth(1),
          5: pw.FlexColumnWidth(1),
          6: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(
            children: [
              pw.SizedBox(),
              pw.SizedBox(),
              textCell(
                'Rate',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'Amount',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'Rate',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              textCell(
                'Amount',
                weight: pw.FontWeight.bold,
                align: pw.TextAlign.center,
                size: 7,
              ),
              pw.SizedBox(),
            ],
          ),
        ],
      );
      final rows = <pw.TableRow>[];
      for (final entry in hsnMap.entries) {
        final tax = entry.value;
        final cgstRate = _a4Money(_a4Cents(entry.key.rate) ~/ BigInt.from(2));
        final rowTax = tax['cgst']! + tax['sgst']!;
        rows.add(
          pw.TableRow(
            children: [
              textCell(entry.key.hsn),
              textCell(_a4Money(tax['taxable']!), align: pw.TextAlign.right),
              textCell('$cgstRate%', align: pw.TextAlign.right),
              textCell(_a4Money(tax['cgst']!), align: pw.TextAlign.right),
              textCell('$cgstRate%', align: pw.TextAlign.right),
              textCell(_a4Money(tax['sgst']!), align: pw.TextAlign.right),
              textCell(_a4Money(rowTax), align: pw.TextAlign.right),
            ],
          ),
        );
      }
      rows.add(
        pw.TableRow(
          children: [
            textCell('Total', weight: pw.FontWeight.bold),
            textCell(
              _a4Money(_a4Cents(invoice.taxableAmount)),
              weight: pw.FontWeight.bold,
              align: pw.TextAlign.right,
            ),
            pw.SizedBox(),
            textCell(
              _a4Money(_a4Cents(invoice.cgstAmount)),
              weight: pw.FontWeight.bold,
              align: pw.TextAlign.right,
            ),
            pw.SizedBox(),
            textCell(
              _a4Money(_a4Cents(invoice.sgstAmount)),
              weight: pw.FontWeight.bold,
              align: pw.TextAlign.right,
            ),
            textCell(
              _a4Money(_a4Cents(invoice.totalTax)),
              weight: pw.FontWeight.bold,
              align: pw.TextAlign.right,
            ),
          ],
        ),
      );
      final body = pw.Table(
        border: pw.TableBorder.all(width: 0.55),
        columnWidths: const {
          0: pw.FlexColumnWidth(2),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1),
          4: pw.FlexColumnWidth(1),
          5: pw.FlexColumnWidth(1),
          6: pw.FlexColumnWidth(2),
        },
        children: rows,
      );
      return pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [topHeader, subHeader, body],
      );
    }

    final placeCode = invoice.placeOfSupply.isEmpty
        ? invoice.saleStateCode
        : invoice.placeOfSupply;
    final placeText = placeCode.contains('-')
        ? placeCode
        : '$placeCode-${_stateName(placeCode)}';
    final shopStateText =
        '${invoice.shopStateCode}-${_stateName(invoice.shopStateCode)}';

    final pageFormat = orientation == 'landscape'
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;
    document.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(14, 10, 14, 12),
        build: (_) => [
          pw.Center(
            child: pw.Column(
              children: [
                if (logo != null) pw.Image(logo, width: 46, height: 46),
                pw.SizedBox(height: 2),
                pw.Text(
                  'THANIGAI STORES',
                  style: pw.TextStyle(
                    fontSize: 17,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green800,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  testMode ? 'TAX INVOICE - TEST' : 'Tax Invoice',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 7),
          pw.Table(
            border: pw.TableBorder.all(width: 0.55),
            columnWidths: const {
              0: pw.FlexColumnWidth(55),
              1: pw.FlexColumnWidth(25),
              2: pw.FlexColumnWidth(20),
            },
            children: [
              pw.TableRow(
                children: [
                  pw.Container(
                    height: 58,
                    padding: const pw.EdgeInsets.all(5),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          sellerName,
                          style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (invoice.businessAddress.isNotEmpty)
                          pw.Text(
                            invoice.businessAddress,
                            style: const pw.TextStyle(fontSize: 7),
                          ),
                        if (invoice.businessPhone.isNotEmpty)
                          pw.Text(
                            'Phone: ${invoice.businessPhone}',
                            style: const pw.TextStyle(fontSize: 7),
                          ),
                        if (invoice.gstin.isNotEmpty)
                          pw.Text(
                            'GSTIN: ${invoice.gstin}',
                            style: const pw.TextStyle(fontSize: 7),
                          ),
                        pw.Text(
                          'State: $shopStateText',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                      ],
                    ),
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                    children: [
                      pw.Container(
                        height: 29,
                        decoration: const pw.BoxDecoration(
                          border: pw.Border(bottom: border, right: border),
                        ),
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              'Invoice No.',
                              style: pw.TextStyle(
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 7,
                              ),
                            ),
                            pw.Text(
                              invoice.invoiceNumber,
                              style: const pw.TextStyle(fontSize: 8),
                            ),
                          ],
                        ),
                      ),
                      pw.Container(
                        height: 29,
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(
                              'Place of supply',
                              style: pw.TextStyle(
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 7,
                              ),
                            ),
                            pw.Text(
                              placeText,
                              style: const pw.TextStyle(fontSize: 7),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  pw.Container(
                    height: 58,
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Date',
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 7,
                          ),
                        ),
                        pw.Text(
                          _a4FormatDateTime(invoice.createdAt),
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          pw.Container(
            width: double.infinity,
            height: 52,
            decoration: const pw.BoxDecoration(
              border: pw.Border(left: border, right: border, bottom: border),
            ),
            padding: const pw.EdgeInsets.all(4),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Business Name',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 8,
                  ),
                ),
                pw.Text(
                  invoice.customerName.isEmpty ? '-' : invoice.customerName,
                  style: const pw.TextStyle(fontSize: 7),
                ),
                pw.Text(
                  'Business address: ${invoice.customerAddress.isEmpty ? '-' : invoice.customerAddress}',
                  style: const pw.TextStyle(fontSize: 7),
                ),
                if (invoice.customerGstin.isNotEmpty)
                  pw.Text(
                    'Business GSTIN: ${invoice.customerGstin}',
                    style: const pw.TextStyle(fontSize: 7),
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Table(
            border: pw.TableBorder.all(width: 0.55),
            columnWidths: const {
              0: pw.FlexColumnWidth(12),
              1: pw.FlexColumnWidth(25),
              2: pw.FlexColumnWidth(9),
              3: pw.FlexColumnWidth(7),
              4: pw.FlexColumnWidth(12),
              5: pw.FlexColumnWidth(9),
              6: pw.FlexColumnWidth(12),
              7: pw.FlexColumnWidth(14),
            },
            children: itemRows,
          ),
          pw.SizedBox(height: 5),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Container(
                width: 410,
                height: 52,
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    left: border,
                    top: border,
                    right: border,
                    bottom: border,
                  ),
                ),
                padding: const pw.EdgeInsets.all(5),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Invoice Amount in Words',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 8,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      _a4AmountInWords(invoice.grandTotal),
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 7,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Container(
                width: 137,
                child: pw.Column(
                  mainAxisSize: pw.MainAxisSize.min,
                  children: [
                    pw.Container(
                      height: 14,
                      width: double.infinity,
                      alignment: pw.Alignment.center,
                      decoration: const pw.BoxDecoration(
                        border: pw.Border(
                          top: border,
                          right: border,
                          bottom: border,
                        ),
                      ),
                      child: pw.Text(
                        'Amount',
                        style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          fontSize: 8,
                        ),
                      ),
                    ),
                    pw.Table(
                      border: pw.TableBorder(
                        right: border,
                        bottom: border,
                        horizontalInside: border,
                        verticalInside: border,
                      ),
                      children: [
                        pw.TableRow(
                          children: [
                            textCell(
                              'Sub Total',
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 5,
                              ),
                            ),
                            textCell(
                              _a4Money(_a4Cents(invoice.subtotal)),
                              align: pw.TextAlign.right,
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 5,
                              ),
                            ),
                          ],
                        ),
                        pw.TableRow(
                          children: [
                            textCell(
                              'Total',
                              weight: pw.FontWeight.bold,
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 5,
                              ),
                            ),
                            textCell(
                              _a4Money(_a4Cents(invoice.grandTotal)),
                              align: pw.TextAlign.right,
                              weight: pw.FontWeight.bold,
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 5,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 5),
          gstTable(),
          pw.SizedBox(height: 9),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 145,
              height: 58,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'For: $sellerName',
                    style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Spacer(),
                  pw.Divider(thickness: 0.5),
                  pw.Text(
                    'Authorized Signatory',
                    style: const pw.TextStyle(fontSize: 7),
                  ),
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.SizedBox(height: 28),
          pw.SizedBox(height: 24),
          pw.Divider(
            thickness: 0.7,
            color: PdfColors.black,
            borderStyle: pw.BorderStyle.dashed,
          ),
          pw.SizedBox(height: 4),
          pw.Column(
            children: [
              pw.Text(
                'Acknowledgement',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                sellerName,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.green800,
                ),
              ),
              pw.SizedBox(height: 7),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Invoice To:',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                        pw.Text(
                          invoice.customerName.isEmpty
                              ? '-'
                              : invoice.customerName,
                          style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Invoice No. : ${invoice.invoiceNumber}',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                        pw.Text(
                          'Invoice date : ${_a4FormatDateTime(invoice.createdAt)}',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                        pw.Text(
                          'Invoice Amount : ₹${_a4Money(_a4Cents(invoice.grandTotal))}',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.SizedBox(height: 14),
                        pw.Text(
                          'Receiver\'s Seal & Sign',
                          style: const pw.TextStyle(fontSize: 7),
                        ),
                        pw.SizedBox(height: 6),
                        pw.Container(
                          width: 125,
                          child: pw.Divider(thickness: 0.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Center(
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              children: [
                pw.Container(
                  width: 70,
                  child: pw.Divider(thickness: 0.7, color: PdfColors.green800),
                ),
                pw.SizedBox(width: 8),
                pw.Text(
                  'Thank you! Visit again!',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontStyle: pw.FontStyle.italic,
                    color: PdfColors.green800,
                  ),
                ),
                pw.SizedBox(width: 8),
                pw.Container(
                  width: 70,
                  child: pw.Divider(thickness: 0.7, color: PdfColors.green800),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  // Retained as a private implementation reference; bulk A4 invoices use
  // _buildExactA4Pdf.
  // ignore: unused_element
  Future<Uint8List> _buildA4Pdf(
    SavedInvoice invoice, {
    required bool testMode,
  }) async {
    final document = pw.Document();
    final logoData = await loadShopLogoBytes(
      'assets/thanigai_stores_receipt_logo.png',
    );
    final logo = pw.MemoryImage(logoData);
    final format = PdfPageFormat.a4;
    final black = PdfColors.black;
    pw.Widget cell(
      String text, {
      bool bold = false,
      pw.TextAlign align = pw.TextAlign.left,
      double fontSize = 8,
    }) => pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );

    final itemRows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(width: 0.5)),
        ),
        children: [
          cell('S.No.', bold: true),
          cell('HSN/SAC', bold: true),
          cell('Item Name', bold: true),
          cell('Quantity', bold: true, align: pw.TextAlign.right),
          cell('Unit', bold: true),
          cell('Net Rate', bold: true, align: pw.TextAlign.right),
          cell('GST %', bold: true, align: pw.TextAlign.right),
          cell('GST Amount', bold: true, align: pw.TextAlign.right),
          cell('Amount', bold: true, align: pw.TextAlign.right),
        ],
      ),
    ];
    for (var i = 0; i < invoice.items.length; i++) {
      final item = invoice.items[i];
      final gstAmount = item.igstAmount != '0.00'
          ? item.igstAmount
          : _a4Cents(item.cgstAmount) + _a4Cents(item.sgstAmount) == BigInt.zero
          ? '0.00'
          : _a4Money(_a4Cents(item.cgstAmount) + _a4Cents(item.sgstAmount));
      itemRows.add(
        pw.TableRow(
          children: [
            cell('${i + 1}'),
            cell(item.hsnCode),
            cell(item.productName),
            cell(_a4FormatQuantity(item.quantity)),
            cell(displayProductUnit(item.unit)),
            cell(item.unitPrice, align: pw.TextAlign.right),
            cell('${item.gstRate}%', align: pw.TextAlign.right),
            cell(gstAmount, align: pw.TextAlign.right),
            cell(_a4Money(_a4Cents(item.lineTotal)), align: pw.TextAlign.right),
          ],
        ),
      );
    }
    itemRows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(width: 0.8)),
        ),
        children: [
          cell('', bold: true),
          cell('', bold: true),
          cell('Total', bold: true),
          cell(
            invoice.items
                .fold<double>(
                  0,
                  (sum, item) => sum + (double.tryParse(item.quantity) ?? 0),
                )
                .toStringAsFixed(3)
                .replaceFirst(RegExp(r'\.?0+$'), ''),
            bold: true,
            align: pw.TextAlign.right,
          ),
          cell('', bold: true),
          cell('', bold: true),
          cell('', bold: true),
          cell(
            _a4Money(_a4Cents(invoice.totalTax)),
            bold: true,
            align: pw.TextAlign.right,
          ),
          cell(
            _a4Money(_a4Cents(invoice.grandTotal)),
            bold: true,
            align: pw.TextAlign.right,
          ),
        ],
      ),
    );

    final hsnTotals = <String, BigInt>{};
    for (final item in invoice.items) {
      final key = item.hsnCode.isEmpty ? '-' : item.hsnCode;
      hsnTotals[key] =
          (hsnTotals[key] ?? BigInt.zero) + _a4Cents(item.taxableAmount);
    }

    document.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.fromLTRB(28, 24, 28, 24),
        build: (_) => [
          pw.Center(child: pw.Image(logo, width: 55, height: 55)),
          pw.SizedBox(height: 4),
          pw.Center(
            child: pw.Text(
              'TAX INVOICE',
              style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(width: 0.7, color: black),
            columnWidths: const {
              0: pw.FlexColumnWidth(4),
              1: pw.FlexColumnWidth(3),
              2: pw.FlexColumnWidth(2),
            },
            children: [
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          invoice.businessName,
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                        if (invoice.businessAddress.isNotEmpty)
                          pw.Text(
                            invoice.businessAddress,
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        if (invoice.businessPhone.isNotEmpty)
                          pw.Text(
                            'Phone: ${invoice.businessPhone}',
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        if (invoice.gstin.isNotEmpty)
                          pw.Text(
                            'GSTIN: ${invoice.gstin}',
                            style: const pw.TextStyle(fontSize: 8),
                          ),
                        pw.Text(
                          'State: ${invoice.shopStateCode}',
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Invoice No.',
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 8,
                          ),
                        ),
                        pw.Text(
                          invoice.invoiceNumber,
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                        pw.SizedBox(height: 5),
                        pw.Text(
                          'Place of supply',
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 8,
                          ),
                        ),
                        pw.Text(
                          invoice.placeOfSupply.isEmpty
                              ? invoice.saleStateCode
                              : invoice.placeOfSupply,
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Date',
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 8,
                          ),
                        ),
                        pw.Text(
                          _a4FormatDateTime(invoice.createdAt),
                          style: const pw.TextStyle(fontSize: 8),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border(
                left: const pw.BorderSide(width: 0.7),
                right: const pw.BorderSide(width: 0.7),
                bottom: const pw.BorderSide(width: 0.7),
              ),
            ),
            padding: const pw.EdgeInsets.all(6),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Bill To',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 9,
                  ),
                ),
                pw.Text(
                  'Customer Name: ${invoice.customerName.isEmpty ? '-' : invoice.customerName}',
                  style: const pw.TextStyle(fontSize: 8),
                ),
                if (invoice.customerAddress.isNotEmpty)
                  pw.Text(
                    'Address: ${invoice.customerAddress}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                if (invoice.customerGstin.isNotEmpty)
                  pw.Text(
                    'Customer GSTIN: ${invoice.customerGstin}',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(width: 0.6, color: black),
            columnWidths: const {
              0: pw.FixedColumnWidth(30),
              1: pw.FixedColumnWidth(58),
              2: pw.FlexColumnWidth(3),
              3: pw.FixedColumnWidth(52),
              4: pw.FixedColumnWidth(38),
              5: pw.FixedColumnWidth(62),
              6: pw.FixedColumnWidth(42),
              7: pw.FixedColumnWidth(58),
              8: pw.FixedColumnWidth(58),
            },
            children: itemRows,
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                flex: 6,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'Invoice amount in words',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 8,
                      ),
                    ),
                    pw.Text(
                      _a4AmountInWords(invoice.grandTotal),
                      style: pw.TextStyle(
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Expanded(
                flex: 4,
                child: pw.Table(
                  border: pw.TableBorder.all(width: 0.6),
                  children: [
                    pw.TableRow(
                      children: [
                        cell('Subtotal'),
                        cell(
                          _a4Money(_a4Cents(invoice.subtotal)),
                          align: pw.TextAlign.right,
                        ),
                      ],
                    ),
                    pw.TableRow(
                      children: [
                        cell('Taxable amount'),
                        cell(
                          _a4Money(_a4Cents(invoice.taxableAmount)),
                          align: pw.TextAlign.right,
                        ),
                      ],
                    ),
                    pw.TableRow(
                      children: [
                        cell('Total GST'),
                        cell(
                          _a4Money(_a4Cents(invoice.totalTax)),
                          align: pw.TextAlign.right,
                        ),
                      ],
                    ),
                    pw.TableRow(
                      children: [
                        cell('Grand Total', bold: true),
                        cell(
                          _a4Money(_a4Cents(invoice.grandTotal)),
                          bold: true,
                          align: pw.TextAlign.right,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(width: 0.6),
            columnWidths: const {
              0: pw.FlexColumnWidth(2),
              1: pw.FlexColumnWidth(2),
              2: pw.FlexColumnWidth(2),
              3: pw.FlexColumnWidth(2),
              4: pw.FlexColumnWidth(2),
            },
            children: [
              pw.TableRow(
                children: [
                  cell('HSN/SAC', bold: true),
                  cell('Taxable Amount', bold: true, align: pw.TextAlign.right),
                  cell('CGST', bold: true, align: pw.TextAlign.right),
                  cell('SGST', bold: true, align: pw.TextAlign.right),
                  cell('IGST', bold: true, align: pw.TextAlign.right),
                ],
              ),
              ...hsnTotals.entries.map((entry) {
                final matching = invoice.items.where(
                  (item) =>
                      (item.hsnCode.isEmpty ? '-' : item.hsnCode) == entry.key,
                );
                final cgst = matching.fold(
                  BigInt.zero,
                  (sum, item) => sum + _a4Cents(item.cgstAmount),
                );
                final sgst = matching.fold(
                  BigInt.zero,
                  (sum, item) => sum + _a4Cents(item.sgstAmount),
                );
                final igst = matching.fold(
                  BigInt.zero,
                  (sum, item) => sum + _a4Cents(item.igstAmount),
                );
                return pw.TableRow(
                  children: [
                    cell(entry.key),
                    cell(_a4Money(entry.value), align: pw.TextAlign.right),
                    cell(_a4Money(cgst), align: pw.TextAlign.right),
                    cell(_a4Money(sgst), align: pw.TextAlign.right),
                    cell(_a4Money(igst), align: pw.TextAlign.right),
                  ],
                );
              }),
              pw.TableRow(
                children: [
                  cell('Total', bold: true),
                  cell(
                    _a4Money(_a4Cents(invoice.taxableAmount)),
                    bold: true,
                    align: pw.TextAlign.right,
                  ),
                  cell(
                    _a4Money(_a4Cents(invoice.cgstAmount)),
                    bold: true,
                    align: pw.TextAlign.right,
                  ),
                  cell(
                    _a4Money(_a4Cents(invoice.sgstAmount)),
                    bold: true,
                    align: pw.TextAlign.right,
                  ),
                  cell(
                    _a4Money(_a4Cents(invoice.igstAmount)),
                    bold: true,
                    align: pw.TextAlign.right,
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    'Customer seal / signature',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                  pw.SizedBox(height: 32),
                  pw.Container(width: 130, child: pw.Divider()),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'For ${invoice.businessName}',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 9,
                    ),
                  ),
                  pw.SizedBox(height: 28),
                  pw.Container(width: 130, child: pw.Divider()),
                  pw.Text(
                    'Authorized Signature',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Divider(thickness: 0.8),
          pw.Center(
            child: pw.Column(
              children: [
                pw.Text(
                  'ACKNOWLEDGEMENT',
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 9,
                  ),
                ),
                pw.SizedBox(height: 3),
                pw.Text(
                  invoice.businessName,
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  'Received goods and verified by: ____________________',
                  style: const pw.TextStyle(fontSize: 8),
                ),
                pw.SizedBox(height: 8),
                pw.Text(
                  'Thank you! Visit us again!',
                  style: pw.TextStyle(
                    fontStyle: pw.FontStyle.italic,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  @override
  Future<bool> printReceipt(
    SavedInvoice invoice, {
    bool testMode = false,
    bool? a4Invoice,
    void Function(String notice)? onPrintNotice,
  }) async {
    final settings = await loadSettings();
    final capabilities = await Printing.info();
    if (!capabilities.canPrint || !capabilities.directPrint) {
      throw const ReceiptPrinterFailure(
        'Direct Windows printing is unavailable. Check the Windows printing service.',
      );
    }

    final printers = await Printing.listPrinters();
    Printer? selected;
    final isA4Print = a4Invoice == true;
    final desiredPrinterUrl = isA4Print
        ? settings?.a4PrinterUrl
        : settings?.printerUrl;
    final desiredPrinterName = isA4Print
        ? settings?.a4PrinterName
        : settings?.printerName;
    if (isA4Print && desiredPrinterUrl == null) {
      throw const ReceiptPrinterFailure(
        'An A4 printer is not selected. Choose and save an A4 Printer first.',
      );
    }
    if (!isA4Print && desiredPrinterUrl == null) {
      throw const ReceiptPrinterFailure(
        'A Roll/Thermal printer is not selected. Choose and save a Roll/Thermal Printer first.',
      );
    }
    for (final printer in printers) {
      if (printer.url == desiredPrinterUrl) {
        selected = printer;
        break;
      }
    }
    if (selected == null) {
      throw ReceiptPrinterFailure(
        'The selected ${isA4Print ? 'A4' : 'Roll/Thermal'} printer '
        '${desiredPrinterName == null ? '' : '"$desiredPrinterName" '}is unavailable or not installed. '
        'Select it again and save settings.',
      );
    }
    if (!selected.isAvailable) {
      throw ReceiptPrinterFailure(
        '${selected.name} is unavailable or offline. Check power, connection, paper, and the Windows printer queue.',
      );
    }

    final paperWidthMm =
        settings?.paperWidthMm ?? ReceiptPrinterSettings.defaultPaperWidthMm;
    final printableWidthMm =
        settings?.targetPrintableWidthMm ??
        ReceiptPrinterSettings.defaultPrintableWidthMm;
    try {
      if (a4Invoice == true) {
        final bytes = await _buildExactA4Pdf(
          invoice,
          testMode,
          orientation: settings?.a4Orientation ?? 'portrait',
        );
        final completed = await Printing.directPrintPdf(
          printer: selected,
          name: testMode ? 'Thanigai Stores A4 Test' : invoice.invoiceNumber,
          format: settings?.a4Orientation == 'landscape'
              ? PdfPageFormat.a4.landscape
              : PdfPageFormat.a4,
          dynamicLayout: false,
          usePrinterSettings: false,
          onLayout: (_) async => bytes,
        );
        return completed;
      }
      final receipt = await _buildReceiptPdf(
        invoice,
        paperWidthMm: paperWidthMm,
        printableWidthMm: printableWidthMm,
        testMode: testMode,
      );
      final completed = await Printing.directPrintPdf(
        printer: selected,
        name: testMode ? 'Thanigai Stores Printer Test' : invoice.invoiceNumber,
        format: receipt.format,
        dynamicLayout: false,
        usePrinterSettings: false,
        onLayout: (_) async => receipt.bytes,
      );
      return completed;
    } on PlatformException catch (error) {
      throw ReceiptPrinterFailure(
        'Windows could not print to ${selected.name}. Check that the printer is online, has paper, and that its driver supports the selected roll width. ${error.message ?? error.code}',
      );
    } catch (error) {
      throw ReceiptPrinterFailure(
        'The print job for ${selected.name} failed. Check that it is online, has paper, and that its Windows driver supports the selected roll width. $error',
      );
    }
  }
}
