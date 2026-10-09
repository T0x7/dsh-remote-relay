import 'package:dsh_remote_core/log_hook.dart';
import 'package:test/test.dart';

/// CoreLog 缝（logging plan P3）：默认 no-op、单 sink 转发、sink 抛错不影响
/// 网络栈。core 不该知道 sink 长什么样——它只知道「有人可能在听」。
void main() {
  tearDown(() {
    CoreLog.sink = null; // 测试间互不污染（静态缝的代价，必须还）
  });

  test('default: no sink installed → emit is a silent no-op', () {
    expect(CoreLog.sink, isNull);
    expect(
      () => CoreLog.emit('warn', 'relay', '429 on /dsh-remote/session'),
      returnsNormally,
    );
  });

  test('installed sink receives level/tag/message verbatim', () {
    final seen = <String>[];
    CoreLog.sink = (level, tag, message) => seen.add('$level|$tag|$message');

    CoreLog.emit('error', 'tofu', 'PIN MISMATCH host=relay.example.com');

    expect(seen, ['error|tofu|PIN MISMATCH host=relay.example.com']);
  });

  test('a throwing sink never breaks the caller', () {
    CoreLog.sink = (_, _, _) => throw StateError('broken sink');

    expect(
      () => CoreLog.emit('info', 'events', 'connected'),
      returnsNormally,
    );
  });

  test('emitting after sink reset back to null stays silent', () {
    CoreLog.sink = (_, _, _) {};
    CoreLog.sink = null;

    expect(() => CoreLog.emit('info', 'relay', 'retry'), returnsNormally);
  });
}
