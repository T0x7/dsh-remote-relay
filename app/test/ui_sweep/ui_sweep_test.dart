import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_inventory.dart';
import 'ui_rules.dart';

/// UI 巡检（第一层：清单驱动的全界面走查）。
///
/// 这层抓的是**渲染与可达性**，三个判据：
/// 1. 渲染不崩、不溢出——RenderFlex overflow / layout exception 在
///    `testWidgets` 里本来就会 fail，这里负责把它和「界面为空/加载不出来」
///    这两种假绿区分开并报清楚是谁的锅；
/// 2. 关键文案都在——列表标题、详情字段名、空态引导语，漏一个就是那一行
///    被布局挤没了或没接本地化；
/// 3. 子表面双向可达——每个折叠/展开/详情都点得开**也关得掉**。
///
/// 排版与可点面积交给 `typography_test.dart`（第二层）。
///
/// **加界面只需要动 [buildUiInventory]**：这里遍历清单，不认识任何具体
/// 界面。新增一个页面却忘了登记，等于这个页面从此无人巡检——所以清单是
/// 覆盖面契约，不是便利清单。
void main() {
  final inventory = buildUiInventory();

  group('UI 巡检 · 清单覆盖', () {
    test('清单非空且 id 唯一', () {
      expect(inventory, isNotEmpty, reason: '清单空了 = 一个界面都不检查');
      final ids = inventory.map((s) => s.id).toList();
      final dupes = <String>{};
      for (final id in ids) {
        if (!dupes.add(id)) fail('清单里有重复 id：$id');
      }
    });

    test('每个界面都登记了分组与状态', () {
      for (final surface in inventory) {
        expect(surface.group, isNotEmpty, reason: '${surface.id} 缺分组');
        expect(
          surface.title,
          isNotEmpty,
          reason: '${surface.id} 缺标题（报告里会显示 None）',
        );
      }
    });
  });

  for (final surface in inventory) {
    group('UI 巡检 · ${surface.group} · ${surface.title}', () {
      testWidgets('渲染且关键文案齐全', (tester) async {
        await _runSurface(tester, surface, probes: false);

        // 包含匹配：清单里写的是关键词（「证书锁定」），页面上是
        // 「证书锁定（TOFU）」。精确匹配会把「加了个副标题」误报成「这行没了」。
        final missing = surface.requiredCopy
            .where((c) => find.textContaining(c, findRichText: true).evaluate().isEmpty)
            .toList();
        expect(
          missing,
          isEmpty,
          reason: '${surface.id} 少了这些文案（被布局挤掉 / 漏了本地化）：$missing',
        );
      });

      if (surface.probes.isNotEmpty) {
        testWidgets('子表面可达（${surface.probes.map((p) => p.name).join('、')}）',
            (tester) async {
          await _runSurface(tester, surface, probes: true);

          for (final probe in surface.probes) {
            await probe.act(tester);
            for (final expected in probe.expectAfter) {
              expect(
                find.textContaining(expected, findRichText: true).evaluate(),
                isNotEmpty,
                reason: '${surface.id} · ${probe.name}：点开之后「$expected」没出现',
              );
            }
            final fold = probe.fold;
            if (fold == null) continue;
            // 回收：同一个子表面点回去之后，它展开出来的内容必须消失。
            // 「点得开却关不掉」是折叠类控件最常见的半成品状态。
            await (probe.foldAct ?? probe.act)(tester);
            await tester.pumpAndSettle();
            for (final gone in fold) {
              expect(
                find.textContaining(gone, findRichText: true).evaluate(),
                isEmpty,
                reason: '${surface.id} · ${probe.name}：收回之后「$gone」还在',
              );
            }
          }
        });
      }
    });
  }
}

/// 把一个界面拉起来：准备 → 首帧 → 投喂 → 静置。
Future<void> _runSurface(
  WidgetTester tester,
  UiSurface surface, {
  required bool probes,
}) async {
  final kit = SweepKit();
  await surface.prepare?.call(tester, kit);

  await tester.pumpWidget(uiHost(
    Builder(builder: (context) {
      kit.hostContext = context;
      return surface.build(context, kit);
    }),
  ));
  await surface.afterFirstPump?.call(tester, kit);
  // 弹层类界面：首帧之后才有 context 可用（showModalBottomSheet 要宿主路由）。
  final openSheet = surface.openSheet;
  if (openSheet != null) {
    await openSheet(kit.hostContext!, kit);
    await tester.pumpAndSettle();
  }

  // 三个静置节奏：一次吸收投喂、一帧走动画、再一次吸收动画尾巴。
  // pumpAndSettle 单次不够——D-071 的三点脉冲与 48ms 涂帧窗口会各欠一帧。
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pumpAndSettle();

  // 空壳检测：一个界面如果什么都没渲染（builder 忘了接线 / 订阅没建立），
  // `testWidgets` 不会失败——它是绿的。把这种情况显式变成失败，否则巡检
  // 会给出一批「通过但什么都没查」的假绿。
  final rendered = find.byType(Scaffold).evaluate().isNotEmpty;
  expect(
    rendered,
    isTrue,
    reason: '${surface.id} 连 Scaffold 都没挂上，巡检没有意义',
  );
}

/// 把排版巡检暴露给其它测试文件（避免重复实现）。
UiTypographyReport sweepTypography(WidgetTester tester, String surface) =>
    inspectTypography(tester, surface: surface);

/// 汇总一份清单的覆盖面报告（`--dart-define=SWEEP_REPORT=1` 时打印）。
String coverageReport(List<UiSurface> inventory) {
  final byGroup = <String, int>{};
  for (final surface in inventory) {
    byGroup[surface.group] = (byGroup[surface.group] ?? 0) + 1;
  }
  final lines = byGroup.entries.map((e) => '${e.key}=${e.value}').join('  ');
  return 'UI 巡检覆盖面：${inventory.length} 个界面状态 · $lines';
}

/// 供报告用：某条巡检是否配了子表面探针。
int probeCount(UiSurface surface) => surface.probes.length;

/// 复用 MaterialApp 的本地化壳，给排版测试搭裸界面用。
Widget sweepHost(Widget child) => uiHost(child);