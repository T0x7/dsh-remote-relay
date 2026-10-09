/// 「关于」页要显示的事实值。
///
/// 全部来自仓库里**已经存在**的记录，不在页面里另写一份版本号——版本号
/// 一旦在两处出现就会开始漂移。
///
/// App 版本
///
/// 取 `app/CHANGELOG.md` 最新一版（`## [0.1.0]`），这是本仓目前唯一维护
/// App 版本的地方。注意 `pubspec.yaml` 写的是 `1.0.0+1`，两者对不上
/// （见交付报告）。真要上板应由 `package_info_plus` 在运行时读，但它还不在
/// 依赖白名单里、pubspec.yaml 也不属于本任务可改的文件，所以这里显式钉住
/// 常量，而不是假装能自动跟随。
const String kAppVersion = '0.1.0';

/// 隧道协议版本。`docs/protocol.md`「Data plane (`v: 1`)」与
/// `server/src/index.ts` 的 `v: 1 as const` 共同钉死；PRD §7.3 要求 App
/// 不假设未协商的帧，所以它是协议契约的一部分，不是 App 的选择。
const int kTunnelProtocolVersion = 1;

/// 许可证。仓库根 `LICENSE` 为 MIT，`package.json` 的 `license` 字段同。
const String kLicense = 'MIT';

/// 源码仓库标识。git remote 目前指向内网 Gitea，没有可公开引用的地址，
/// 所以只放仓库名；要补公网地址时改这一处即可。
const String kSourceRepository = 'dsh-remote-relay';
