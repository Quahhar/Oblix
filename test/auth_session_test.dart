// Session-persistence tests: the reason a signed-in user was landing back on
// the login screen after leaving the app alone for a while.
//
// The access token lives 30 minutes; the refresh token survives 90 days of
// inactivity and is renewed on every use. So the refresh path only runs after
// the app has been away — which is precisely when the
// network is least reliable (radio reconnecting, DNS cold, proxy waking). These
// cover the two ways that used to cost the whole session:
//   * a refresh that failed for transport reasons must NOT end the session,
//   * the token pair must be written atomically, so a half-written pair can't
//     replay a rotated refresh token into the server's reuse detection.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/auth/auth_state.dart';
import 'package:oblix/core/network/auth_interceptor.dart';
import 'package:oblix/core/storage/secure_storage.dart';

/// In-memory stand-in for the flutter_secure_storage platform channel.
class _FakeSecureStorageChannel {
  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  final Map<String, String> values = {};
  final List<String> writes = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = (call.arguments as Map).cast<String, dynamic>();
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return values[key];
            case 'write':
              writes.add(key!);
              values[key] = args['value'] as String;
              return null;
            case 'delete':
              values.remove(key);
              return null;
            case 'containsKey':
              return values.containsKey(key);
            case 'readAll':
              return Map<String, String>.from(values);
            case 'deleteAll':
              values.clear();
              return null;
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// Adapter that answers every request with a scripted result, so no socket is
/// ever opened.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._respond);

  final FutureOr<ResponseBody> Function(RequestOptions options) _respond;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return _respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// An unsigned JWT whose `exp` is [secondsFromNow] away. Nothing under test
/// verifies the signature — only the `exp` claim is read locally.
String _jwt({required int secondsFromNow}) {
  String segment(Map<String, dynamic> map) =>
      base64Url.encode(utf8.encode(jsonEncode(map))).replaceAll('=', '');
  final exp =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsFromNow;
  return '${segment({'alg': 'none'})}.${segment({'sub': 'u1', 'exp': exp})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStorageChannel storage;

  setUp(() {
    storage = _FakeSecureStorageChannel()..install();
    AuthState.instance.markSignedIn();
  });

  tearDown(() => storage.uninstall());

  group('SecureStorage', () {
    test('writes the token pair as a single entry', () async {
      await SecureStorage.saveTokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      // One write ⇒ no window in which the device holds a stale refresh token
      // alongside a fresh access token.
      expect(storage.writes.length, 1);
      expect(await SecureStorage.getAccessToken(), 'a1');
      expect(await SecureStorage.getRefreshToken(), 'r1');
    });

    test('reads tokens written by the pre-atomic format', () async {
      storage.values['access_token'] = 'legacy-a';
      storage.values['refresh_token'] = 'legacy-r';

      expect(await SecureStorage.getAccessToken(), 'legacy-a');
      expect(await SecureStorage.getRefreshToken(), 'legacy-r');

      // Saving migrates: the legacy keys must not linger and shadow the pair.
      await SecureStorage.saveTokens(accessToken: 'a2', refreshToken: 'r2');
      expect(storage.values.containsKey('access_token'), isFalse);
      expect(storage.values.containsKey('refresh_token'), isFalse);
      expect(await SecureStorage.getAccessToken(), 'a2');
    });

    test('clearTokens removes both formats', () async {
      storage.values['access_token'] = 'legacy-a';
      storage.values['refresh_token'] = 'legacy-r';
      await SecureStorage.saveTokens(accessToken: 'a', refreshToken: 'r');

      await SecureStorage.clearTokens();

      expect(storage.values, isEmpty);
      expect(await SecureStorage.getAccessToken(), isNull);
    });
  });

  group('AuthInterceptor refresh', () {
    /// A Dio wired with the interceptor: [refresh] answers /auth/refresh,
    /// [api] answers everything else.
    ({Dio dio, _ScriptedAdapter refresh, _ScriptedAdapter api}) buildClient({
      required FutureOr<ResponseBody> Function() refresh,
      required FutureOr<ResponseBody> Function(RequestOptions o) api,
    }) {
      final refreshAdapter = _ScriptedAdapter((_) => refresh());
      final apiAdapter = _ScriptedAdapter(api);
      final refreshDio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = refreshAdapter;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
        ..httpClientAdapter = apiAdapter;
      dio.interceptors.add(AuthInterceptor(dio, refreshClient: refreshDio));
      return (dio: dio, refresh: refreshAdapter, api: apiAdapter);
    }

    test('a refresh that never reaches the server keeps the session', () async {
      await SecureStorage.saveTokens(
        accessToken: _jwt(secondsFromNow: -60),
        refreshToken: 'r1',
      );
      final client = buildClient(
        refresh: () => throw DioException.connectionError(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          reason: 'network unreachable',
        ),
        api: (_) => _json({'ok': true}, 200),
      );

      await client.dio.get('/notes').catchError((_) => Response(
            requestOptions: RequestOptions(path: '/notes'),
          ));

      // The refresh token is good for months — a dead radio is no reason to
      // throw it away and force a fresh login.
      expect(await SecureStorage.getRefreshToken(), 'r1');
      expect(AuthState.instance.status.value, AuthStatus.signedIn);
    });

    test('a 5xx from the refresh endpoint keeps the session', () async {
      await SecureStorage.saveTokens(
        accessToken: _jwt(secondsFromNow: -60),
        refreshToken: 'r1',
      );
      final client = buildClient(
        refresh: () => _json({'detail': 'bad gateway'}, 502),
        api: (_) => _json({'ok': true}, 200),
      );

      await client.dio.get('/notes').catchError((_) => Response(
            requestOptions: RequestOptions(path: '/notes'),
          ));

      expect(await SecureStorage.getRefreshToken(), 'r1');
      expect(AuthState.instance.status.value, AuthStatus.signedIn);
    });

    test('a 401 from the refresh endpoint ends the session', () async {
      await SecureStorage.saveTokens(
        accessToken: _jwt(secondsFromNow: -60),
        refreshToken: 'r1',
      );
      final client = buildClient(
        refresh: () => _json({'detail': 'Refresh token reuse detected'}, 401),
        api: (_) => _json({'ok': true}, 200),
      );

      await client.dio.get('/notes').catchError((_) => Response(
            requestOptions: RequestOptions(path: '/notes'),
          ));

      expect(await SecureStorage.getAccessToken(), isNull);
      expect(AuthState.instance.status.value, AuthStatus.signedOut);
    });

    test('an expired access token is refreshed before the request goes out',
        () async {
      await SecureStorage.saveTokens(
        accessToken: _jwt(secondsFromNow: -60),
        refreshToken: 'r1',
      );
      final fresh = _jwt(secondsFromNow: 1800);
      final seenAuthHeaders = <String?>[];
      final client = buildClient(
        refresh: () =>
            _json({'access_token': fresh, 'refresh_token': 'r2'}, 200),
        api: (o) {
          seenAuthHeaders.add(o.headers['Authorization'] as String?);
          return _json({'ok': true}, 200);
        },
      );

      await client.dio.get('/notes');

      // One request, carrying the new token: no 401 round trip was needed.
      expect(client.api.calls, 1);
      expect(seenAuthHeaders.single, 'Bearer $fresh');
      expect(await SecureStorage.getRefreshToken(), 'r2');
      expect(AuthState.instance.status.value, AuthStatus.signedIn);
    });

    test('concurrent expired requests share one refresh', () async {
      await SecureStorage.saveTokens(
        accessToken: _jwt(secondsFromNow: -60),
        refreshToken: 'r1',
      );
      final fresh = _jwt(secondsFromNow: 1800);
      final client = buildClient(
        refresh: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _json({'access_token': fresh, 'refresh_token': 'r2'}, 200);
        },
        api: (_) => _json({'ok': true}, 200),
      );

      await Future.wait([
        client.dio.get('/notes'),
        client.dio.get('/notebooks'),
        client.dio.get('/tags'),
      ]);

      // Rotating three times in parallel would burn two refresh tokens and trip
      // the server's reuse detection, revoking every session for the account.
      expect(client.refresh.calls, 1);
      expect(await SecureStorage.getRefreshToken(), 'r2');
    });
  });
}
