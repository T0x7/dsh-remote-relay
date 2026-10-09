import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_remote_app/data/secure_storage_options.dart';

/// D-054 的防再犯守卫。
///
/// 这个 bug 的恶劣之处在于**它长得像正常代码**：`const FlutterSecureStorage()`
/// 编译通过、类型正确、`flutter analyze` 不报、测试全绿，然后在真机上把用户
/// 的语言偏好和提醒/锁开关悄悄吃掉。唯一的症状是「重启后设置自己变回去了」，
/// 而那个 `hydrate()` 里原来的 `on Object { return; }` 又把唯一的线索吞了。
///
/// 人工 review 靠不住，所以钉成一条会红的测试。规则很简单：
/// **lib/ 下不允许出现未带 options 的 `const FlutterSecureStorage()`。**
///
/// 写法上有意收窄，避免误报淹没真问题：
/// - 只扫 `lib/`，排除 `l10n/generated/`（生成物）；
/// - 剥注释后再找，和 `i18n_hardcoded_test.dart` 用同一个思路（本仓大量中文注释，
///   注释里的字面量不算违规）；
/// - 放行注入用的构造（`storage ??` 那侧的注入参数、测试里的 fake），只抓
///   **默认兜底**那处的裸构造——那才是出事的写法。
/// 裸构造：`const FlutterSecureStorage()` 后**立刻**闭合，括号里没有 options。
///
/// 写成正则而不是 `line.startsWith(...)` 是有教训的：第一版守卫用了
/// 「行首匹配」，结果真实的事故写法
/// `: _storage = storage ?? const FlutterSecureStorage();` 根本不以它开头，
/// 守卫从上线起就没抓到过任何人——包括我自己的那次「加一处验证守卫有牙齿」。
/// 临时插一行 `const _probe = const FlutterSecureStorage();` 它照样放行。
///
/// 所以规则必须匹配**构造本身**，与它被赋给谁、在表达式里的哪个位置无关。
final _bareCtor = RegExp(r'const\s+FlutterSecureStorage\s*\(\s*\)');

void main() {
  group('D-054 secure storage 选项统一', () {
    test('lib/ 里没有裸的 const FlutterSecureStorage()', () {
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue,
          reason: '测试以 app/ 为工作目录运行，找不到 lib/ 说明跑错目录了');

      final files = lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.contains('l10n/generated/'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      expect(files, isNotEmpty, reason: '扫到 0 个文件＝路径过滤写错了，测试形同虚设');

      final violations = <String>[];
      for (final f in files) {
        final stripped = _stripComments(f.readAsStringSync());
        for (final m in _bareCtor.allMatches(stripped)) {
          final line = '\n'.allMatches(stripped.substring(0, m.start)).length + 1;
          violations.add('${f.path}:$line  ${m.group(0)}');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '发现 ${violations.length} 处裸的 const FlutterSecureStorage()。\n'
            'D-054：AndroidOptions.encryptedSharedPreferences 默认是 **false**，'
            '裸构造走非加密路径。它和 machines 的加密路径共用同一个 '
            'FlutterSecureStorage.xml 却是两套密钥，而加密模式初始化时跑的 '
            'checkAndMigrateToEncrypted 会重写并清理非加密条目——用户的选择会被'
            '悄悄吃掉。\n'
            '改成 `const FlutterSecureStorage(aOptions: kSecureAndroidOptions)`，'
            '常量在 lib/data/secure_storage_options.dart（那里有完整的事故记录）。\n'
            '${violations.join('\n')}',
      );
    });

    test('共享常量确实是加密模式（这个 bug 的正身）', () {
      // 直接对着插件源码钉住：`encryptedSharedPreferences` 的默认值是 false。
      // 哪天插件改默认，这条会红，提醒我们重新评估迁移路径。
      expect(kSecureAndroidOptions.toMap()['encryptedSharedPreferences'],
          'true');
      // 裸的默认构造走的是 false —— 也就是事故现场那条路。
      expect(
        const AndroidOptions().toMap()['encryptedSharedPreferences'],
        'false',
        reason: '插件默认值一旦变成 true，本守卫的必要性要重新评估（但不必删）',
      );
    });
  });
}

/// 剥掉 `//` 与 `/* */` 注释，保留行结构。
///
/// 与 `i18n_hardcoded_test.dart` 同款：一个 `//` 会被 `'https://…'` 里的冒号骗到，
/// 所以这里做一次简单的字符串态检查，够用且不引三方依赖。
String _stripComments(String src) {
  final out = StringBuffer();
  var quote = '';
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote.isNotEmpty) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = '';
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      var depth = 1;
      while (i < src.length && depth > 0) {
        if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (src[i] == '*' && i + 1 < src.length && src[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          if (src[i] == '\n') out.write('\n');
          i++;
        }
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
