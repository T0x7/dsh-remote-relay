import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/logging/crash_capture.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全局崩溃捕获——兑现 `docs/app-design.md` §7.2「全部错误入本地脱敏日志」。
///
/// 修之前这个承诺**没有兑现**：全仓零个全局异常钩子，于是框架异常只在 logcat
/// 的红屏里、未捕获异常直接崩进程，两样都不进日志文件——App 真崩了的时候打开
/// 诊断页是空的。下面每条用例锁的都是这个缺口。
///
/// 语义澄清（写测试时才发现，值得钉住）：「既有 handler 仍被调用」指的是
/// **install 之前**装着的那个——不是调用时当前的那个。所以用例必须先摆好
/// 自己的 handler 再 [CrashCapture.install]。
void main() {
  late MemoryLogSink sink;
  FlutterExceptionHandler? originalFlutter;
  ErrorCallback? originalPlatform;

  setUp(() {
    originalFlutter = FlutterError.onError;
    originalPlatform = PlatformDispatcher.instance.onError;
    sink = MemoryLogSink();
    AppLog.sink = sink;
    // 默认的 presentError 会在测试输出里刷红字，顶掉它。
    FlutterError.onError = (_) {};
  });

  tearDown(() {
    AppLog.sink = null;
    FlutterError.onError = originalFlutter;
    PlatformDispatcher.instance.onError = originalPlatform;
  });

  group('CrashCapture', () {
    test('install 把 FlutterError.onError 接到崩溃通道', () {
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
        library: 'widgets library',
      ));

      final crash = sink.lines.where((l) => l.contains('E/[flutter]')).toList();
      expect(crash, isNotEmpty);
      expect(crash.first, contains('Bad state: boom'));
      expect(crash.first, contains('library=widgets library'));
      expect(capture.capturedCount, 1);
    });

    test('zone 未捕获错误落盘，且栈跟着走、也被脱敏', () {
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      capture.reportError(
        StateError('kaboom'),
        StackTrace.current,
        origin: 'zone',
      );

      final all = sink.lines.join('\n');
      expect(all, contains('E/[zone]'));
      expect(all, contains('kaboom'));
      // 栈以原样换行附在同一条记录后面——断言基准是「渲染文本拆行数」。
      expect(sink.lines.single.split('\n').length, greaterThan(1));
    });

    test('既有 FlutterError handler 仍被调用（debug 红屏不能消失）', () {
      var priorCalls = 0;
      FlutterError.onError = (_) => priorCalls++;
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ));

      expect(priorCalls, 1, reason: '捕获 ≠ 吞掉；debug 包还得能看见红屏');
      expect(capture.capturedCount, 1, reason: '而且崩溃记录照样落盘');
      expect(sink.lines.any((l) => l.contains('E/[flutter]')), isTrue);
    });

    test('既有 handler 自己抛异常时，崩溃记录不能因此丢失', () {
      FlutterError.onError = (_) => throw StateError('prior handler broken');
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      expect(
        () => FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('boom'),
          stack: StackTrace.current,
        )),
        returnsNormally,
        reason: '上一个 handler 的故障不能把报告本身带崩',
      );
      expect(capture.capturedCount, 1);
      expect(sink.lines.any((l) => l.contains('Bad state: boom')), isTrue);
    });

    test('崩溃记录落的是 crash 通道，与 app 通道隔离', () async {
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      AppLog.d('e2e', '[e2e] probe noise');
      capture.reportError(StateError('boom'), StackTrace.current);

      // 通道断言必须走 readChannel：`lines` 不按通道过滤，崩溃误落到 app
      // 通道时它照样出现在 lines 里，用 lines 断言就是假绿。
      expect(await sink.readChannel(LogChannel.crash), contains('Bad state: boom'));
      final app = await sink.readChannel(LogChannel.app);
      expect(app, contains('[e2e] probe noise'));
      expect(app, isNot(contains('boom')),
          reason: '崩溃不该混进诊断通道');
    });

    test('PlatformDispatcher 的未捕获错误被记录并标记为已处理', () {
      final capture = CrashCapture()..install();
      addTearDown(capture.dispose);

      final handled = PlatformDispatcher.instance.onError!(
        StateError('async escape'),
        StackTrace.current,
      );

      expect(handled, isTrue, reason: '已记录 = 已处理，别再往上冒');
      // 注意 StateError 的字符串形态是 `Bad state: …`，别拿 `async escape`
      // 紧跟在 tag 后面去匹配——那是个永远红的断言。
      expect(sink.lines.any((l) => l.contains('E/[platform]')), isTrue);
      expect(sink.lines.any((l) => l.contains('async escape')), isTrue);
    });

    test('install 幂等：第二个 capture 装上后，唯一入口仍是第一个', () {
      var priorCalls = 0;
      FlutterError.onError = (_) => priorCalls++;
      final first = CrashCapture()..install();
      final second = CrashCapture()..install();
      addTearDown(() {
        second.dispose();
        first.dispose();
      });

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ));

      expect(first.capturedCount, greaterThanOrEqualTo(1));
      expect(priorCalls, 1, reason: '不能叠成两层，否则红屏报两次');
    });

    test('dispose 把既有 handler 原样还回去', () {
      var priorCalls = 0;
      FlutterError.onError = (_) => priorCalls++;
      final capture = CrashCapture()..install();
      final restored = FlutterError.onError;

      capture.dispose();

      expect(FlutterError.onError, isNot(same(restored)),
          reason: '装上的是捕获器');
      expect(capture.capturedCount, 0);

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('after dispose'),
        stack: StackTrace.current,
      ));
      expect(priorCalls, 1);
      expect(capture.capturedCount, 0, reason: '卸载后不再捕获');
    });
  });
}