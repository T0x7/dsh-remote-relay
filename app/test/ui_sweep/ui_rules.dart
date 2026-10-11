import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// UI 巡检的**排版与可用性规则**（第二层：静态判据）。
///
/// 第一层（`ui_sweep_test.dart`）抓的是「崩没崩、溢出没溢出」——那是
/// Flutter 自己就会报的红。这一层抓的是「好不好看、能不能点」：没有
/// 编译器会替你抱怨 h2 比正文还小，也没有框架会拦下一个 24×24 的图标按钮。
///
/// 规则分两级：
/// - **error** 必须在界面上过不去，否则测试红；
/// - **finding** 只汇总打印，由人决定要不要改——排版审美不该让 CI 变红，
///   但绝不能因为不红就没人看（runner 每次都会把明细打出来）。
class UiTypography {
  const UiTypography._();

  /// 允许出现的字号（dp）。
  ///
  /// 来自一次全树统计，不是拍脑袋：App 自绘文本用 10/10.5/11/12/12.5/13/14/16，
  /// `gpt_markdown` 自带 14/16/18/20/24 一档。**超出这个集合就是新样式**——
  /// 要么是有意的设计决策（那把它加进来并写明理由），要么是漏改。
  static final allowed = <double>{
    9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 14, 15, 16,
    18, 20, 22, 24, 28, 32,
  };

  /// 正文下限。
  ///
  /// 9.5 是**全库既有约定**——等宽时间戳、次要元信息（主机详情、会话列表、
  /// 队列表、轨迹的耗时列）一律 9.5。它比 Material 默认的 caption(12) 小一截，
  /// 但承载的是「扫一眼确认有没有」的辅助信息，不是要读的内容；真机上这一档
  /// 读得清。真要往上提到 10 是一轮**视觉改版**，不是巡检该顺手改的事——
  /// 巡检只负责把现状钉住，让改版发生在有人决定的时候。
  static const minBody = 9.5;

  /// 自绘 UI 的字号上限。超过它通常意味着标题层级失控——真机上 h2
  /// 「第三步·市场证据」独占三行的观感就出自这一档。
  static const maxAppFont = 24;

  /// 最小可点区域。AppTheme.minTouch 已经是这个值（44dp，Material 规范），
  /// 巡检只是把它从「约定」变成「事实」。
  static const minTap = AppTheme.minTouch;
}

/// 一处排版/可用性问题。
class UiFinding {
  const UiFinding({
    required this.rule,
    required this.where,
    required this.detail,
    required this.severity,
  });

  /// 规则名：`implicit-font` / `font-not-allowed` / `font-too-large` /
  /// `font-below-body-min` / `tap-target-small`。
  final String rule;
  final String where;
  final String detail;

  /// `error` 阻断，`finding` 仅汇总。
  final String severity;

  bool get isError => severity == 'error';

  @override
  String toString() => '[${severity.toUpperCase()}] $rule @ $where — $detail';
}

/// 树遍历结果。
class UiTypographyReport {
  UiTypographyReport(this.findings, this.fontHistogram);

  final List<UiFinding> findings;

  /// 字号 → 出现次数。巡检每次都会打出来：分布突然多出一档，就是有人
  /// 绕过设计体系直接写了个魔数。
  final Map<double, int> fontHistogram;

  List<UiFinding> get errors => findings.where((f) => f.isError).toList();
  List<UiFinding> get notes => findings.where((f) => !f.isError).toList();
}

/// 遍历一棵 widget 树，检查排版规则。
///
/// 判据刻意只取**客观**项：字号是不是显式给的、是不是在既有集合里、
/// 可点区域够不够大。「h2 该比正文小一号」这种主观判断留给真机走查，
/// 自动化只保证它有迹可循。
UiTypographyReport inspectTypography(WidgetTester tester, {required String surface}) {
  final findings = <UiFinding>[];
  final histogram = <double, int>{};

  for (final element in find.byType(Text).evaluate()) {
    final text = element.widget as Text;
    final style = text.style;
    final data = text.data;
    if ((data ?? '').trim().isEmpty) continue;
    // 按钮的文字样式来自 ButtonStyle / IconTheme，Text 自己不写 fontSize 是
    // **正确**写法——硬塞一个进去反而会盖掉主题。把它算成「隐式字号」会让规则
    // 天天误报，最后没人看。
    if (style == null) {
      if (_insideButton(element)) continue;
      // 隐式字号：吃 Theme 默认值，任何主题改动都会静默改掉这一行的观感。
      findings.add(UiFinding(
        rule: 'implicit-font',
        where: '$surface · ${_where(element)}',
        detail: 'Text(${_preview(data)}) 没有显式 style，字号随主题漂移',
        severity: 'error',
      ));
      continue;
    }
    final size = style.fontSize;
    if (size == null) continue;
    histogram[size] = (histogram[size] ?? 0) + 1;
    if (!UiTypography.allowed.contains(size)) {
      findings.add(UiFinding(
        rule: 'font-not-allowed',
        where: '$surface · ${_where(element)}',
        detail: '字号 $size 不在 UiTypography.allowed 里',
        severity: 'error',
      ));
    } else if (size < UiTypography.minBody) {
      findings.add(UiFinding(
        rule: 'font-below-body-min',
        where: '$surface · ${_where(element)}',
        detail: '字号 $size < 正文下限 ${UiTypography.minBody}',
        severity: 'error',
      ));
    } else if (size > UiTypography.maxAppFont) {
      findings.add(UiFinding(
        rule: 'font-too-large',
        where: '$surface · ${_where(element)}',
        detail: '字号 $size > 自绘上限 ${UiTypography.maxAppFont}，标题层级可能失控',
        severity: 'error',
      ));
    }
  }

  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    final size = rich.text.style?.fontSize;
    if (size == null) continue;
    // 看不见的东西不管它什么字号。加载态里的占位/指示器节点带着几十号的
    // 「绘制字号」，但渲染出来是 0×0——按排版判它是纯粹的噪音。
    if (!_isVisible(element)) continue;
    // 空 RichText 是布局占位（图标容器、空 span），没有可见文字——按字号判它
    // 是无意义的误报（真机上撞见过一个 44pt 的空 RichText）。
    final plain = rich.text.toPlainText();
    if (!hasVisibleText(plain)) continue;
    // 图标字形：项目用 icon font 画图标，落到 Unicode 私有使用区（PUA，
    // 0xE000–0xF8FF），字号就是图标的设计尺寸（实测见过 44 / 56）。
    // 它们不是「一段 56 号文字」，排版规则不该管——真机上它们也就那么大，
    // 恰恰是合适的。判据用码位而不是查表：PUA 就是为字形图标准备的。
    if (_isIconGlyph(plain)) continue;
    histogram[size] = (histogram[size] ?? 0) + 1;
    if (!UiTypography.allowed.contains(size)) {
      findings.add(UiFinding(
        rule: 'font-not-allowed',
        where: '$surface · ${_where(element)}',
        detail: 'RichText 字号 $size 不在 UiTypography.allowed 里',
        severity: 'error',
      ));
    }
  }

  for (final finding in inspectTapTargets(tester, surface: surface)) {
    findings.add(finding);
  }

  return UiTypographyReport(findings, histogram);
}

/// 最小可点区域巡检。
///
/// 只看语义上就是按钮的控件（IconButton / TextButton / InkWell /
/// FloatingActionButton），**不**含列表 tile —— tile 本身可以矮，但里面
/// 必须有一个够大的点击点。软键盘/小屏下 24×24 的图标是真会点不中的。
List<UiFinding> inspectTapTargets(WidgetTester tester, {required String surface}) {
  final findings = <UiFinding>[];
  final kinds = <Type, String>{
    IconButton: 'IconButton',
    TextButton: 'TextButton',
    OutlinedButton: 'OutlinedButton',
    FilledButton: 'FilledButton',
    ElevatedButton: 'ElevatedButton',
  };
  kinds.forEach((type, label) {
    for (final element in find.byType(type).evaluate()) {
      final size = element.size;
      if (size == null) continue;
      if (size.width <= 0 || size.height <= 0) continue;
      if (size.width + 0.5 < UiTypography.minTap ||
          size.height + 0.5 < UiTypography.minTap) {
        findings.add(UiFinding(
          rule: 'tap-target-small',
          where: '$surface · $label · ${_where(element)}',
          detail: '点击区 ${size.width.toStringAsFixed(1)}×'
              '${size.height.toStringAsFixed(1)} < ${UiTypography.minTap}',
          severity: 'finding',
        ));
      }
    }
  });
  return findings;
}

/// 取元素在树里的可读路径，最多三段父级——足够定位到「哪张卡的哪一行」，
/// 又不至于打出一整条从 Scaffold 开始的链。
/// 元素的可读定位串。
///
/// `Element` 没有 `parent`（parent 在 `Element` 的实现细节里不可直接拿），
/// 所以这里走 `visitAncestorElements` 的官方遍历入口，向上取三段类型名。
String _where(Element element) {
  final path = <String>[];
  element.visitAncestorElements((ancestor) {
    final name = ancestor.widget.runtimeType.toString();
    if (!name.startsWith('_')) path.add(name);
    return path.length < 3;
  });
  return path.isEmpty ? '<root>' : path.reversed.join(' > ');
}

/// 这个元素是不是某个按钮的后代。
/// 这个元素在布局里占得到地方吗（0×0 的占位不算「有内容」）。
bool _isVisible(Element element) {
  final object = element.renderObject;
  if (object is! RenderBox) return true;
  if (!object.hasSize) return false;
  return object.size.width > 0 && object.size.height > 0;
}

bool _insideButton(Element element) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    final type = ancestor.widget.runtimeType;
    if (type == TextButton ||
        type == IconButton ||
        type == OutlinedButton ||
        type == FilledButton ||
        type == ElevatedButton ||
        type == TextField ||
        type == DropdownButton ||
        type == Switch ||
        type == Slider ||
        // AppBar 标题的样式来自 AppBarTheme，AppBarTheme.of(context).titleTextStyle
        // 才是权威来源——在 Text 上硬写 fontSize 反而会盖掉主题。写 AppBar 的
        // 标准姿势就是不带 style，所以这里必须豁免。
        type == AppBar ||
        type == SliverAppBar) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// 这段纯文本有没有**可见**字符。
///
/// 光用 `trim().isEmpty` 不够：进度指示器（`CircularProgressIndicator`）内部
/// 也会挂一个只含零宽/不可见 span 的 RichText，实测带着 44pt / 56pt 的字号——
/// 那是绘制参数，不是排版。按字号去管它只会得到一条永远误报的规则。
final _invisible = RegExp(r'[\s\u200B-\u200F\u2060-\u2064\uFEFF]');

/// 整段文本是不是图标字形（全部落在 Unicode 私有使用区）。
bool _isIconGlyph(String text) => text.runes.isNotEmpty &&
    text.runes.every((rune) => rune >= 0xE000 && rune <= 0xF8FF);

bool hasVisibleText(String text) =>
    text.replaceAll(_invisible, '').trim().isNotEmpty;

String _preview(String? data) {
  if (data == null) return 'null';
  final flat = data.replaceAll('\n', '⏎');
  return flat.length <= 24 ? flat : '${flat.substring(0, 24)}…';
}

/// 把排版报告打印成人能扫的表。
///
/// 静默通过等于没检查——所以这条函数在每次巡检结束时都会跑，无论有没有
/// finding。
void printTypographyReport(String surface, UiTypographyReport report) {
  final sizes = report.fontHistogram.keys.toList()..sort();
  final spread = sizes.isEmpty ? '（无文本）' : sizes.map((s) => '$s×${report.fontHistogram[s]}').join('  ');
  // ignore: avoid_print
  print('  字号分布 · $surface · $spread');
  for (final finding in report.findings) {
    // ignore: avoid_print
    print('    $finding');
  }
}

/// 界面上必须出现的关键文案（存在性 = 内容没被裁没被翻译漏）。
///
/// 「排版合理」的一大半其实是「该显示的都在」。列表页的标题、详情的字段名、
/// 空态的引导语——漏一个就说明那一行的 layout 把它挤没了。
class SurfaceCopy {
  const SurfaceCopy(this.copies);

  final List<String> copies;

  List<String> missing(WidgetTester tester) => copies
      .where((c) => find.text(c).evaluate().isEmpty)
      .toList(growable: false);
}