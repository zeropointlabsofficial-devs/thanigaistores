import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:malligai_kadai/auth/auth_gateway.dart';
import 'package:malligai_kadai/auth/auth_token.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sign-in token authenticates product, billing, and dashboard requests',
    () async {
      final storage = _MemorySecureStorage();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'token': 'valid-test-token',
              'user': {'id': '1', 'username': 'admin', 'role': 'admin'},
            }),
            200,
          );
        }

        expect(request.headers['authorization'], 'Bearer valid-test-token');
        return switch (request.url.path) {
          '/products' => http.Response('{"products":[]}', 200),
          '/settings/gst' => http.Response(
            '{"settings":{"gstEnabled":false,"priceMode":"exclusive","stateCode":"33","updatedAt":""}}',
            200,
          ),
          '/admin/dashboard' => http.Response(
            '{"dashboard":{"date":"2026-11-01","totalSales":"0.00","invoiceCount":0,"stockProductCount":0,"paymentSummary":[]}}',
            200,
          ),
          _ => http.Response('{"message":"Unexpected request."}', 404),
        };
      });
      final gateway = HttpAuthGateway(
        secureStorage: storage,
        httpClient: client,
      );

      await gateway.login('admin', 'password');
      expect(storage.values[authTokenStorageKey], 'valid-test-token');
      expect(await gateway.searchProducts(''), isEmpty);
      expect((await gateway.getGstSettings()).stateCode, '33');
      expect((await gateway.dashboard(DateTime(2026, 11, 1))).invoiceCount, 0);

      expect(requests.map((request) => request.url.path), [
        '/auth/login',
        '/products',
        '/settings/gst',
        '/admin/dashboard',
      ]);
    },
  );

  test('refreshes and securely persists a renewed sign-in token', () async {
    final storage = _MemorySecureStorage()
      ..values[authTokenStorageKey] = 'expired-soon-token';
    final client = MockClient((request) async {
      expect(request.url.path, '/auth/refresh');
      expect(request.headers['authorization'], 'Bearer expired-soon-token');
      return http.Response(
        jsonEncode({
          'token': 'renewed-test-token',
          'user': {'id': '1', 'username': 'admin', 'role': 'admin'},
        }),
        200,
      );
    });
    final gateway = HttpAuthGateway(secureStorage: storage, httpClient: client);

    final user = await gateway.refreshSession('expired-soon-token');

    expect(user.username, 'admin');
    expect(storage.values[authTokenStorageKey], 'renewed-test-token');
  });
}

class _MemorySecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
