import 'billing_gateway.dart';
import '../products/product_gateway.dart';

class ReceiptFormatter {
  static const int a4Columns = 80;

  static List<String> format(
    SavedInvoice invoice, {
    required int paperWidthMm,
    double? printableWidthMm,
    bool testMode = false,
    bool includeFooter = true,
  }) {
    if (paperWidthMm != 58 && paperWidthMm != 80) {
      throw ArgumentError.value(paperWidthMm, 'paperWidthMm');
    }
    final contentWidthMm = printableWidthMm ?? (paperWidthMm - 8).toDouble();
    if (!contentWidthMm.isFinite ||
        contentWidthMm < 40 ||
        contentWidthMm > paperWidthMm) {
      throw ArgumentError.value(printableWidthMm, 'printableWidthMm');
    }
    final columns = (contentWidthMm * 0.6).ceil();
    return _format(
      invoice,
      columns: columns,
      testMode: testMode,
      includeFooter: includeFooter,
    );
  }

  static List<String> formatA4(
    SavedInvoice invoice, {
    bool testMode = false,
    bool includeFooter = true,
  }) => _format(
    invoice,
    columns: a4Columns,
    testMode: testMode,
    includeFooter: includeFooter,
    a4Layout: true,
  );

  static List<String> formatA4Footer(
    SavedInvoice invoice, {
    bool testMode = false,
  }) {
    final lines = <String>[];
    void centered(String value) {
      for (final line in _wrap(value, a4Columns)) {
        lines.add(line.padLeft((a4Columns + line.length) ~/ 2));
      }
    }

    lines.add('-' * a4Columns);
    centered(testMode ? 'PRINTER TEST ONLY' : 'THANK YOU! VISIT US AGAIN!!');
    if (invoice.businessAddress.isNotEmpty) {
      centered(invoice.businessAddress);
    }
    if (invoice.businessPhone.isNotEmpty) {
      centered(invoice.businessPhone);
    }
    lines.add('');
    centered('Developed By ZEROPOINT LABS');
    centered('www.zeropointlabs.in');
    return List.unmodifiable(lines);
  }

  static List<String> _format(
    SavedInvoice invoice, {
    required int columns,
    required bool testMode,
    required bool includeFooter,
    bool a4Layout = false,
  }) {
    final lines = <String>[];

    void centered(String text) {
      for (final line in _wrap(text, columns)) {
        final left = ((columns - line.length) ~/ 2).clamp(0, columns);
        lines.add('${' ' * left}$line');
      }
    }

    void pair(String label, String value) {
      if (value.isEmpty) {
        lines.addAll(_wrap(label, columns));
      } else if (label.length + value.length + 2 <= columns) {
        lines.add(
          '$label${' ' * (columns - label.length - value.length)}$value',
        );
      } else {
        lines.addAll(_wrap(label, columns));
        lines.addAll(
          _wrap(value, columns).map((line) => line.padLeft(columns)),
        );
      }
    }

    void divider() => lines.add('-' * columns);

    centered(invoice.businessName.toUpperCase());
    if (invoice.gstin.isNotEmpty && !a4Layout) {
      centered('GSTIN ${invoice.gstin}');
    }
    if (testMode) centered('*** PRINTER TEST - NOT A SALE ***');
    divider();
    if (a4Layout) {
      pair(
        'Invoice No: ${invoice.invoiceNumber}',
        'Date: ${_formatDate(invoice.createdAt)}',
      );
      if (invoice.invoiceType == 'bulk') {
        pair('Bill To: ${invoice.customerName}', '');
        if (invoice.customerAddress.isNotEmpty) {
          pair('Customer Address: ${invoice.customerAddress}', '');
        }
        if (invoice.customerGstin.isNotEmpty) {
          pair('Customer GSTIN: ${invoice.customerGstin}', '');
        }
        if (invoice.placeOfSupply.isNotEmpty) {
          pair('Place of Supply: ${invoice.placeOfSupply}', '');
        }
      }
      pair('Cashier: ${invoice.cashierName}', '');
      if (invoice.gstin.isNotEmpty) pair('GSTIN: ${invoice.gstin}', '');
      divider();

      const snoWidth = 4;
      const hsnWidth = 10;
      const itemWidth = 20;
      const quantityWidth = 8;
      const unitWidth = 7;
      const rateWidth = 9;
      const gstRateWidth = 7;
      const gstAmountWidth = 8;
      lines.add(
        'S.No'.padRight(snoWidth) +
            'HSN/SAC'.padRight(hsnWidth) +
            'Item'.padRight(itemWidth) +
            'Qty'.padRight(quantityWidth) +
            'Unit'.padRight(unitWidth) +
            'Net Rate'.padRight(rateWidth) +
            'GST %'.padRight(gstRateWidth) +
            'GST Amt'.padRight(gstAmountWidth) +
            'Total'.padLeft(7),
      );
      divider();
      for (var index = 0; index < invoice.items.length; index++) {
        final item = invoice.items[index];
        final serial = '${index + 1}'.padRight(snoWidth);
        final hsn = item.hsnCode.padRight(hsnWidth);
        final names = _wrap(item.productName, itemWidth);
        final quantity = _displayQuantity(item.quantity)
            .padRight(quantityWidth);
        final unit = displayProductUnit(item.unit).padRight(unitWidth);
        final rate = _formatUnitPrice(item.unitPrice).padRight(rateWidth);
        final gstRate = '${item.gstRate}%'.padRight(gstRateWidth);
        final gstAmount =
            (item.igstAmount != '0.00'
                    ? item.igstAmount
                    : (() {
                        final cents =
                            _toCents(item.cgstAmount) +
                            _toCents(item.sgstAmount);
                        return '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
                      })())
                .padRight(gstAmountWidth);
        final total = _formatMoney(item.lineTotal).padLeft(7);
        final rowCount = names.length;
        for (var index = 0; index < rowCount; index++) {
          final name = index < names.length ? names[index] : '';
          lines.add(
            serial +
                hsn +
                name.padRight(itemWidth) +
                (index == 0 ? quantity : ''.padRight(quantityWidth)) +
                (index == 0 ? unit : ''.padRight(unitWidth)) +
                (index == 0 ? rate : ''.padRight(rateWidth)) +
                (index == 0 ? gstRate : ''.padRight(gstRateWidth)) +
                (index == 0 ? gstAmount : ''.padRight(gstAmountWidth)) +
                (index == 0 ? total : ''.padLeft(7)),
          );
        }
      }
    } else {
      pair('Bill No:', '#${invoice.invoiceNumber}');
      pair('Date:', _formatDate(invoice.createdAt, slash: true));
      pair('Cashier:', invoice.cashierName);
      divider();
      final quantityWidth = columns == 30 ? 6 : 8;
      final priceWidth = columns == 30 ? 7 : 9;
      final amountWidth = columns == 30 ? 7 : 9;
      final itemWidth = columns - quantityWidth - priceWidth - amountWidth - 3;
      final widths = [itemWidth, quantityWidth, priceWidth, amountWidth];
      _appendTableRow(
        lines,
        ['Item', 'Qty', 'Price', 'Total'],
        widths,
        rightAligned: const [false, true, true, true],
      );
      divider();
      for (final item in invoice.items) {
        _appendTableRow(
          lines,
          [
            item.productName,
            _displayQuantity(item.quantity),
            _formatUnitPrice(item.unitPrice),
            _formatMoney(item.lineTotal),
          ],
          widths,
          rightAligned: const [false, true, true, true],
        );
      }
    }

    divider();
    pair('Subtotal', _formatMoney(invoice.subtotal));
    if (a4Layout) {
      pair('Discount', _formatMoney(invoice.discountAmount));
      pair('Amount after discount', '₹${_amountAfterDiscount(invoice)}');
      if (invoice.cgstAmount != '0.00') {
        pair('CGST', _formatMoney(invoice.cgstAmount));
      }
      if (invoice.sgstAmount != '0.00') {
        pair('SGST', _formatMoney(invoice.sgstAmount));
      }
      if (invoice.igstAmount != '0.00') {
        pair('IGST', _formatMoney(invoice.igstAmount));
      }
      pair(
        'GST',
        invoice.gstEnabled ? _formatMoney(invoice.totalTax) : 'Disabled',
      );
    } else {
      if (_toCents(invoice.discountAmount) > 0) {
        pair('Discount', _formatMoney(invoice.discountAmount));
      }
      if (invoice.gstEnabled && _toCents(invoice.totalTax) > 0) {
        pair('GST', _formatMoney(invoice.totalTax));
      }
    }
    divider();
    if (a4Layout) {
      pair('TOTAL', _formatMoney(invoice.grandTotal));
    } else {
      lines.add('TOTAL  ${_formatMoney(invoice.grandTotal)}');
    }
    pair('Total Items', _displayQuantity(_itemCount(invoice)));
    final paymentMethod = invoice.payments.isEmpty
        ? 'Not recorded'
        : invoice.payments
              .map(
                (payment) =>
                    '${payment.method.toUpperCase()} ${_formatMoney(payment.amount)}',
              )
              .join(' + ');
    pair('Payment method', paymentMethod);
    if (includeFooter) {
      divider();
      centered(testMode ? 'PRINTER TEST ONLY' : 'THANK YOU! VISIT US AGAIN!!');
      if (invoice.businessAddress.isNotEmpty) {
        centered(invoice.businessAddress);
      }
      if (invoice.businessPhone.isNotEmpty) {
        centered(invoice.businessPhone);
      }
      lines.add('');
      centered('Developed By ZEROPOINT LABS');
      centered('www.zeropointlabs.in');
    }
    return List.unmodifiable(lines);
  }

  static String _amountAfterDiscount(SavedInvoice invoice) {
    final subtotalCents = _toCents(invoice.subtotal);
    final discountCents = _toCents(invoice.discountAmount);
    final amountCents = subtotalCents - discountCents;
    final sign = amountCents < 0 ? '-' : '';
    final absoluteCents = amountCents.abs();
    return '$sign${absoluteCents ~/ 100}.${(absoluteCents % 100).toString().padLeft(2, '0')}';
  }

  static void _appendTableRow(
    List<String> lines,
    List<String> values,
    List<int> widths, {
    required List<bool> rightAligned,
  }) {
    final cells = [
      for (var index = 0; index < values.length; index++)
        _wrap(values[index], widths[index]),
    ];
    final rowCount = cells
        .map((cell) => cell.length)
        .fold<int>(0, (count, length) => count > length ? count : length);
    for (var row = 0; row < rowCount; row++) {
      lines.add(
        List.generate(values.length, (column) {
          final value = row < cells[column].length ? cells[column][row] : '';
          return rightAligned[column]
              ? value.padLeft(widths[column])
              : value.padRight(widths[column]);
        }).join(' '),
      );
    }
  }

  static String _itemCount(SavedInvoice invoice) {
    final thousandths = invoice.items.fold<int>(
      0,
      (sum, item) =>
          sum + ((double.tryParse(item.quantity) ?? 0) * 1000).round(),
    );
    final whole = thousandths ~/ 1000;
    final fraction = (thousandths % 1000).abs();
    if (fraction == 0) return '$whole';
    final fractionalText = fraction.toString().padLeft(3, '0');
    return '$whole.${fractionalText.replaceFirst(RegExp(r'0+$'), '')}';
  }

  static String _displayQuantity(String value) {
    final quantity = double.tryParse(value);
    if (quantity == null || !quantity.isFinite) return value;
    return quantity.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static String _formatMoney(String value) {
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid currency amount in receipt.', value);
    }

    return '₹${match.group(1)}${match.group(2)}.'
        '${(match.group(3) ?? '').padRight(2, '0')}';
  }

  static String _formatUnitPrice(String value) {
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,6}))?$').firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid unit price in receipt.', value);
    }
    var fraction = (match.group(3) ?? '').padRight(2, '0');
    while (fraction.length > 2 && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
    return '₹${match.group(1)}${match.group(2)}.$fraction';
  }

  static int _toCents(String value) =>
      ((double.tryParse(value) ?? 0) * 100).round();

  static String _formatDate(String value, {bool slash = false}) {
    final date = DateTime.parse(value).toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final separator = slash ? '/' : '-';
    return '$day$separator$month$separator${date.year} $hour:$minute';
  }

  static List<String> _wrap(String value, int width) {
    final words = value.trim().split(RegExp(r'\s+'));
    final lines = <String>[];
    var line = '';
    for (final word in words) {
      if (word.length > width) {
        if (line.isNotEmpty) {
          lines.add(line);
          line = '';
        }
        for (var start = 0; start < word.length; start += width) {
          final end = start + width < word.length ? start + width : word.length;
          lines.add(word.substring(start, end));
        }
      } else if (line.isEmpty) {
        line = word;
      } else if (line.length + word.length + 1 <= width) {
        line = '$line $word';
      } else {
        lines.add(line);
        line = word;
      }
    }
    if (line.isNotEmpty) lines.add(line);
    return lines;
  }
}
