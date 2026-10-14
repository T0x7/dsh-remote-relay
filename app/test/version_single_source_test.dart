import 'dart:io';

import 'package:dsh_remote_app/settings/about_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// 发版前置：**版本号必须只有一个来源**。
///
/// 历史事实（本仓真实发生过）：`pubspec.yaml` 写 `1.0.0+1`、「关于」页常量写
/// `0.1.0`、CHANGELOG 停在 `## [0.1.0]`——**三份对不上**。日常看不出来，一旦要做
/// 「检查更新」，拿哪个版本号去比就是个死结，而且症状是"提示有新版本但装不上"。
///
/// 所以这条守门把三方钉在一起：`pubspec.yaml` 为准，另两处必须跟着。
/// 不引 `package_info_plus` 读运行时包信息——那要进依赖白名单，而这个项目是
/// 自部署自签名的工具，版本一致性用守门钉住就够，不必为它多一个依赖。
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final changelog = File('CHANGELOG.md').readAsStringSync();

  test('pubspec 解析得出合法版本', () {
    final m = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 里读不到 version:');
    final parts = m!.group(1)!.split('+');
    expect(parts, hasLength(2), reason: 'version 应为 <semver>+<build>');
    expect(parts[0], matches(RegExp(r'^\d+\.\d+\.\d+$')), reason: '${parts[0]} 不是 x.y.z');
    expect(int.tryParse(parts[1]), isNotNull, reason: 'build 号应为整数');
  });

  test('「关于」页的版本常量 = pubspec 的 semver 部分', () {
    final semver = pubspecVersion().split('+').first;
    expect(kAppVersion, semver,
        reason: '「关于」页显示的版本与实际构建版本不一致 —— 用户报 bug 说的和装的对不上');
  });

  test('CHANGELOG 里有本版本的分段（发版即封版）', () {
    expect(changelog, contains('## [$kAppVersion]'),
        reason: 'CHANGELOG 缺 ## [$kAppVersion] 段：改完代码却没封版，'
            '更新检查会把「有新版」指向一个没有变更说明的版本');
  });

  test('协议版本与 docs 的钉死值一致', () {
    // design §7.3：协议按帧 v:1 钉死，App 不假设未协商的帧。
    expect(kTunnelProtocolVersion, 1);
    expect(File('../server/src/index.ts').existsSync(), isTrue,
        reason: '找不到 relay 源码，协议版本那处钉死无从对照');
  });

  test('kSourceRepository 必须是 owner/repo —— 少 owner 就是 404', () {
    // 这条守门第一次写错了方向：它只断言「不是完整 URL」，于是
    // `kSourceRepository = 'dsh-remote-relay'`（少 owner）照样放行，
    // 而更新检查拼出来的是 /repos/dsh-remote-relay/… ⇒ 404 ⇒「检查更新失败」。
    // **断言必须指向真实的失败形态**，而不是一个"看起来像"的形式。
    expect(kSourceRepository, matches(r'^[^/]+/[^/]+$'),
        reason: '更新检查拼的是 api.github.com/repos/<kSourceRepository>/…，'
            '只写仓库名会少一段 owner 直接 404');
    expect(kSourceRepository, startsWith('T0x7/'),
        reason: 'remote 指向 github.com:T0x7/dsh-remote-relay');
  });

  test('拼出来的 release 接口必须是 200（真实网络，发布后才成立）', () async {
    // 这条要联网，且只在有发布时成立——所以它**不**是守门用例，
    // 而是发版后手测。我把它写成普通 test 但默认跳过，用环境变量开。
    if (Platform.environment['DSH_CHECK_RELEASE_NET'] != '1') {
      markTestSkipped('设 DSH_CHECK_RELEASE_NET=1 才会真的打网络');
      return;
    }
    final client = HttpClient()..userAgent = 'dsh-remote-app/$kAppVersion';
    try {
      final uri = Uri.https('api.github.com',
          '/repos/$kSourceRepository/releases/latest');
      final res = await (await client.getUrl(uri)).close();
      expect(res.statusCode, 200,
          reason: '「检查更新」失败的最常见原因就是这条 URL 拼错');
    } finally {
      client.close();
    }
  });
}

String pubspecVersion() =>
    RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())!
        .group(1)!;