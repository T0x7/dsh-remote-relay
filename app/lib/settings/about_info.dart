/// 「关于」页要显示的事实值。
///
/// 全部来自仓库里**已经存在**的记录，不在页面里另写一份版本号——版本号
/// 一旦在两处出现就会开始漂移。
///
/// App 版本
///
/// `pubspec.yaml` 的 `version:` 是**唯一权威**；`test/version_single_source_test.dart`
/// 会在 CI 里断言本常量、pubspec 与 CHANGELOG 的 `## [x.y.z]` 三者一致——版本号
/// 一旦在两处出现就会开始漂移，而「拿哪个版本号去比更新」正是发版链路的前置条件
/// （历史事实：pubspec 写 1.0.0+1、这里曾写 0.1.0、CHANGELOG 又停在 0.1.0，三份对不上）。
///
/// 这里**不**引 `package_info_plus` 去运行时读包信息：那要进依赖白名单，而本 App
/// 是自部署自签名的调试工具，版本一致性用一条守门钉住就够了，不必为它多一个依赖。
const String kAppVersion = '1.0.0';

/// 隧道协议版本。`docs/protocol.md`「Data plane (`v: 1`)」与
/// `server/src/index.ts` 的 `v: 1 as const` 共同钉死；PRD §7.3 要求 App
/// 不假设未协商的帧，所以它是协议契约的一部分，不是 App 的选择。
const int kTunnelProtocolVersion = 1;

/// 许可证。仓库根 `LICENSE` 为 MIT，`package.json` 的 `license` 字段同。
const String kLicense = 'MIT';

/// 源码仓库标识。git remote 目前指向内网 Gitea，没有可公开引用的地址，
/// 所以只放仓库名；要补公网地址时改这一处即可。
const String kSourceRepository = 'dsh-remote-relay';
