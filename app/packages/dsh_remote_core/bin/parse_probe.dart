import 'package:dsh_remote_core/credentials/signed_url.dart';

void main() {
  final url = mintSignedUrl(
    relayOrigin: Uri.parse('http://127.0.0.1:8080'),
    sessionId: 'sess_test01',
    psk: 'test-psk',
    mid: '5ee0f${'0' * 58}9',
    name: 'mac-mini',
    now: DateTime.utc(2026, 10, 1, 8),
  );
  print('url=$url');
  try {
    final p = parseSignedUrl(Uri.parse(url.toString().trim()));
    print('PARSE OK name=${p.name} bearer=${p.bearer.substring(0, 20)}…');
  } catch (e) {
    print('PARSE FAIL: $e');
  }
}
