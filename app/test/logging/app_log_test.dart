import 'dart:async';
import 'dart:io';

import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// Logging plan P5：Redactor 表驱动 + FileLogSink 滚动/缓冲/清空 + MemoryLogSink。
///
/// FileLogSink 的写路径是 fire-and-forget（目录解析、开句柄都异步），测试用
/// [_settle] 轮询到稳定态，不给产品代码加测试专用钩子。
void main() {
  group('Redactor', () {
    test('table-driven: secrets out, identifiers stay', () {
      // (input, expected) — 期望值是**整行**，逼着每个用例想清楚边界。
      const cases = <String, String>{
        // Bearer 头（大小写不敏感）。header 规则整段替换成
        // `Authorization: [REDACTED]`——比留着 Bearer 字样的形态更干净。
        'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.sig.part':
            'Authorization: [REDACTED]',
        'bearer abc123 xyz': 'Bearer [REDACTED] xyz',
        // 裸 JWT（三段式，无 Bearer 前缀）
        'got eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
                'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV back':
            'got [REDACTED] back',
        // key=value / JSON 形态
        'psk=hunter2secret': 'psk=[REDACTED]',
        '"pairingToken": "abcd1234-uuid-5678"': '"pairingToken=[REDACTED]',
        "'config' token=abcd1234 done": "'config' token=[REDACTED] done",
        'session_secret: "0123456789abcdef"': 'session_secret=[REDACTED]',
        // URL：query/fragment 剥掉，scheme+host+path 留着诊断
        'open https://relay.example.com/dsh-remote/land?t=abc123&x=1 now':
            'open https://relay.example.com/dsh-remote/land now',
        'landing at https://relay.example.com:8443/#fromQr':
            'landing at https://relay.example.com:8443/',
        // 无 query 的 URL 原样保留
        'GET https://relay.example.com/dsh-remote/session 200':
            'GET https://relay.example.com/dsh-remote/session 200',
        // 标识符按纪律**必须**留下（server logger.ts 的"identifiers"）
        '429 on /dsh-remote/session, retry #2 in 1600ms':
            '429 on /dsh-remote/session, retry #2 in 1600ms',
        'PIN MISMATCH host=relay.example.com — reject':
            'PIN MISMATCH host=relay.example.com — reject',
        'journal error session=sess_abc12 code=engine.down':
            'journal error session=sess_abc12 code=engine.down',
        // 短值（<4）不算密钥形态，不动 —— 减少误伤
        'token=ab': 'token=ab',
      };
      cases.forEach((input, expected) {
        expect(Redactor.apply(input), expected, reason: 'input: $input');
      });
    });

    test('JWT detector needs all three segments ≥8 chars', () {
      const notJwt = 'eyJshort.alsoshort.me';
      expect(Redactor.apply(notJwt), notJwt);
    });
  });

  group('FileLogSink', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('applog_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// 写路径全异步：flush()（LogSink 接口的一部分，诊断页读取前也用它）
    /// 把 in-flight 的开目录/滚动/排队行全部落稳，测试据此拿到确定态。
    Future<void> settle(FileLogSink sink) => sink.flush();

    LogLine line(String message, [LogLevel level = LogLevel.info]) =>
        LogLine(
            ts: DateTime(2026, 10, 7, 12, 30),
            level: level,
            tag: 'relay',
            message: message);

    test('writes, redacts, reads back', () async {
      final sink = FileLogSink(resolveDir: () async => dir);
      sink.write(line('Authorization: Bearer abc123secret'));
      sink.write(line('PIN MISMATCH host=relay.example.com', LogLevel.error));
      await settle(sink);

      final all = await sink.readAll();
      expect(all, contains('Authorization: [REDACTED]'));
      expect(all, isNot(contains('abc123secret')));
      expect(all, contains('E/[relay] PIN MISMATCH host=relay.example.com'));
      expect(await sink.sizeBytes(), greaterThan(0));
    });

    test('rotation keeps one generation and never loses the newest', () async {
      // maxBytes=200、每行 ~80B：写到第 3/5 行各触发一次滚动。
      final sink = FileLogSink(resolveDir: () async => dir, maxBytes: 200);
      for (var i = 1; i <= 6; i++) {
        sink.write(line('event line $i with some padding bytes here'));
      }
      await settle(sink);

      final files = await sink.files();
      expect(files.length, 2, reason: 'current + one rotated generation');
      expect(files.first.path, endsWith('.old'),
          reason: 'oldest generation first (share/read 顺序)');
      final all = await sink.readAll();
      expect(all, contains('event line 6'),
          reason: '最新一行必须在盘上——滚动永远不吞最新内容');
    });

    test('lines written before the dir resolves buffer, then drain',
        () async {
      final gate = Completer<Directory>();
      final sink =
          FileLogSink(resolveDir: () => gate.future, maxBytes: 64 * 1024);
      sink.write(line('early line one'));
      sink.write(line('early line two'));
      // 目录还没就绪：盘上必须什么都没有。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await sink.sizeBytes(), 0);

      gate.complete(dir);
      await settle(sink);
      final all = await sink.readAll();
      expect(all, contains('early line one'));
      expect(all, contains('early line two'));
    });

    test('clear empties both generations and keeps the sink usable',
        () async {
      final sink = FileLogSink(resolveDir: () async => dir);
      sink.write(line('before clear'));
      await settle(sink);

      await sink.clear();
      expect(await sink.sizeBytes(), 0);
      expect(await sink.readAll(), isEmpty);

      sink.write(line('after clear'));
      await settle(sink);
      expect(await sink.readAll(), contains('after clear'));
    });
  });

  group('MemoryLogSink', () {
    test('caps at 500 lines, oldest dropped; redaction applied; clear flags',
        () async {
      final sink = MemoryLogSink();
      for (var i = 1; i <= 501; i++) {
        sink.write(LogLine(
            ts: DateTime(2026, 10, 7),
            level: LogLevel.info,
            tag: 't',
            message: 'line $i secret=abcd1234'));
      }
      expect(sink.lines.length, 500);
      expect(sink.lines.first, contains('line 2'));
      expect(sink.lines.last, contains('line 501'));
      expect(sink.lines.first, contains('secret=[REDACTED]'));

      await sink.clear();
      expect(sink.cleared, isTrue);
      expect(sink.lines, isEmpty);
    });
  });

  group('AppLog facade', () {
    test('with a sink installed, info+ reaches it and level letters format',
        () {
      final sink = MemoryLogSink();
      final previous = AppLog.sink;
      AppLog.sink = sink;
      addTearDown(() => AppLog.sink = previous);

      AppLog.i('chat', 'hello');
      AppLog.w('lock', 'careful');
      AppLog.d('e2e', 'probe'); // debug 构建里 kDebugMode=true → 也写
      AppLog.raw('error', 'tofu', 'mismatch'); // CoreLog 缝适配器
      AppLog.raw('bogus', 'x', 'y'); // 未知级别 → info 兜底

      expect(sink.lines, hasLength(5));
      expect(sink.lines[0], contains('I/[chat] hello'));
      expect(sink.lines[1], contains('W/[lock] careful'));
      expect(sink.lines[2], contains('D/[e2e] probe'));
      expect(sink.lines[3], contains('E/[tofu] mismatch'));
      expect(sink.lines[4], contains('I/[x] y'));
    });

    test('no sink installed → calls never throw', () {
      final previous = AppLog.sink;
      AppLog.sink = null;
      addTearDown(() => AppLog.sink = previous);

      expect(() {
        AppLog.i('a', 'b');
        AppLog.e('a', 'c');
        AppLog.raw('warn', 'a', 'd');
      }, returnsNormally);
    });
  });
}
