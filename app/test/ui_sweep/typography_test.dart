import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_inventory.dart';
import 'ui_rules.dart';

/// UI 巡检（第二层）：排版与可点面积。
///
/// 第一层抓「崩没崩」，这一层抓「好不好看、能不能点」——后者没有任何编译器
/// 或框架会替你把关：一个 10pt 的说明文字、一个 24×24 的图标按钮、一个
/// 没写 style 的 `Text`，编译器全都放行，只有真机用户看得见。
///
/// 规则取**客观**项（显式字号 / 字号在集合内 / 触摸区够大），审美判断留给
/// 真机走查。但每次跑都会把字号分布和全部 finding 打出来——**静默通过等于
/// 没检查**。
void main() {
  final inventory = buildUiInventory();

  group('排版规则 · 静态判据', () {
    test('字号集合本身是合法的（没有 NaN / 负数 / 零）', () {
      for (final size in UiTypography.allowed) {
        expect(size, greaterThan(0), reason: '字号 $size 非法');
        expect(size.isFinite, isTrue, reason: '字号 $size 不是有限数');
      }
      expect(UiTypography.minBody, lessThanOrEqualTo(11));
      expect(UiTypography.minTap, greaterThanOrEqualTo(44),
          reason: 'Material 规范：可点区域不得小于 44×44');
    });
  });

  for (final surface in inventory) {
    testWidgets('排版 · ${surface.group} · ${surface.title}', (tester) async {
      final kit = SweepKit();
      await surface.prepare?.call(tester, kit);
      await tester.pumpWidget(
          uiHost(Builder(builder: (c) => surface.build(c, kit))));
      await surface.afterFirstPump?.call(tester, kit);
      await tester.pumpAndSettle();

      final report = inspectTypography(tester, surface: surface.id);
      printTypographyReport(surface.id, report);

      expect(
        report.errors,
        isEmpty,
        reason: '${surface.id} 的排版规则违规（详见上方明细）：'
            '${report.errors.join(' | ')}',
      );
    });
  }

  group('排版规则 · 不许有隐式字号', () {
    // 单独再跑一遍是因为它最容易被「顺手写的 Text」破掉：多数人不会给
    // 一行占位文字设 fontSize，于是它吃主题默认值——主题一改，这行静默变形。
    for (final surface in inventory.where((s) => s.id.startsWith('settings'))) {
      testWidgets('隐式字号 · ${surface.title}', (tester) async {
        final kit = SweepKit();
        await tester.pumpWidget(
            uiHost(Builder(builder: (c) => surface.build(c, kit))));
        await tester.pumpAndSettle();

        final report = inspectTypography(tester, surface: surface.id);
        final implicit = report.findings
            .where((f) => f.rule == 'implicit-font')
            .toList();
        expect(
          implicit,
          isEmpty,
          reason: '${surface.id} 有 ${implicit.length} 处 Text 没写 fontSize：'
              '${implicit.take(3).join(' | ')}',
        );
      });
    }
  });
}