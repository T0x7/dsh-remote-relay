import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫测试：PRD `docs/app-design.md` §7.1 要求「全部文案经 Flutter intl
/// 资源键，**零硬编码字符串**」。
///
/// 这条测试存在的唯一理由是**防再犯**。历史事实：相机功能（屏 B）是最后
/// 一批加的，8 处硬编码中文全部留在代码里，而 arb 里早就有对应的键——
/// 翻译资源写好了、代码没接线，编译通过、测试全绿、评审也没看出来。
/// 人工 review 靠不住，所以把它钉成一条会红的测试。
///
/// 扫描规则（刻意收窄，避免误报淹没真问题）：
/// - 只扫 `lib/` 下的 `.dart`，排除 `lib/l10n/generated/`（生成物，翻译文本
///   本来就该是中文）。
/// - **先剥注释再找 CJK**：本仓大量注释是中文的，注释里的中文不算硬编码。
///   剥注释用一个小的状态机而不是正则，因为 `//` 会被 `'https://…'` 里的
///   冒号骗到。
/// - 字符串字面量**不剥**：字符串里出现 CJK 就是要显示给用户的文案（或藏在
///   字符串里的注释），一律算违规。
class _Violation {
  _Violation(this.file, this.line, this.snippet);

  final String file;
  final int line;
  final String snippet;

  @override
  String toString() => '$file:$line  $snippet';
}

/// 暂时豁免的文件。每一条都必须写明原因，且 [组 2] 会锁住这张表不许悄悄变长
/// ——豁免是欠账，不是许可证。
///
/// 现在是**空的**，而且必须保持是空的：
/// - `trajectory_projection.dart` 曾因「错误」/「返回」拼进用户可见的预览行
///   挂在这里，已由 D-049 销账（投影只吐零件，句子交给有 L10n 的 App 层）。
/// - `lib/main.dart` 曾以「由并行任务拥有，移交主线」挂在这里。移交是写好的
///   计划，不是永久豁免：D-052 拿到该文件所有权后，屏 A 空状态那句硬编码
///   中文已由 D-053 接上 `machinesEmptyBody`，欠账结清。
const _exemptions = <String, String>{};

void main() {
  group('零硬编码文案守卫', () {
    test('lib/ 代码里没有 CJK 字面量（注释除外）', () {
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue,
          reason: '测试以 app/ 为工作目录运行，找不到 lib/ 说明跑错目录了');

      final files = lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !_isGenerated(f.path))
          .where((f) => !_exemptions.containsKey(_normalize(f.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      expect(files, isNotEmpty, reason: '扫描到 0 个文件＝路径过滤写错了，测试形同虚设');

      final violations = <_Violation>[];
      for (final f in files) {
        final stripped = _stripComments(f.readAsStringSync());
        final seenLines = <int>{};
        for (final m in _cjk.allMatches(stripped)) {
          // 一行只报一次：一条 8 字的中文文案不该刷出 8 条记录。
          final line = '\n'.allMatches(stripped.substring(0, m.start)).length + 1;
          if (!seenLines.add(line)) continue;
          violations.add(
              _Violation(_normalize(f.path), line, _lineOf(stripped, m.start)));
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '发现 ${violations.length} 处 CJK 字面量。'
            'PRD 要求零硬编码：把文案搬进 lib/l10n/app_zh.arb + app_en.arb'
            '（键集必须一致），再用 L10n.of(context).<key> 取。\n'
            '${violations.join('\n')}',
      );
    });

    test('豁免表不许静默增长（每条都必须是写明原因的已知欠账）', () {
      expect(
        _exemptions.keys.toSet(),
        <String>{},
        reason: '豁免表必须保持为空。新增豁免前先确认文件的所有权：能改就直接改。\n'
            'trajectory_projection.dart（D-049 已销账）和 lib/main.dart'
            '（D-053 已销账）都曾挂在这里——「移交主线」「由别人拥有」都不是'
            '长期许可证，否则这张表会变成垃圾桶。',
      );
      for (final entry in _exemptions.entries) {
        expect(entry.value.trim(), isNotEmpty,
            reason: '${entry.key} 的豁免必须写明原因');
        expect(File(entry.key).existsSync(), isTrue,
            reason: '${entry.key} 已不存在，豁免可以删掉了');
      }
    });

    test('app_zh.arb / app_en.arb 键集完全一致', () {
      final zh = _arbKeys('lib/l10n/app_zh.arb');
      final en = _arbKeys('lib/l10n/app_en.arb');
      expect(zh, isNotEmpty);
      expect(
        zh.difference(en),
        isEmpty,
        reason: '中文侧独有的键：${zh.difference(en).toList()..sort()}',
      );
      expect(
        en.difference(zh),
        isEmpty,
        reason: '英文侧独有的键：${en.difference(zh).toList()..sort()}',
      );
    });

    test('同一个键的中英文占位符一致（漏改 {n} 会直接抛 FormatException）', () {
      final zh = _arbValues('lib/l10n/app_zh.arb');
      final en = _arbValues('lib/l10n/app_en.arb');
      for (final key in zh.keys.toList()..sort()) {
        if (!en.containsKey(key)) continue;
        expect(
          _placeholders(en[key]!),
          _placeholders(zh[key]!),
          reason: '键 $key 的占位符在 zh/en 之间不一致',
        );
      }
    });
  });
}

bool _isGenerated(String path) =>
    _normalize(path).startsWith('lib/l10n/generated/');

String _normalize(String path) => path.replaceAll(r'\', '/');

String _lineOf(String text, int index) {
  final start = text.lastIndexOf('\n', index - 1) + 1;
  final end = text.indexOf('\n', index);
  return text.substring(start, end < 0 ? text.length : end).trim();
}

/// CJK 表意文字 + CJK 标点/符号 + 全角形式。`·`（U+00B7）不在内——它在中
/// 文文案里是常用分隔符，但同时大量出现在英文文案里，按字符查会全库误报。
final _cjk = RegExp('[　-〿一-鿿＀-￯]');

Set<String> _placeholders(String value) => RegExp(r'\{(\w+)\}')
    .allMatches(value)
    .map((m) => m.group(1)!)
    .toSet();

Set<String> _arbKeys(String path) => _arbValues(path).keys.toSet();

Map<String, String> _arbValues(String path) {
  final decoded = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final out = <String, String>{};
  decoded.forEach((k, v) {
    if (k.startsWith('@')) return; // @@locale 与 @key 的元数据
    out[k] = v as String? ?? '';
  });
  return out;
}

enum _Mode { code, lineComment, blockComment, string }

/// 剥掉注释，保留字符串字面量与行号偏移。
///
/// Dart 的块注释和 `'''`/`"""` 都可以嵌套，所以两个状态都带 depth/终止符
/// 判定，不能用「找到下一个 `*/`」这种简化。
String _stripComments(String src) {
  final out = StringBuffer();
  var mode = _Mode.code;
  var depth = 0;
  var quote = '';
  var raw = false;
  var multiline = false;
  var prev = ''; // 上一个非空白字符，用来判 raw 前缀 r''

  bool identish(String c) =>
      c.isNotEmpty &&
      (RegExp(r'[A-Za-z0-9_$]').hasMatch(c));

  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';

    switch (mode) {
      case _Mode.lineComment:
        if (c == '\n') {
          mode = _Mode.code;
          out.write(c);
        }
        i++;

      case _Mode.blockComment:
        if (c == '\n') out.write(c); // 保留行号
        if (c == '/' && n == '*') {
          depth++;
          i += 2;
        } else if (c == '*' && n == '/') {
          depth--;
          i += 2;
          if (depth == 0) mode = _Mode.code;
        } else {
          i++;
        }

      case _Mode.string:
        out.write(c);
        if (!raw && c == r'\' && i + 1 < src.length) {
          out.write(src[i + 1]); // 转义：下一个字符不参与终止判定
          i += 2;
          continue;
        }
        if (multiline) {
          if (src.startsWith(quote * 3, i)) {
            out.write(quote * 2);
            i += 3;
            mode = _Mode.code;
            continue;
          }
        } else if (c == quote) {
          i++;
          mode = _Mode.code;
          continue;
        }
        i++;

      case _Mode.code:
        if (c == '/' && n == '/') {
          mode = _Mode.lineComment;
          i += 2;
          continue;
        }
        if (c == '/' && n == '*') {
          mode = _Mode.blockComment;
          depth = 1;
          i += 2;
          continue;
        }
        if (c == "'" || c == '"') {
          final triple = src.startsWith(c * 3, i);
          raw = !identish(prev) && i > 0 && src[i - 1] == 'r';
          quote = c;
          multiline = triple;
          mode = _Mode.string;
          out.write(triple ? c * 3 : c);
          i += triple ? 3 : 1;
          prev = c;
          continue;
        }
        if (c.trim().isNotEmpty) prev = c;
        out.write(c);
        i++;
    }
  }
  return out.toString();
}
