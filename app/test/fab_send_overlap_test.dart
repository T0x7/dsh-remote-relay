import 'package:dsh_remote_app/data/machine_entry.dart';
import 'package:dsh_remote_app/data/machines_repository.dart';
import 'package:dsh_remote_app/data/settings_store.dart';
import 'package:dsh_remote_app/lock/biometric_gate.dart';
import 'package:dsh_remote_app/settings/locale_store.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/app_root.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';
import 'factories.dart';

/// D-060：`新会话` FAB 压住了发送按钮。
///
/// 真机（小米 2109119BC）形态：Scaffold 的 `floatingActionButton` 默认落在右下角，
/// 而 composer 的发送按钮（`chat_pane.dart` 的 `IconButton(Icons.send)`）也在输入栏
/// 右端——两者**同一个位置**，FAB 在上层。截图里输入框只露出「发消息给 agent…」，
/// 发送按钮整个不见了。
///
/// 这不是「挤了一点」，是**主操作不可达**：能看见输入框、看得见 FAB、唯独发不出去。
///
/// 为什么之前没发现：D-048 修好了「按钮被自动恢复永久隐藏」，把入口放回来了，
/// 但没检查它落在哪儿——一个「让功能出现」的修复，恰好把另一个功能盖住了。
/// 所以这条测试盯的不是「按钮在不在」，而是「**发送按钮能不能被点到**」。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: child,
    );

// factories.dart 的签名 URL 工厂：手写那串不是 v3.176.2 的签名格式。
MachineEntry _mac() => machineFrom(mintTestUrl(name: 'mac-mini'));

void main() {
  setUp(pinChineseSystemLocale);
  tearDown(unpinSystemLocale);

  late FakeEngineGateway gateway;

  Future<void> mountConsole(WidgetTester tester) async {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
    final store = MachinesStore(
      repo: InMemoryMachinesRepository(),
      seed: [_mac()],
    );
    addTearDown(store.dispose);
    // 挂完整的 AppRoot：底栏和 console 都在里面，FAB 的定位依赖底栏之上
    // 的 Scaffold。只挂 MachinesPage 的话测不到「FAB 压住发送按钮」这个关系。
    // AppRoot 而非 DshRemoteApp：后者不透传 gatewayFactory，会真去拨 WebSocket
    // （测试里是 'Unsupported operation: Mocked response'）。
    await tester.pumpWidget(_host(AppRoot(
      store: store,
      settings: SettingsStore(storage: MemStorage()),
      localeStore: LocaleStore(storage: MemStorage()),
      biometricGate: _NoBiometrics(),
      gatewayFactory: (_) => gateway,
    )));
    // pumpAndSettle 收不住：本页有 60s 轮询定时器和转圈动画（本仓既有陷阱）。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.tap(find.text('控制'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // 必须先有会话：没有会话时对话页渲染的是 `_NoSession`，连 composer 都没有
    // （`_Composer` 只在 ChatPane 的有会话分支里）。
    //
    // 走「新会话」按钮而不是手点列表：它是这次改动移动过位置的控件，用它顺带
    // 验证「挪完还能用」，也免去在列表里找一条随机会话的脆弱步骤。
    await tester.tap(find.byIcon(Icons.add_comment_outlined));
    // D-073: 新会话第一跳是 agent 预设面板——「直接新建」保持默认快路径，
    // 点它才会真正 createSession。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.tap(find.text('直接新建（默认预设）'));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // 创建出来的会话立刻给它首帧，否则 D-058 的 45s 看门狗会让 composer
    // 一直停在 loading（虽然 composer 在 loading 时也在，但断言会等它稳定）。
    gateway.pushFrame(SessionFollowFrame.fromJson({
      'type': 'snapshot',
      'header': {'sessionId': 'session-new', 'title': '新对话'},
      'projections': const <String, Object?>{},
      'records': const <Object?>[],
      'cursor': 1,
      'hasMore': false,
    }));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('发送按钮不被「新会话」挡住', (tester) async {
    await mountConsole(tester);

    final send = find.byIcon(Icons.send);
    expect(send, findsOneWidget, reason: '对话页必须有发送按钮');

    // 命中测试：点得到。修之前这里是 FAB 盖在上面，warnIfMissed 会报
    // 「hit test 落到别的 widget 上」。
    //
    // `mountConsole` 为了开出会话**故意**点过一次「新会话」，所以这里比的是
    // 增量而不是绝对值——修之前这一下会再点中 FAB，createSession 变成 2 次。
    final createdBefore = gateway.calls
        .where((c) => c.call == 'createSession')
        .length;
    await tester.tap(send, warnIfMissed: true);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    final createdAfter =
        gateway.calls.where((c) => c.call == 'createSession').length;
    expect(
      createdAfter,
      createdBefore,
      reason: '点发送按钮却创建了新会话 —— 说明这一下点到了「新会话」上',
    );
  });

  testWidgets('「新会话」不在输入栏那一行的位置上', (tester) async {
    await mountConsole(tester);

    final send = find.byIcon(Icons.send);
    final newSession = find.byIcon(Icons.add_comment_outlined);
    expect(newSession, findsOneWidget,
        reason: 'D-048 恢复的入口不该因为挪位置而消失');

    // 两个控件的矩形不许相交。相交就是「上层把下层盖住」——无论当前谁在上，
    // 这个布局在别的分段/别的输入内容下都可能反过来咬人。
    final sendRect = tester.getRect(send);
    final entryRect = tester.getRect(newSession);
    expect(
      sendRect.overlaps(entryRect),
      isFalse,
      reason: '发送按钮 $sendRect 与「新会话」入口 $entryRect 重叠了 —— '
          '主操作被遮，用户看得见输入框却发不出去',
    );
  });

  testWidgets('对话页不再有 FAB（右下角归发送按钮）', (tester) async {
    await mountConsole(tester);
    // FAB 的落点固定在右下角，而发送按钮就在那儿。有 FAB 就一定会压住它——
    // 与其算偏移量，不如让这个布局根本不存在。
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(FloatingActionButton).evaluate().isEmpty, isTrue);
  });
}

/// D-056: 一台没有生物识别的设备，锁屏据此退回手动解锁；本测试不关心它。
class _NoBiometrics implements BiometricGate {
  @override
  Future<bool> isDeviceSupported() async => false;

  @override
  Future<bool> get canCheckBiometrics async => false;

  @override
  Future<List<BiometricKind>> getAvailableBiometrics() async => const [];

  @override
  Future<BiometricResult> authenticate({required String reason}) async =>
      const BiometricResultUnavailable();
}

/// 屏 G 二级页测试里那套内存 secure storage。
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
