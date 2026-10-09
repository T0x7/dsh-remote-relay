import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/error_code.dart';
import '../api/relay.dart';
import '../log_hook.dart';
import 'pinned_http.dart';

/// `/dsh-remote/*` + `/api/*` client over the pinned HTTP stack (plan T1.4).
///
/// - Bearer + `Accept-Language` injected on every request (design §7.3)
/// - 429 → auto-backoff retry (bounded), then surfaces `ratelimit.hit`
/// - transport failures throw [AppError] (`network.*` / `tls.cert_changed`)
/// - HTTP status errors are RETURNED (status, body) — the caller folds in
///   SessionClock's verdict via [mapHttpError] so 401 keeps its three causes
class RelayClient {
  RelayClient({
    required this.origin,
    required this.pinned,
    required this.bearerProvider,
    this.acceptLanguage = 'zh',
    this.max429Retries = 2,
  });

  final Uri origin;
  final PinnedHttpClient pinned;
  final Future<String?> Function() bearerProvider;
  final String acceptLanguage;
  final int max429Retries;

  /// GET a JSON route. Returns (status, decodedBody-or-rawString).
  Future<(int, dynamic)> get(String path,
      {Map<String, String>? query}) async {
    final uri = query == null
        ? origin.resolve(path)
        : origin.resolve(path).replace(queryParameters: {
            ...origin.resolve(path).queryParameters,
            ...query,
          });
    return _send('GET', uri, null);
  }

  Future<(int, dynamic)> postJson(String path, Object? body) =>
      _send('POST', origin.resolve(path), body);

  Future<(int, dynamic)> delete(String path) =>
      _send('DELETE', origin.resolve(path), null);

  Future<(int, dynamic)> _send(String method, Uri uri, Object? body) async {
    var attempt = 0;
    while (true) {
      final (status, decoded) = await _once(method, uri, body);
      if (status == 429 && attempt < max429Retries) {
        attempt++;
        final delay = Duration(milliseconds: 400 * (1 << attempt));
        // Path only — query strings are never logged (call-site discipline).
        CoreLog.emit('info', 'relay',
            '429 on ${uri.path}, retry #$attempt in ${delay.inMilliseconds}ms');
        await Future<void>.delayed(delay);
        continue;
      }
      return (status, decoded);
    }
  }

  Future<(int, dynamic)> _once(String method, Uri uri, Object? body) async {
    final bearer = await bearerProvider();
    try {
      final HttpClientRequest r = switch (method) {
        'GET' => await pinned.client.getUrl(uri),
        'POST' => await pinned.client.postUrl(uri),
        'DELETE' => await pinned.client.deleteUrl(uri),
        _ => throw UnsupportedError('method $method'),
      };
      if (bearer != null) r.headers.set('Authorization', 'Bearer $bearer');
      r.headers.set('Accept-Language', acceptLanguage);
      if (body != null) {
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(body));
      }
      final res = await r.close();
      final text = await utf8.decoder.bind(res).join();
      dynamic decoded = text;
      if (text.isNotEmpty &&
          (res.headers.value('content-type') ?? '').contains('json')) {
        try {
          decoded = jsonDecode(text);
        } catch (_) {/* keep raw */}
      }
      return (res.statusCode, decoded);
    } on SocketException catch (e) {
      CoreLog.emit('warn', 'relay', '$method ${uri.path} transport: $e');
      throw classifyTransportError(e, rejectedHosts: pinned.rejectedHosts);
    } on HandshakeException catch (e) {
      CoreLog.emit('warn', 'relay', '$method ${uri.path} transport: $e');
      throw classifyTransportError(e, rejectedHosts: pinned.rejectedHosts);
    }
  }

  // ---- Typed /dsh-remote/* helpers (contract in api/relay.dart) ----

  Future<RemoteSessionSnapshot?> fetchSessionSnapshot() async {
    final (status, body) = await get('/dsh-remote/session');
    if (status != 200) return null;
    final map = body is Map<String, dynamic> ? body : null;
    if (map == null) return null;
    return RemoteSessionSnapshot.fromJson(map);
  }

  Future<UrlSessionMint?> mintUrlSession() async {
    final (status, body) = await get('/dsh-remote/url-session');
    if (status != 200 || body is! Map<String, dynamic>) return null;
    return UrlSessionMint.fromJson(body);
  }

  Future<RevokeAllResult?> revokeAll() async {
    final (status, body) = await delete('/dsh-remote/session');
    if (status != 200 || body is! Map<String, dynamic>) return null;
    return RevokeAllResult.fromJson(body);
  }

  Future<bool> setTunnel(TunnelAction action) async {
    final (status, body) = await postJson(
        '/dsh-remote/tunnel', {'action': action.name});
    return status == 200 && body == true;
  }
}
