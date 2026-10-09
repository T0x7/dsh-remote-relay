// T0.5 probe — run once to DISCOVER, then pin the behavior in
// tls_pinning_test.dart. Usage: dart run tool/pinning_probe.dart
import 'dart:io';

void log(String s) => stdout.writeln(s);

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 49411;
  log('== probe against wss://127.0.0.1:$port (self-signed) ==');

  // 1) HttpClient.badCertificateCallback on a FRESH client instance.
  var httpCbFired = 0;
  final http = HttpClient();
  http.badCertificateCallback = (cert, host, port) {
    httpCbFired++;
    log('  [http] badCertificateCallback fired host=$host port=$port -> accept');
    return true;
  };
  try {
    final req = await http.getUrl(Uri.parse('https://127.0.0.1:$port/'));
    final res = await req.close();
    await res.drain<void>();
    log('  [http] GET status=${res.statusCode} callbackFired=$httpCbFired');
  } catch (e) {
    log('  [http] GET failed: $e (callbackFired=$httpCbFired)');
  }
  http.close(force: true);

  // 2) WebSocket.connect with the GLOBAL override installed.
  var wsCbFired = 0;
  final overrideClient = HttpClient();
  overrideClient.badCertificateCallback = (cert, host, port) {
    wsCbFired++;
    log('  [ws-global] callback fired host=$host port=$port');
    return true;
  };
  HttpOverrides.global = _FixedClientOverrides(overrideClient);
  try {
    final ws = await WebSocket.connect('wss://127.0.0.1:$port/echo')
        .timeout(const Duration(seconds: 8));
    final first = await ws.first.timeout(const Duration(seconds: 8));
    log('  [ws-global] CONNECTED, first=$first callbackFired=$wsCbFired');
    await ws.close();
  } catch (e) {
    log('  [ws-global] FAILED: $e (callbackFired=$wsCbFired)');
  }
  HttpOverrides.global = null;

  // 3) WebSocket.connect customClient parameter (fallback path).
  var customCbFired = 0;
  final custom = HttpClient();
  custom.badCertificateCallback = (cert, host, port) {
    customCbFired++;
    return true;
  };
  try {
    final ws = await WebSocket.connect('wss://127.0.0.1:$port/echo',
        customClient: custom);
    final first = await ws.first.timeout(const Duration(seconds: 8));
    log('  [ws-custom] CONNECTED, first=$first callbackFired=$customCbFired');
    await ws.close();
  } catch (e) {
    log('  [ws-custom] FAILED: $e (callbackFired=$customCbFired)');
  }
  custom.close(force: true);
  log('== probe done ==');
}

class _FixedClientOverrides extends HttpOverrides {
  _FixedClientOverrides(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}
