import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../products/product_gateway.dart';
import 'billing_gateway.dart';
import 'receipt_preview_screen.dart';
import 'receipt_printer.dart';

class BulkOrderScreen extends StatefulWidget {
  const BulkOrderScreen({
    super.key,
    required this.productGateway,
    required this.billingGateway,
    required this.receiptPrinterGateway,
  });

  final ProductGateway productGateway;
  final BillingGateway billingGateway;
  final ReceiptPrinterGateway receiptPrinterGateway;

  @override
  State<BulkOrderScreen> createState() => _BulkOrderScreenState();
}

class _BulkOrderScreenState extends State<BulkOrderScreen> {
  final _search = TextEditingController();
  final _businessName = TextEditingController();
  final _customerAddress = TextEditingController();
  final _customerGstin = TextEditingController();
  final _placeOfSupply = TextEditingController();
  final _cart = <String, Map<String, Object>>{};
  var _products = <ProductItem>[];
  String _saleStateCode = '33';
  bool _saving = false;
  bool _gstEnabled = false;
  String _priceMode = 'exclusive';
  String? _error;
  String _shopStateCode = '33';

  @override
  void initState() {
    super.initState();
    _load('');
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await widget.billingGateway.getGstSettings();
      if (mounted) {
        setState(() {
          _shopStateCode = settings.stateCode;
          _gstEnabled = settings.gstEnabled;
          _priceMode = settings.priceMode;
        });
      }
    } on BillingFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _load(String search) async {
    try {
      final products = await widget.productGateway.searchProducts(search);
      if (mounted) setState(() => _products = products);
    } on ProductFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  BigInt _cents(String value) {
    if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(value.trim())) {
      return BigInt.zero;
    }
    final parts = value.trim().split('.');
    return BigInt.parse(parts[0]) * BigInt.from(100) +
        BigInt.parse((parts.length > 1 ? parts[1] : '').padRight(2, '0'));
  }

  String _money(BigInt cents) =>
      '${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';

  BigInt _quantityMilli(String value) {
    if (!RegExp(r'^\d+(?:\.\d{0,3})?$').hasMatch(value.trim())) {
      return BigInt.zero;
    }
    final parts = value.trim().split('.');
    return BigInt.parse(parts[0]) * BigInt.from(1000) +
        BigInt.parse((parts.length > 1 ? parts[1] : '').padRight(3, '0'));
  }

  BigInt _amountFor(Map<String, Object> item) {
    final product = item['product'] as ProductItem;
    final selling = _quantityMilli(product.sellingQuantity);
    final quantity = _quantityMilli(item['quantity'] as String);
    if (selling <= BigInt.zero) return BigInt.zero;
    final price = _cents(item['unitPrice'] as String);
    return (price * quantity + selling ~/ BigInt.from(2)) ~/ selling;
  }

  ({BigInt taxable, BigInt gst}) _taxFor(
    BigInt amount,
    String rate,
  ) {
    final rateHundredths = _cents(rate);
    if (!_gstEnabled || rateHundredths == BigInt.zero) {
      return (taxable: amount, gst: BigInt.zero);
    }
    if (_priceMode == 'inclusive') {
      final taxable =
          (amount * BigInt.from(10000) +
              (BigInt.from(10000) + rateHundredths) ~/ BigInt.from(2)) ~/
          (BigInt.from(10000) + rateHundredths);
      return (taxable: taxable, gst: amount - taxable);
    }
    return (
      taxable: amount,
      gst:
          (amount * rateHundredths + BigInt.from(5000)) ~/
          BigInt.from(10000),
    );
  }

  BigInt get _subtotal =>
      _cart.values.fold(BigInt.zero, (sum, item) => sum + _amountFor(item));

  BigInt get _taxable => _cart.values.fold(
    BigInt.zero,
    (sum, item) =>
        sum +
        _taxFor(_amountFor(item), item['gstRate'] as String).taxable,
  );

  BigInt get _gst => _cart.values.fold(
    BigInt.zero,
    (sum, item) => sum + _taxFor(_amountFor(item), item['gstRate'] as String).gst,
  );

  BigInt get _grandTotal =>
      _priceMode == 'inclusive' ? _subtotal : _taxable + _gst;

  BigInt get _cgst => _saleStateCode == _shopStateCode
      ? (_gst + BigInt.one) ~/ BigInt.from(2)
      : BigInt.zero;

  BigInt get _sgst =>
      _saleStateCode == _shopStateCode ? _gst - _cgst : BigInt.zero;

  BigInt get _igst => _saleStateCode == _shopStateCode ? BigInt.zero : _gst;

  void _add(ProductItem product) {
    setState(() {
      _cart.putIfAbsent(
        product.id,
        () => {
          'product': product,
          'quantity': formatSellingQuantity(product.sellingQuantity),
          'unitPrice': product.sellingPrice,
          'hsnCode': '',
          'gstRate': '',
        },
      );
    });
  }

  Future<void> _print(SavedInvoice invoice) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ReceiptPreviewScreen(
        invoice: invoice,
        printerGateway: widget.receiptPrinterGateway,
        a4Invoice: true,
      ),
    );
  }

  Future<void> _save() async {
    if (_cart.isEmpty || _saving) return;
    if (_businessName.text.trim().isEmpty) {
      setState(() => _error = 'Enter a Business Name.');
      return;
    }
    for (final item in _cart.values) {
      final quantity = item['quantity'] as String;
      final price = item['unitPrice'] as String;
      final hsnCode = (item['hsnCode'] as String).trim();
      final gstRate = item['gstRate'] as String;
      if (_quantityMilli(quantity) <= BigInt.zero) {
        setState(() => _error = 'Enter a valid quantity for every product.');
        return;
      }
      if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(price.trim()) ||
          _cents(price) <= BigInt.zero) {
        setState(() => _error = 'Enter a valid Price for every product.');
        return;
      }
      if (hsnCode.length > 20 ||
          !RegExp(r'^[A-Za-z0-9]*$').hasMatch(hsnCode)) {
        setState(() => _error = 'Enter a valid HSN code (letters or digits).');
        return;
      }
      if (hsnCode.isEmpty) {
        setState(() => _error = 'Enter an HSN code for every product.');
        return;
      }
      if (!RegExp(r'^\d+(?:\.\d{0,2})?$').hasMatch(gstRate.trim()) ||
          _cents(gstRate) > BigInt.from(10000)) {
        setState(() => _error = 'Enter a GST Rate from 0 to 100%.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final items = _cart.entries
          .map((entry) {
            final product = entry.value['product'] as ProductItem;
            return InvoiceCartItem(
              productId: product.id,
              quantity: entry.value['quantity'] as String,
              unitPrice: entry.value['unitPrice'] as String,
              hsnCode: (entry.value['hsnCode'] as String).trim(),
              gstRate: entry.value['gstRate'] as String,
            );
          })
          .toList(growable: false);
      final invoice = await widget.billingGateway.createInvoice(
        idempotencyKey: const Uuid().v4(),
        items: items,
        saleStateCode: _saleStateCode,
        discountAmount: '0.00',
        gstAmount: '0.00',
        payments: [
          InvoicePayment(method: 'cash', amount: _money(_grandTotal)),
        ],
        invoiceType: 'bulk',
        customerName: _businessName.text.trim(),
        customerAddress: _customerAddress.text,
        customerGstin: _customerGstin.text,
        placeOfSupply: _placeOfSupply.text,
      );
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _saving = false;
      });
      if (!mounted) return;
      await _print(invoice);
    } on BillingFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save the bulk order.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _businessName.dispose();
    _customerAddress.dispose();
    _customerGstin.dispose();
    _placeOfSupply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grand = _grandTotal;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bulk Order'),
        actions: [
          TextButton(
            key: const Key('printBulkOrderInvoiceButton'),
            onPressed: _cart.isEmpty || _saving ? null : _save,
            child: const Text('Print Bulk Order Invoice'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('bulkProductSearch'),
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Search products',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _load,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _products.length,
                      itemBuilder: (_, index) {
                        final product = _products[index];
                        return ListTile(
                          title: Text(product.name),
                          trailing: IconButton(
                            key: Key('bulkAdd-${product.id}'),
                            onPressed: () => _add(product),
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 7,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _businessName,
                      decoration: const InputDecoration(
                        labelText: 'Business Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _customerAddress,
                      decoration: const InputDecoration(
                        labelText: 'Business address',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _customerGstin,
                      decoration: const InputDecoration(
                        labelText: 'Business GSTIN',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _placeOfSupply,
                      decoration: const InputDecoration(
                        labelText: 'Place of supply',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: const Key('bulkSaleStateCode'),
                      initialValue: _saleStateCode,
                      decoration: const InputDecoration(
                        labelText: 'Place of supply state',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: '33',
                          child: Text('Tamil Nadu (33)'),
                        ),
                        DropdownMenuItem(
                          value: '32',
                          child: Text('Kerala (32)'),
                        ),
                        DropdownMenuItem(
                          value: '29',
                          child: Text('Karnataka (29)'),
                        ),
                        DropdownMenuItem(
                          value: '01',
                          child: Text('Jammu and Kashmir (01)'),
                        ),
                        DropdownMenuItem(
                          value: '07',
                          child: Text('Delhi (07)'),
                        ),
                        DropdownMenuItem(
                          value: '27',
                          child: Text('Maharashtra (27)'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _saleStateCode = value ?? '33'),
                    ),
                    const SizedBox(height: 12),
                    for (final entry in _cart.entries)
                      _BulkCartRow(
                        product: entry.value['product'] as ProductItem,
                        quantity: entry.value['quantity'] as String,
                        unitPrice: entry.value['unitPrice'] as String,
                        hsnCode: entry.value['hsnCode'] as String,
                        gstRate: entry.value['gstRate'] as String,
                        taxableAmount: _taxFor(
                          _amountFor(entry.value),
                          entry.value['gstRate'] as String,
                        ).taxable,
                        gstAmount: _taxFor(
                          _amountFor(entry.value),
                          entry.value['gstRate'] as String,
                        ).gst,
                        amount: _amountFor(entry.value),
                        onFieldChanged: (field, value) {
                          setState(() => entry.value[field] = value);
                        },
                        onRemove: () => setState(() => _cart.remove(entry.key)),
                      ),
                    const Divider(),
                    Text('Subtotal: ₹${_money(_subtotal)}'),
                    Text('Taxable Amount: ₹${_money(_taxable)}'),
                    Text('GST: ₹${_money(_gst)}'),
                    if (_cgst > BigInt.zero) Text('CGST: ₹${_money(_cgst)}'),
                    if (_sgst > BigInt.zero) Text('SGST: ₹${_money(_sgst)}'),
                    if (_igst > BigInt.zero) Text('IGST: ₹${_money(_igst)}'),
                    Text(
                      'Grand Total: ₹${_money(grand)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BulkCartRow extends StatelessWidget {
  const _BulkCartRow({
    required this.product,
    required this.quantity,
    required this.unitPrice,
    required this.hsnCode,
    required this.gstRate,
    required this.taxableAmount,
    required this.gstAmount,
    required this.amount,
    required this.onFieldChanged,
    required this.onRemove,
  });

  final ProductItem product;
  final String quantity;
  final String unitPrice;
  final String hsnCode;
  final String gstRate;
  final BigInt taxableAmount;
  final BigInt gstAmount;
  final BigInt amount;
  final void Function(String field, String value) onFieldChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    product.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: Key('bulkRemove-${product.id}'),
                  onPressed: onRemove,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _field(
                  field: 'quantity',
                  label: 'Quantity',
                  value: quantity,
                  width: 100,
                  decimal: true,
                ),
                _field(
                  field: 'unitPrice',
                  label: 'Price',
                  value: unitPrice,
                  width: 120,
                  decimal: true,
                  prefix: '₹',
                ),
                _field(
                  field: 'hsnCode',
                  label: 'HSN Code',
                  value: hsnCode,
                  width: 125,
                ),
                _field(
                  field: 'gstRate',
                  label: 'GST Rate (%)',
                  value: gstRate,
                  width: 120,
                  decimal: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Taxable: ₹${_formatMoney(taxableAmount)} · '
              'GST: ₹${_formatMoney(gstAmount)} · '
              'Amount: ₹${_formatMoney(amount)}',
              key: Key('bulkTotals-${product.id}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String field,
    required String label,
    required String value,
    required double width,
    bool decimal = false,
    String? prefix,
  }) => SizedBox(
    width: width,
    child: TextFormField(
      initialValue: value,
      key: Key('bulk${field[0].toUpperCase()}${field.substring(1)}-${product.id}'),
      keyboardType: decimal
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (value) => onFieldChanged(field, value),
    ),
  );
}

String _formatMoney(BigInt cents) =>
    '${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';
