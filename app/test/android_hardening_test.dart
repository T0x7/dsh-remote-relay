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

  // D-115：又是**只在 release 出现**的洞，debug 包永远测不出来——和上面 D-114
  // 的 INTERNET 同一形状：装得上、启动不崩、权限还在、功能却整个坏掉。
  group('release 包必须真的能扫码配对（D-115）', () {
    test('存在 proguard-rules.pro 且保住了 mobile_scanner 的伴生对象', () {
      final proguard = File('android/app/proguard-rules.pro');
      expect(proguard.existsSync(), isTrue,
          reason: '文件没了 = R8 又能把 Kotlin 伴生对象剥空 ⇒ release 扫码必挂。'
              '注意 Flutter Gradle 插件是靠「这个路径的文件存在」自动追加规则的'
              '（FlutterPlugin.kt: File("\${project.projectDir}/proguard-rules.pro")），'
              '换个路径等于规则根本没进构建');
      final rules = proguard.readAsStringSync();
      expect(rules, contains('-keep class dev.steenbakker.mobile_scanner.**'),
          reason: 'mobile_scanner 的 MobileScanner.kt:46 用 `::defaultBarcodeScanner'
              'Factory`（伴生对象函数的可调用引用）。R8 full mode 把方法体内联后'
              '会判定 MobileScanner\$Companion 无人使用，连同 <clinit> 整个剥掉，'
              '而那个 lambda 仍照读 INSTANCE ⇒ BarcodeScanning.getClient() 第一行'
              ' NPE，相机压根不开。插件自带规则只 keep 了 mlkit/barhopper/photos，'
              '不覆盖它自己的类。');
      expect(rules, isNot(contains('-dontwarn dev.steenbakker.mobile_scanner')),
          reason: '别用 -dontwarn 糊过去：那是静音告警，INSTANCE 照样被剥、'
              '运行时照样 NPE');
    });

    test('只 keep CallableReference 不算数——必须 keep 住伴生对象类', () {
      final rules = File('android/app/proguard-rules.pro').readAsStringSync();
      // 被剥掉的是伴生对象上的**静态 INSTANCE 字段**（非编译期常量）。只 keep
      // CallableReference 的话，那个那个读操作照样拿到 null。这条守门防止有人把
      // 上面的规则"优化"成看似等价、实际无效的窄规则。
      expect(
        RegExp(r'^-keep\s+\S.*$', multiLine: true).allMatches(rules).any((m) =>
            !m.group(0)!.contains('{ *; }')),
        isFalse,
        reason: '出现了不带成员块（{ *; }）的 -keep：类名被 keep 了但字段/方法仍'
            '可被剥掉，INSTANCE 依旧会消失',
      );
    });

    // D-115 第二层：伴生对象修好后，NPE 只挪了一行——MlKitContext 的组件注册表
    // 返回 null，因为 ML Kit 的 *Registrar 是**反射**实例化的，R8 full mode 把
    // 它们的构造器当死代码剥了（启动日志里三条 NoSuchMethodException.<init>）。
    test('ML Kit 的反射注册类要用 ** 保住，不能只靠插件那条 *', () {
      final rules = File('android/app/proguard-rules.pro').readAsStringSync();
      expect(rules, contains('-keep class com.google.mlkit.**'),
          reason: 'ProGuard 的 * 不匹配包分隔符：只写 com.google.mlkit.* 覆盖不到 '
              'com.google.mlkit.common.internal.* / vision.barcode.internal.*，'
              '而 ML Kit 恰恰只在这些子包里放 Registrar。Registrar 构造器被剥 ⇒ '
              '注册表查不到实现 ⇒ 扫码器创建失败 ⇒ 相机一次都不开');
      expect(
          rules,
          contains(
              '-keep class com.google.android.gms.internal.mlkit_vision_barcode.**'),
          reason: 'play-services 条码模块那部分同样靠反射装配，单星号盖不住');
      // 插件自带的规则写的是单星号；别有人以为「插件已经 keep 过了」就撤掉本条。
      // 注意 `\*` 后面要加 (?!\*)：否则它会把 `**` 的第一个星号也算命中，
      // 守门就会对着**正确**的规则报红（自己写成假阳性）。
      expect(
          RegExp(r'^-keep class com\.google\.mlkit\.\*(?!\*)', multiLine: true)
              .hasMatch(rules),
          isFalse,
          reason: '单星号规则是无效的（见上），留着只会让人误以为已经覆盖');
    });

    test('扫码页把插件的真因显示出来，而不是只印 genericError', () {
      final scan = File('lib/pairing/scan_page.dart');
      expect(scan.existsSync(), isTrue, reason: 'scan_page 路径变了？同步改守门');
      final src = scan.readAsStringSync();
      expect(src, contains('errorDetails'),
          reason: 'D-115 的第二个 bug：mobile_scanner 把 start() 的任何 '
              'PlatformException 都硬编码映射成 genericError，真因只在 '
              'errorDetails 里。不打出来，下次坏掉又只能看到一句没法查的 '
              'genericError（本仓就为这个排查了一整天）');
      expect(src, contains('error.errorCode.name'),
          reason: '保留错误码本身：它和 message 一起看才有诊断价值');
    });
  });
}
