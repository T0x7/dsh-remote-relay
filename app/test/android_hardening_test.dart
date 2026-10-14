import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// D-113：备份 / 截屏这两条是**原生侧**改动，widget 测试进不去。
///
/// 曾经的漏洞正是这个：design §8 隐私表白纸黑字写着「不随备份出设备」，而
/// main manifest 里**根本没有** `android:allowBackup` 那一行——文档承诺了一
/// 轮，靠的是「日志落在 cache 目录」这个间接事实。凭证本身（flutter_secure_storage
/// 的偏好）是会被云备份带走的。
///
/// 所以守门直接读**文件本身**：manifest 的属性 + data_extraction_rules 的存在，
/// 以及 MainActivity 里 FLAG_SECURE 的设置。文件被删或那一行被移除时立刻变红。
void main() {
  final androidDir = Directory('android/app/src/main');
  final manifestFile = File('${androidDir.path}/AndroidManifest.xml');

  group('凭证不随备份出设备（D-113）', () {
    test('main manifest 显式声明 allowBackup=false', () {
      expect(manifestFile.existsSync(), isTrue,
          reason: 'manifest 路径变了？同步改这条守门');
      final manifest = manifestFile.readAsStringSync();
      expect(manifest, contains('android:allowBackup="false"'),
          reason: '漏了这一行 = 凭证会被云备份带走（隐私表的承诺落空）');
      expect(manifest, contains('android:fullBackupContent="false"'),
          reason: 'Android 11 及以下的 adb 备份路径也要关');
    });

    test('指向 dataExtractionRules（Android 12+ 换机迁移才拦得住）', () {
      expect(manifestFile.readAsStringSync(),
          contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
      final rules = File('${androidDir.path}/res/xml/data_extraction_rules.xml');
      expect(rules.existsSync(), isTrue,
          reason: '规则文件没了 → Android 13+ 的设备迁移会把凭证搬走');
      final body = rules.readAsStringSync();
      for (final domain in ['root', 'database', 'sharedpref', 'external', 'file']) {
        expect(body, contains('domain="$domain"'),
            reason: '漏排除 $domain ——凭证所在的正是 sharedpref');
      }
      // 两个通道都要挡：云备份 ≠ 设备迁移，只写一个漏另一个。
      expect(body, contains('<cloud-backup>'));
      expect(body, contains('<device-transfer>'));
    });
  });

  // D-114：这一组是**release-only**的洞，debug 包永远测不出来。
  //
  // Flutter 模板把 INTERNET 权限放在 src/debug 与 src/profile 的 manifest 里，
  // main（= release）没有。症状：release 包装得上、启动不崩、签名也对，但
  // **完全没有网络**——配对、控制台、更新检查一律 `SocketException: Permission
  // denied`。任何在 debug 包上做的验证（包括"启动没崩""能装上""签名正确"）
  // 都不可能发现它。所以只能静态断言。
  group('release 包必须真的有网络权限（D-114）', () {
    test('main manifest 声明 INTERNET——release 的网络全靠它', () {
      final main = manifestFile.readAsStringSync();
      expect(main, contains('android.permission.INTERNET'),
          reason: '只在 debug/profile manifest 里声明 INTERNET ⇒ release 包无网络'
              '权限，配对/控制台/更新检查全挂，而 debug 包永远看不出来');
    });

    test('配对要用相机，所以 CAMERA 也必须在 main（不只是 debug）', () {
      expect(manifestFile.readAsStringSync(),
          contains('android.permission.CAMERA'),
          reason: '同一条release-only 陷阱：扫码配对是屏 B 的主路径');
    });

    test('不给 release 留任何"只在 debug 里有"的权限', () {
      // 反向检查：把 debug manifest 独有的权限列出来，若有人只加在那里就红。
      final debugOnly = RegExp(r'android:name="android.permission.([A-Z_]+)"')
          .allMatches(File('android/app/src/debug/AndroidManifest.xml').readAsStringSync())
          .map((m) => m.group(1))
          .where((n) => n != 'INTERNET')
          .toSet();
      final mainText = manifestFile.readAsStringSync();
      for (final perm in debugOnly) {
        expect(mainText, contains('android.permission.$perm'),
            reason: '$perm 只在 debug manifest 里声明 ⇒ release 包没有它');
      }
    });
  });

  group('防截屏 / 防录屏（D-113）', () {
    test('MainActivity 设置 FLAG_SECURE', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/dshremote/dsh_remote_app/MainActivity.kt',
      );
      expect(kt.existsSync(), isTrue, reason: 'MainActivity 路径变了？同步改守门');
      final src = kt.readAsStringSync();
      expect(src, contains('WindowManager.LayoutParams.FLAG_SECURE'),
          reason: '屏 E 是真实业务内容；没有 FLAG_SECURE 就能被截屏/录屏带出去');
      expect(src, contains('setFlags('), reason: '只有引用常量、没有真正设置等于没做');
    });
  });
}
