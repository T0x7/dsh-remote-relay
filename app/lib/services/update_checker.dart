import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/settings/about_info.dart';

/// D-114：检查更新（**只提示，不自动安装**）。
///
/// 为什么不自动装，两个理由都是硬的：
/// 1. **Android 没有签名密钥吊销机制**（iOS 有）。自动更新通道一旦被攻破，
///    攻击者能发布一个设备会信任的「更新」——而这个 App 能远程操控你的电脑。
/// 2. 自更新要求 App 长期持有**发布签名私钥**。这不是可选项而是前提：密钥
///    泄露只能靠**改包名**止损（等于放弃全部已装用户），密钥丢失则所有已装
///    用户都无法升级。签名密钥的安全等级比 relay 的 PSK 还高一档。
///
/// 所以只做到「知道有新版 + 能下载 + 能读变更说明」，装不装、什么时候装由人决定。
/// 将来真要做静默安装，前置是签名密钥先有安全的存放方案。
abstract class UpdateChecker {
  Future<UpdateCheck> fetch();

  static UpdateChecker instance() => _HttpUpdateChecker(kSourceRepository);
}

class _HttpUpdateChecker implements UpdateChecker {
  _HttpUpdateChecker(this.repo);

  final String repo;

  @override
  Future<UpdateCheck> fetch() async {
    final uri = Uri.https('api.github.com', '/repos/$repo/releases/latest');
    try {
      final body = await _httpGet(uri);
      final decoded = jsonDecode(body);
      if (decoded is! Map) return UpdateCheck.failed(UpdateError.badJson);
      return UpdateCheck.fromReleaseJson(decoded.cast<String, dynamic>());
    } on Object catch (e) {
      return UpdateCheck.failed('$e');
    }
  }
}

/// 测试注入缝：生产走 `dart:io`，守门用例塞一个假返回。
typedef ReleaseFetcher = Future<String> Function(Uri uri);

ReleaseFetcher releaseFetcher = _defaultFetch;

Future<String> _defaultFetch(Uri uri) async {
  final client = HttpClient()..userAgent = 'dsh-remote-app/$kAppVersion';
  try {
    final res = await (await client.getUrl(uri)).close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('GitHub ${res.statusCode}', uri: uri);
    }
    return body;
  } finally {
    client.close();
  }
}

Future<String> _httpGet(Uri uri) => releaseFetcher(uri);

/// 一次检查的结果。[available] 为 false 时 [error] / [notes] 可能为空。
class UpdateCheck {
  const UpdateCheck({
    required this.available,
    this.latest,
    this.current,
    this.url,
    this.bytes,
    this.notes,
    this.error,
  });

  UpdateCheck.failed(Object this.error)
      : available = false,
        latest = null,
        current = kAppVersion,
        url = null,
        bytes = null,
        notes = null;

  final bool available;
  final String? latest;
  final String? current;
  final String? url;
  final int? bytes;
  final String? notes;
  /// 失败原因：网络异常时是 [Object]（原始信息只进日志），解析失败时是
  /// [UpdateError]（UI 层据此取 l10n 文案——checker 不 import Flutter，
  /// 也不该硬编码中文）。
  final Object? error;

  /// 从 `releases/latest` 的 JSON 取。
  ///
  /// 两个容易踩的点：① `tag_name` 可能带 `v` 前缀；② **不能用 API 返回顺序或
  /// `published_at` 判新旧**——GitHub 的 latest 按发布时间挑而不是按版本号，
  /// 顺序一错就会把旧版当新版推给用户。唯一正确的判据是版本号本身。
  factory UpdateCheck.fromReleaseJson(Map<String, dynamic> json) {
    final raw = (json['tag_name'] as String?)?.trim();
    if (raw == null || raw.isEmpty) {
      return UpdateCheck.failed(UpdateError.noTag);
    }
    final latest = raw.startsWith('v') ? raw.substring(1) : raw;
    final asset = _pickApk(json);
    return UpdateCheck(
      available: isNewer(latest, kAppVersion),
      latest: latest,
      current: kAppVersion,
      url: asset?['browser_download_url'] as String?,
      bytes: (asset?['size'] as num?)?.toInt(),
      notes: json['body'] as String?,
    );
  }

  static Map<String, dynamic>? _pickApk(Map<String, dynamic> json) {
    final assets = json['assets'];
    if (assets is! List) return null;
    Map<String, dynamic>? fallback;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] as String? ?? '').toLowerCase();
      if (!name.endsWith('.apk')) continue;
      if (name.contains('arm64') || name.contains('universal')) {
        return a.cast<String, dynamic>();
      }
      fallback ??= a.cast<String, dynamic>();
    }
    return fallback;
  }

  /// 每次检查都留痕：将来有人问「这台手机为什么提示过新版」，答案在日志里。
  void logAudit() => AppLog.audit('update.check', attrs: {
        'latest': latest,
        'available': available,
        'bytes': bytes,
        if (error != null) 'error': error.toString(),
      });
}

/// `a` 是否比 `b` 新。三段 x.y.z 逐段比数字；相等返回 false。
///
/// 非法段按 0 处理（`1.0` ≡ `1.0.0`）——一个格式古怪的 tag 不该让整条检查
/// 路径报错，把「检查不出来」和「有新版」区分开就够了。
bool isNewer(String a, String b) {
  final av = _parts(a);
  final bv = _parts(b);
  for (var i = 0; i < 3; i++) {
    if (av[i] > bv[i]) return true;
    if (av[i] < bv[i]) return false;
  }
  return false;
}

List<int> _parts(String v) {
  final core = v.split('+').first.split('-').first;
  final seg = core.split('.');
  return List<int>.generate(
    3,
    (i) => i < seg.length ? (int.tryParse(seg[i]) ?? 0) : 0,
  );
}

/// 解析类失败的种类。UI 层把它映射成 l10n 文案——零硬编码文案守卫不允许
/// checker 里出现中文，而这两条是**要显示给用户**的。
enum UpdateError { badJson, noTag }
