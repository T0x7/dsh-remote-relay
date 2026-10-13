import 'dart:async';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// 全局崩溃捕获——兑现 `docs/app-design.md` §7.2 的契约「**全部错误**入本地
/// 脱敏日志（token/psk 不落盘）」。
///
/// 之前这个承诺**没有兑现**：全仓没有任何全局异常钩子，于是 Flutter 框架异常
/// 只进 logcat 的红屏、未捕获的 Dart 异常直接崩进程，两样都**不进 app.log**。
/// 后果很直接——App 真崩了的时候打开诊断页是空的，恰恰是最需要日志的那次。
///
/// 三个入口，覆盖 Dart 侧所有漏网出口：
/// - [FlutterError.onError]：build/layout/断言等框架错误（同时保留红屏）。
/// - `PlatformDispatcher.instance.onError`：逃出根 zone 的异步错误。
/// - [runGuarded] 的 zone handler：GUI isolate 里的未捕获错误。
///
/// 全部汇入 [LogChannel.crash]（`crash.log`，release 也落），且与 app/audit
/// 通道配额隔离——debug 探针刷屏挤不掉崩溃记录。
///
/// 单独成类（而不是写死在 `main()`）是为了可测：守门用例直接
/// `install()` + 触发 handler，不需要跑 `main()`。
class CrashCapture {
  FlutterExceptionHandler? _priorFlutterHandler;
  ErrorCallback? _priorPlatformHandler;
  bool _installed = false;

  /// 已捕获的崩溃条数——诊断页用它提示「有崩溃」，也是守门用例的断言面。
  int capturedCount = 0;

  /// 幂等。安装前先把既有 handler 存下来，[dispose] 原样还回去。
  void install() {
    if (_installed) return;
    _priorFlutterHandler = FlutterError.onError;
    _priorPlatformHandler = PlatformDispatcher.instance.onError;
    FlutterError.onError = reportFlutter;
    PlatformDispatcher.instance.onError = (error, stack) {
      reportError(error, stack, origin: 'platform');
      // 返回 true = 已被记录，不让它继续往上冒把 isolate 带走。
      return true;
    };
    _installed = true;
  }

  /// 卸载并还原既有 handler。测试 tearDown 用，生产不调用。
  void dispose() {
    if (!_installed) return;
    FlutterError.onError = _priorFlutterHandler;
    PlatformDispatcher.instance.onError = _priorPlatformHandler;
    _installed = false;
  }

  /// 在受保护 zone 里跑 [body]。**必须在 [install] 之后调用**，且 App 的
  /// 根（`runApp`）要在 [body] 里。
  void runGuarded(void Function() body) {
    runZonedGuarded(body, (error, stack) => reportError(error, stack));
  }

  /// FlutterError.onError 的实现。
  @visibleForTesting
  void reportFlutter(FlutterErrorDetails details) {
    capturedCount++;
    final library = details.library;
    AppLog.crash(
      'flutter',
      details.exception,
      details.stack,
      [
        if (details.context != null)
          'while ${ErrorDescription('${details.context}')}',
        if (library != null && library.isNotEmpty) 'library=$library',
      ].join(' '),
    );
    // 保持 Flutter 默认行为（debug 出红屏）。还原失败也不能吞掉报告本身。
    try {
      _priorFlutterHandler?.call(details);
    } catch (_) {
      // 上一个 handler 自己坏了：崩溃记录已经落盘，不追第二次。
    }
  }

  /// zone / platform 的未捕获错误。
  @visibleForTesting
  void reportError(Object error, StackTrace? stack, {String origin = 'zone'}) {
    capturedCount++;
    AppLog.crash(origin, error, stack);
  }
}