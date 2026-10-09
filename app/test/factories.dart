import 'package:dsh_remote_core/credentials/signed_url.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared fixtures for widget tests — same mint algorithm as the machine
/// side, so the paste path is exercised end-to-end minus the real relay.
/// 5+58+1 = 64 — programmatic, never hand-counted.
final String testMid = '5ee0f${'0' * 58}9';

/// Mint time for fixtures that must read as **live**.
///
/// Relative to now on purpose: a signed URL carries a 24h window, so a
/// hard-coded absolute mint date turns every "live" fixture into an expired
/// one the day after the baseline is written — a time bomb that made the
/// pairing and golden suites fail on 2026-10-02 with no code change.
final DateTime liveMintTime = DateTime.now();

Uri mintTestUrl({
  String sessionId = 'sess_test01',
  String relay = 'http://127.0.0.1:8080',
  String name = 'mac-mini',
  DateTime? now,
}) =>
    mintSignedUrl(
      relayOrigin: Uri.parse(relay),
      sessionId: sessionId,
      psk: 'test-psk',
      mid: testMid,
      name: name,
      now: now ?? liveMintTime,
    );

MachineEntry machineFrom(Uri url) {
  final p = parseSignedUrl(url);
  return MachineEntry(
    id: p.sessionId,
    name: p.name ?? 'machine',
    params: p,
    firstPairedMs: p.tMs,
  );
}

/// An entry whose 24h window closed two days ago (danger card state).
MachineEntry expiredMachine() => machineFrom(mintTestUrl(
      now: DateTime.now().subtract(const Duration(days: 3)),
    ));

/// 把测试设备的系统语言钉成中文。
///
/// D-052 之后 App 不再写死 `Locale('zh')`，而是「跟随系统」——这正是语言页
/// 能生效的前提。于是任何用 `DshRemoteApp` 搭宿主、又拿中文字符串做断言的
/// 测试，都开始**依赖测试平台的默认 en_US**：pairing / screens_dghi / widget /
/// landscape / golden 五套用例曾经集体飘红，就是这个原因——它们从没写明过
/// 自己的语言前提，只是碰巧吃到了写死 zh 的红利。
///
/// 注意必须设 `localesTestValue`（**列表**）而不是 `localeTestValue`（单个）：
/// WidgetsApp 走 `platformDispatcher.locales` 做首选列表解析，只设单个
/// locale 会被静默无视，App 留在 en，症状是「改了没反应」。
///
/// 配 [unpinSystemLocale] 使用；平台 locale 是进程级共享状态，不还原会污染
/// 同一 isolate 里后续的用例。
void pinChineseSystemLocale() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.localeTestValue = const Locale('zh');
  binding.platformDispatcher.localesTestValue = const [Locale('zh')];
}

void unpinSystemLocale() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.platformDispatcher.clearLocaleTestValue();
  binding.platformDispatcher.clearLocalesTestValue();
}

/// [pinChineseSystemLocale] 的单用例版，省得每个文件各写一遍 tearDown。
void pinChineseSystemLocaleFor(WidgetTester tester) {
  pinChineseSystemLocale();
  addTearDown(unpinSystemLocale);
}
