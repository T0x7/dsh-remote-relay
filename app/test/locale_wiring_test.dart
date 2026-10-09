import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/main.dart';
import 'package:dsh_remote_app/services/app_lifecycle_gate.dart';
import 'package:dsh_remote_app/settings/locale_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 屏 G 语言页的**接线**测试（D-052）。
///
/// 同目录的 `settings_pages_test.dart` 已经证明「语言页自己会持久化」，但那
/// 是在孤立页面里测的：它把宿主 locale 直接写成期望值，于是恰好跳过了接线。
/// 真正的 bug 在这一层——`MaterialApp.locale` 写死 `const Locale('zh')`，
/// 语言页写进存储的选择**没有任何消费者**，用户点 English 只会看到
/// 存储里多了个 'en'、界面纹丝不动（和提醒开关当初一模一样）。
///
/// 所以这里测的是真机跑的那条路径：`const DshRemoteApp()`，不注入
/// localeStore 之外的任何东西，唯一的观察点是屏幕上有没有英文。
class MemStorage extends FlutterSecureStorage {
  final map = <String?, String?>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      map[key];

  @override
  Future<void> write({
    required String key,
    String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      map[key] = value;
}

void main() {
  // 「跟随系统」= 中文，否则默认的 en_US 测试平台会让「切到 English」
  // 这条断言失去意义（切之前就已经是英文了）。
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  Future<void> boot(
    WidgetTester tester, {
    required LocaleStore locale,
    required Locale system,
  }) async {
    // 注意是 `localesTestValue`（**列表**），不是 `localeTestValue`（单个）：
    // 新版 WidgetsApp 拿 `platformDispatcher.locales` 做首选列表解析，只设
    // 单个 locale 会被无视，App 静默留在默认 en——于是「切到 English」这条
    // 断言永远为真，测试变成摆设。
    tester.platformDispatcher.localeTestValue = system;
    tester.platformDispatcher.localesTestValue = [system];
    await tester.pumpWidget(DshRemoteApp(
      store: MachinesStore(repo: InMemoryMachinesRepository()),
      settings: SettingsStore(storage: MemStorage()),
      lifecycle: AppLifecycleGate(),
      localeStore: locale,
    ));
    await tester.pumpAndSettle();
  }

  tearDown(() {
    // 平台 locale 是测试间共享的全局，不还原会污染后面所有用例。
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.clearLocaleTestValue();
    binding.platformDispatcher.clearLocalesTestValue();
  });

  testWidgets('语言页选 English，整个 App 立刻变英文（不重启）', (tester) async {
    final locale = LocaleStore(storage: MemStorage());
    await boot(tester, locale: locale, system: const Locale('zh'));

    // 起点：跟随系统 = 中文。
    expect(find.text('机器'), findsWidgets);

    await tester.tap(find.text('设置')); // 底部导航
    await tester.pumpAndSettle();
    await tester.tap(find.text('语言')); // 屏 G 的语言页
    await tester.pumpAndSettle();
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    // 语言页当场改口。
    expect(find.textContaining('In effect now: English'), findsOneWidget);

    // 退回到设置页 —— 推入的路由会盖住底下的 Scaffold，所以「外壳换没换
    // 语言」只能在 pop 之后断言，否则这条检查永远为真。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // 关键断言：不是「存储里写了 en」，而是**整个界面真的变了**。
    expect(
      find.text('Machines'),
      findsWidgets,
      reason: 'MaterialApp.locale 没跟着 LocaleStore 走 —— 语言页是个零消费者的开关',
    );
    expect(
      find.text('机器'),
      findsNothing,
      reason: '底栏 + AppBar 都还停在中文，说明 locale 只换了一半',
    );
    expect(find.text('Language'), findsOneWidget);
  });

  testWidgets('选完之后重启 App，语言保持（hydrate 通路）', (tester) async {
    final storage = MemStorage();
    final first = LocaleStore(storage: storage);
    await boot(tester, locale: first, system: const Locale('zh'));

    await first.setLanguage(L10nCode.en);
    await tester.pumpAndSettle();

    // 重开进程：新的 store 指向同一份存储，只 hydrate 过一次。
    final reopened = LocaleStore(storage: storage);
    await boot(tester, locale: reopened, system: const Locale('zh'));
    expect(find.text('Machines'), findsWidgets);
    expect(find.text('机器'), findsNothing);
  });

  testWidgets('没选过时跟随系统，不被硬编码的 zh 绑死', (tester) async {
    final locale = LocaleStore(storage: MemStorage());
    await boot(tester, locale: locale, system: const Locale('en'));
    expect(find.text('Machines'), findsWidgets);
    // D-053：屏 A 空状态那句曾经是 const Text('在电脑上运行…')，英文下
    // 半屏中文。这里锁的是**接对了键**，不只是「中文字面量没了」。
    expect(find.textContaining('Run dsh-remote-client pair'), findsOneWidget);
  });
}
