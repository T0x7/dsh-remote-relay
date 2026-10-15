// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class L10nZh extends L10n {
  L10nZh([String locale = 'zh']) : super(locale);

  @override
  String get tabMachines => '机器';

  @override
  String get tabConsole => '控制';

  @override
  String get tabSettings => '设置';

  @override
  String get consoleTitle => '控制台';

  @override
  String get consoleBody => '对话 / 任务 / 审批将在 M2 到来。\n先在「机器」里完成配对。';

  @override
  String get machinesEmptyTitle => '还没有机器';

  @override
  String get machinesEmptyBody =>
      '在电脑上运行 dsh-remote-client pair 或打开插件的远程控制卡片，\n扫二维码把机器加进来。';

  @override
  String get machinesAddFab => '添加机器';

  @override
  String get machinesScanOrPaste => '扫码 / 粘贴链接';

  @override
  String get cardExpiredHint => '会话已失效 · 点击重新配对';

  @override
  String cardSessionLine(Object day, Object left) {
    return '会话剩余 $left · $day/30 天';
  }

  @override
  String get machinesEngineUnreachable => '隧道在线，但引擎没有应答 · 请检查电脑上的 dsh';

  @override
  String get chipExpired => '已过期';

  @override
  String get chipAutoRenew => '自动续期';

  @override
  String get pairingTitle => '添加机器';

  @override
  String get pairingHint => '粘贴配对链接（https://relay…/?sessionId=…）';

  @override
  String get pairingParse => '解析链接';

  @override
  String get errTokenRetired => '这不是签名链接（token 形态已退役）';

  @override
  String get errWindowExpired => '链接已过期或超时（有效期 1 分钟–24 小时）';

  @override
  String errMalformed(Object reason) {
    return '链接格式不对：$reason';
  }

  @override
  String get errNotUrl => '这不是一个有效的 URL';

  @override
  String get confirmTitle => '确认机器';

  @override
  String get confirmSessionLine => '24 小时内有效 · 到期前自动续期';

  @override
  String get kvRelay => '中继';

  @override
  String get kvMachine => '机器';

  @override
  String get confirmSecurity => '凭证只存本机安全存储（Keychain / Keystore）；连接前会先验证链接有效性。';

  @override
  String get actionCancel => '取消';

  @override
  String get actionLockAndConnect => '锁定并连接';

  @override
  String get verifyingLink => '正在验证链接（不保存无效凭证）…';

  @override
  String get qrExpiredTitle => '二维码已失效';

  @override
  String get qrExpiredBody => '机器端二维码已过期，或已被新生成的替换（每次生成会替换旧的）。请回到电脑端刷新后重试。';

  @override
  String get unreachableTitle => '中继不可达';

  @override
  String get unreachableBody => '连不上中继——检查手机网络与中继地址后重试。';

  @override
  String get actionRetry => '重试';

  @override
  String get detailSectionTunnel => '隧道';

  @override
  String get detailSectionSession => '会话';

  @override
  String detailSectionDevices(Object line) {
    return '设备 · $line';
  }

  @override
  String get detailSectionActions => '操作';

  @override
  String get stateConnected => '已连接';

  @override
  String get stateConnecting => '连接中';

  @override
  String get stateReconnecting => '重连中';

  @override
  String get stateManualOff => '手动断开';

  @override
  String get stateDisabled => '已停用';

  @override
  String get stateUnknown => '未知';

  @override
  String get kvState => '状态';

  @override
  String get kvReported => '上报';

  @override
  String detailRemaining(Object left) {
    return '剩余 $left';
  }

  @override
  String detailCapLine(Object day) {
    return '会话寿命 第 $day / 30 天（到期须重扫）';
  }

  @override
  String detailPairedOnline(Object online, Object paired) {
    return '$paired 已配对 / $online 在线';
  }

  @override
  String get detailSnapshotMissing => '快照不可用';

  @override
  String get detailThisSession => '本会话';

  @override
  String get deviceOnline => '在线';

  @override
  String get deviceOffline => '离线';

  @override
  String get devicePairedSuffix => ' · 已配对';

  @override
  String get actionCopyLink => '复制完整 Web 界面链接（24h）';

  @override
  String get actionDisconnect => '断开中继';

  @override
  String get actionReconnect => '重连中继';

  @override
  String get actionRevokeAll => '吊销全部配对…';

  @override
  String get revokeTitle => '吊销全部配对？';

  @override
  String get revokeBody => '所有设备（包括这台手机）将立即失效。机器端需要重新生成二维码。';

  @override
  String get actionRevoke => '吊销';

  @override
  String get snackDisconnected => '已断开中继';

  @override
  String get snackReconnected => '已重连中继';

  @override
  String get snackRejected => '操作被引擎拒绝';

  @override
  String snackRevoked(Object n) {
    return '已吊销 $n 个会话';
  }

  @override
  String get snackLinkCopied => '已复制 24h 完整界面链接——在浏览器打开';

  @override
  String get snackMintFailed => '铸链接失败（中继不可达或已失效）';

  @override
  String get expiredTitle => '会话已失效';

  @override
  String get expiredChipWindow => '24h 窗口已过期';

  @override
  String get expiredChipRevoked => '已被吊销';

  @override
  String get expiredChipMaxAge => '达 30 天上限';

  @override
  String get expiredChipUnknown => '已失效';

  @override
  String get expiredCauseWindow => '24 小时窗口到期，自动续期未能完成';

  @override
  String expiredCauseMaxAge(Object day) {
    return '会话绝对寿命已到（第 $day 天）——需在电脑端重新配对';
  }

  @override
  String get expiredCauseRevoked => '此机器的配对在其他设备或电脑上被吊销';

  @override
  String get expiredCauseUnknown => '会话在服务端已不存在';

  @override
  String get expiredScopeHint => '仅此机器受影响——列表其他机器照常工作。';

  @override
  String get expiredRepairHint => '到电脑上打开 dsh「设置 → 远程控制」刷新二维码，回来扫一下即可恢复。';

  @override
  String get actionRescan => '重新扫码';

  @override
  String get actionDeleteMachine => '删除这台机器…';

  @override
  String get settingsLockTitle => '生物识别锁';

  @override
  String get settingsLockSubProbing => '正在检测这台设备的认证能力…';

  @override
  String get settingsLockSubBiometric => '解锁后才会解密会话凭证 · 由系统生物识别校验';

  @override
  String get settingsLockSubDeviceCredential => '未录入生物识别，将由设备密码或图案校验';

  @override
  String get settingsLockSubUnsupported => '这台设备没有可用的生物识别，只能靠手动解锁';

  @override
  String get settingsPinsTitle => '证书锁定 (TOFU)';

  @override
  String get settingsPinsNone => '尚未固定证书 · 重新配对 https 中继即可锁定';

  @override
  String settingsPinsCount(Object n) {
    return '$n 台已锁定 · 查看指纹';
  }

  @override
  String get settingsRemindersTitle => '前台提醒';

  @override
  String get settingsRemindersSub => '隧道断开 · 任务完成（仅 App 打开时，无后台推送）';

  @override
  String get settingsLanguageTitle => '语言';

  @override
  String get settingsLanguageSub => '跟随系统 · 中文 / English（仅此两种）';

  @override
  String get settingsAboutTitle => '关于';

  @override
  String get settingsAboutSub => 'v0.0.3 · 隧道协议 v:1 · MIT 开源';

  @override
  String get settingsFooter =>
      '零遥测 · 零崩溃收集 · 零第三方 SDK\n全部源码随 dsh-remote-relay 开源';

  @override
  String get pinsHowTofu => 'TOFU：首次连接时记下中继证书的指纹，之后每次连接都要对上；对不上就断开。';

  @override
  String get pinsEmptyTitle => '尚未钉住任何中继';

  @override
  String get pinsNoPinNeeded => 'http 链路，无需 pin';

  @override
  String get pinsFingerprint => '证书指纹 (SHA-256)';

  @override
  String get pinsReadOnlyNote =>
      '本页只读。删掉 pin 等于让这条链路退回「首次连接即信任」；要换指纹请在电脑上重新配对。';

  @override
  String get languageOptionZh => '中文';

  @override
  String get languageOptionEn => 'English';

  @override
  String languageEffective(Object value) {
    return '当前生效：$value';
  }

  @override
  String get languageEffectiveUnknown => '当前生效：未知（系统语言没有对应译文）';

  @override
  String get languageStartupNote => '语言在 App 启动时确定；改动已保存，下次启动读取。';

  @override
  String get aboutAppVersion => 'App 版本';

  @override
  String get aboutProtocolVersion => '隧道协议版本';

  @override
  String get aboutLicense => '许可';

  @override
  String get aboutSource => '源码';

  @override
  String get aboutNoOtaNote => '无 OTA、无自动更新：源码即产物，重新构建即升级。';

  @override
  String get lockTitle => 'DSH Remote 已锁定';

  @override
  String get lockSub => '解锁后才会解密会话凭证';

  @override
  String get lockAction => '解锁';

  @override
  String get lockReason => '解锁以解密会话凭证';

  @override
  String get lockVerifying => '验证中…';

  @override
  String get lockFailed => '验证未通过，再试一次';

  @override
  String get lockCancelled => '已取消';

  @override
  String get lockUnavailable => '系统无法完成验证——检查设备的锁屏密码与生物识别设置';

  @override
  String get lockNoBiometrics => '这台设备没有可用的生物识别';

  @override
  String get lockNoBiometricsTried => '这台设备没有可用的生物识别或锁屏密码（已试过系统验证）';

  @override
  String get lockFootnote => '由系统生物识别或设备密码校验 · 凭证留在系统钥匙串里';

  @override
  String get lockFootnotePlain => '当前设备不支持生物识别，解锁需要你本人的操作';

  @override
  String get err_network_unreachable => '连不上中继——检查网络与中继地址';

  @override
  String get err_tls_cert_changed => '中继证书已变更——确认非入侵后删除机器重新配对';

  @override
  String get err_auth_expired => '会话已过期（24h 窗口）';

  @override
  String get err_auth_revoked => '配对已被吊销';

  @override
  String get err_auth_max_age => '会话已达 30 天上限';

  @override
  String get err_auth_missing => '会话凭证不存在';

  @override
  String get err_ratelimit_hit => '操作过于频繁，稍候重试';

  @override
  String get err_engine_down => '机器上的引擎未响应（可能已退出）';

  @override
  String get err_payload_too_large => '响应超过 32 MiB 上限';

  @override
  String get err_concurrency_exceeded => '并发大响应过多，稍候';

  @override
  String get err_api_privileged => '该操作仅本机可用（引擎特权方法）';

  @override
  String get err_ws_device_replaced => '已在其他设备连接，事件流重连中';

  @override
  String get consoleReconnecting => '连接已断开，正在重连…';

  @override
  String get err_pair_qr_invalid => '二维码/链接无效或已过期';

  @override
  String get err_renew_failed => '自动续期失败，请尽快重新扫码';

  @override
  String get err_storage_error => '安全存储不可写';

  @override
  String get err_engine_timeout => '引擎处理超时，正在重试';

  @override
  String get err_engine_unknown => '引擎返回了未知错误';

  @override
  String get pairingScan => '扫码';

  @override
  String get scanTitle => '扫码配对';

  @override
  String get scanHint => '对准 dsh 插件「远程控制」卡片或终端 pair 输出的二维码';

  @override
  String get cameraUnavailable => '相机不可用';

  @override
  String cameraError(Object code) {
    return '错误：$code\n可改用「粘贴链接」入口。';
  }

  @override
  String get actionBack => '返回';

  @override
  String get actionOpenWeb => '在浏览器打开完整 Web 界面';

  @override
  String get snackOpeningWeb => '正在打开完整界面（24h 链接）…';

  @override
  String get snackCopyFallback => '无法唤起浏览器，链接已复制';

  @override
  String get renewFailedChip => '续期失败';

  @override
  String get err_engine_session_gone => '该会话已不存在（可能已在另一端删除）';

  @override
  String get err_session_writer_held => '另一端正在编辑此会话，稍候再试';

  @override
  String get err_session_agent_busy => '该子会话正被 agent 占用，请从主会话操作';

  @override
  String get err_subagent_read_only => '该子代理只读，无法输入';

  @override
  String get err_model_unavailable => '所选模型或服务商不可用';

  @override
  String get err_engine_unsupported => '当前引擎版本不支持此操作，请升级 dsh';

  @override
  String get err_engine_unavailable => '引擎暂时不可用，正在重试';

  @override
  String get err_engine_cancelled => '操作已取消';

  @override
  String get consoleNoMachine => '还没有可控制的机器';

  @override
  String get consoleNoMachineBody => '先在「机器」页扫码绑定一台机器，控制台会接管它的 agent';

  @override
  String get consoleNoSessionTitle => '选一个会话开始';

  @override
  String get consoleNoSessionBody => '点右上角列表恢复引擎侧的会话（与电脑端同一份），或新建一个';

  @override
  String get segmentChat => '对话';

  @override
  String get segmentTasks => '任务';

  @override
  String get segmentWorkspace => '工作区';

  @override
  String get segmentHost => '主机';

  @override
  String get segmentTrajectory => '轨迹';

  @override
  String workspacesTitle(Object machine) {
    return '工作区 · $machine';
  }

  @override
  String get workspacesUngrouped => '未分组';

  @override
  String get workspacesEmpty => '这台机器还没有任何带会话的工作区';

  @override
  String get workspacesLoadingSessions => '正在读取这台机器的会话…';

  @override
  String get workspacesUnavailable => '工作区注册表拿不到：引擎的 workspace/follow 流没有响应';

  @override
  String get workspacesEmptyGroup => '这个工作区下还没有会话';

  @override
  String get workspacesSearchHint => '搜索工作区或会话';

  @override
  String workspacesMore(Object count) {
    return '还有 $count 个会话';
  }

  @override
  String workspacesSessionCount(Object count) {
    return '$count 个会话';
  }

  @override
  String get segmentTasksSoon => '任务页在 T2.8 接入';

  @override
  String get segmentHostSoon => '主机页在 T2.8 接入';

  @override
  String get sessionsTitleShort => '会话';

  @override
  String sessionsTruncated(Object shown, Object total) {
    return '只显示最近 $total 个会话（共 $shown）';
  }

  @override
  String sessionsTitle(Object machine) {
    return '会话 · $machine';
  }

  @override
  String get sessionsNew => '新会话';

  @override
  String get sessionsEmpty => '还没有会话';

  @override
  String get sessionsEmptyBody => '新会话后即可在手机上与 agent 对话，电脑端同步可见';

  @override
  String get sessionsUntitled => '未命名会话';

  @override
  String get sessionsRunning => '运行中';

  @override
  String get sessionsFooter => '会话保存在引擎侧 · 点按恢复（与 web 端同一会话，两端接力）';

  @override
  String sessionsRowSubtitle(Object turns, Object when) {
    return '$when · $turns 轮';
  }

  @override
  String sessionsChildSubtitle(Object when) {
    return '子代理 · $when';
  }

  @override
  String get chatComposerHint => '发消息给 agent…';

  @override
  String get chatSend => '发送';

  @override
  String get chatReadOnly => '该子代理只读，无法输入';

  @override
  String get chatFromSubagent => '来自';

  @override
  String get chatApprovalTitle => '请求执行';

  @override
  String get chatAllow => '允许';

  @override
  String get chatReject => '拒绝';

  @override
  String get chatQuestionPending => 'agent 正在等待你的回答';

  @override
  String chatQuestionProgress(Object answered, Object total) {
    return '已答 $answered/$total';
  }

  @override
  String get chatQuestionSubmit => '提交';

  @override
  String get chatQuestionAbandon => '放弃';

  @override
  String get chatQuestionAbandonReason => '用户在手机上放弃了这次提问';

  @override
  String get chatFreeTextHint => '自由输入（可留空跳过）';

  @override
  String get chatCustomAlongsideHint => '补充说明（可选，与选项并存）';

  @override
  String get chatPlanReviewTitle => '计划待批准';

  @override
  String get workspaceRootLabel => '本会话工作区';

  @override
  String get workspaceUncategorized => '未分类';

  @override
  String get workspaceParent => '上一级';

  @override
  String get workspaceTruncated => '条目过多，仅显示前一部分';

  @override
  String get workspaceEmpty => '这个目录是空的';

  @override
  String workspaceSize(Object bytes) {
    return '$bytes 字节';
  }

  @override
  String get workspaceBack => '返回目录';

  @override
  String get workspaceCopy => '复制内容';

  @override
  String get workspaceCopied => '已复制';

  @override
  String workspaceMoreLines(Object lines) {
    return '再看 $lines 行';
  }

  @override
  String chatContextPercent(Object percent) {
    return '上下文 $percent%';
  }

  @override
  String get chatContextUnknown => '上下文 未知';

  @override
  String chatTokensPerSecond(Object rate) {
    return '$rate tok/s';
  }

  @override
  String chatCachePercent(Object percent) {
    return '缓存 $percent%';
  }

  @override
  String chatTurnsElapsed(Object turns) {
    return '$turns 轮';
  }

  @override
  String get retry => '重试';

  @override
  String get modelTitle => '模型与思考档位';

  @override
  String get modelFollowDefault => '跟随默认';

  @override
  String get modelFollowDefaultBody => '该会话尚未选择过模型，当前跟随部署默认。点模型可固定。';

  @override
  String get modelPickedBody => '该会话已固定模型，引擎返回的是归一化后的选择。';

  @override
  String get modelUseThis => '使用';

  @override
  String modelEffortChip(Object effort, Object model) {
    return '$model · $effort';
  }

  @override
  String get modelEffortDefault => '默认档';

  @override
  String get modelCatalogFailures => '以下服务商未能加载（不影响其余）';

  @override
  String get modelSheetFailed => '读取模型目录失败';

  @override
  String get contextTitle => '上下文与统计';

  @override
  String get contextNotReported => '引擎尚未上报用量——这里显示未知，而不是 0%。';

  @override
  String get contextProjected => '预估占用';

  @override
  String get contextPressure => '当前压力';

  @override
  String get contextWindow => '上下文窗口';

  @override
  String get contextBreakdownTitle => '构成分解';

  @override
  String get contextBreakdownCaveat => '（按固定密度估算，不与上方总量对齐）';

  @override
  String get contextSegmentSystem => '系统提示';

  @override
  String get contextSegmentTools => '工具定义';

  @override
  String get contextSegmentMessages => '对话消息';

  @override
  String get contextUsageTitle => '用量与统计';

  @override
  String get contextUsageUncached => '未命中输入';

  @override
  String get contextUsageCacheRead => '缓存读';

  @override
  String get contextUsageCacheWrite => '缓存写';

  @override
  String get contextUsageOutput => '输出';

  @override
  String get contextTurns => '轮次';

  @override
  String get teamTitle => '子代理团队';

  @override
  String teamCount(Object count) {
    return '$count 个子代理';
  }

  @override
  String get teamEmpty => '该会话还没有子代理';

  @override
  String get teamCatalogUnavailable => '该会话未提供子代理目录';

  @override
  String get teamReadOnly => '只读';

  @override
  String get teamModeTerminal => '终态 · 不可再派活';

  @override
  String get teamModeContinuable => '可继续对话';

  @override
  String get teamFooter => '点按子代理打开它的会话；能否继续对话看卡片上的模式';

  @override
  String get teamBadgeTooltip => '子代理团队';

  @override
  String get jobsEmpty => '该会话没有任务';

  @override
  String get jobsStateRunning => '运行中';

  @override
  String get jobsStateDone => '已结束';

  @override
  String get jobsStateFailed => '失败';

  @override
  String get jobsStatePending => '等待中';

  @override
  String get jobsKill => '终止';

  @override
  String get jobsKillRequested => '已请求终止';

  @override
  String get jobsNoFirstFrame => '任务列表没有回第一帧（引擎未响应）';

  @override
  String get jobsAlreadyFinished => '该任务已经结束了';

  @override
  String get hostSessions => '会话数';

  @override
  String get hostModel => '当前模型';

  @override
  String get hostPlugins => '已装载插件';

  @override
  String get hostPluginDisabled => '未启用';

  @override
  String get hostPluginsNote =>
      '来自引擎 pluginManager/listBundles：开关作用于整包，重启引擎后生效';

  @override
  String get hostBundleModules => '个内部模块';

  @override
  String get hostPluginCoreLocked => '核心模块';

  @override
  String get hostPluginUnaddressable => '不可寻址';

  @override
  String get hostPluginRestartRequired => '已记录 · 重启引擎后生效';

  @override
  String get hostMetricsUnavailable =>
      '本版引擎未提供主机指标（无 events.host / 相关路由），故不显示推测值。';

  @override
  String get trajectoryEmpty => '这个会话还没有轨迹记录';

  @override
  String get trajectoryNoSession => '先打开一个会话，轨迹才有东西可看';

  @override
  String trajectoryTruncated(Object dropped, Object kept) {
    return '窗口只保留最近 $kept 条记录（更早的 $dropped 条已丢弃，可向上加载）';
  }

  @override
  String get trajectoryLoadEarlier => '加载更早的记录';

  @override
  String get trajectoryLoadingEarlier => '正在加载更早的记录…';

  @override
  String trajectoryEarlierFailed(Object reason) {
    return '加载更早的记录失败：$reason';
  }

  @override
  String get trajectoryBetweenTurns => '轮次之间';

  @override
  String trajectoryTurn(Object turn) {
    return '第 $turn 轮';
  }

  @override
  String trajectoryRequest(Object request) {
    return '请求 #$request';
  }

  @override
  String get trajectoryLaneSystem => '系统';

  @override
  String get trajectoryLaneMessage => '消息';

  @override
  String get trajectoryLaneTool => '工具';

  @override
  String get trajectoryNoTiming => '这段记录没有可画的耗时（引擎没记起点）';

  @override
  String get trajectoryInspector => '记录';

  @override
  String get trajectoryTabPayload => '载荷';

  @override
  String get trajectoryTabTiming => '计时';

  @override
  String get trajectoryTabUsage => '用量';

  @override
  String trajectoryRangeActive(Object from, Object to) {
    return '已筛选 $from–$to';
  }

  @override
  String get trajectoryRangeClear => '清除筛选';

  @override
  String get trajectoryToolError => '错误';

  @override
  String get trajectoryToolReturn => '返回';

  @override
  String get trajectoryHint => '点一条记录看原始载荷 · 在时间条上拖动可按区间筛选';

  @override
  String get trajectoryTtft => '首 token';

  @override
  String get trajectoryDecode => '解码';

  @override
  String get trajectoryTotal => '合计';

  @override
  String get trajectoryStarted => '开始';

  @override
  String get trajectoryEnded => '结束';

  @override
  String get trajectoryEmptyRange => '所选区间内没有记录';

  @override
  String get workspacesFilter => '归档视图';

  @override
  String get workspacesFilterHide => '隐藏已归档';

  @override
  String get workspacesFilterShow => '显示已归档';

  @override
  String get workspacesFilterOnly => '只看看归档';

  @override
  String get workspacesArchivedBadge => '已归档';

  @override
  String get workspacesArchivedHint => '已归档的会话不会被打断，点「恢复」可以拿回来';

  @override
  String get workspacesArchivedNone => '没有被归档的会话';

  @override
  String get workspacesUnarchive => '恢复';

  @override
  String get workspacesDeadBadge => '已失效';

  @override
  String get workspacesDeadHint =>
      '引擎里已没有这个会话：多为主机任务绕过引擎直写的记录，或记录被清理后的注册表残留。点「归档」可从列表清理。';

  @override
  String chatFoldExpand(int count) {
    return '展开全文（$count 字）';
  }

  @override
  String get chatFoldCollapse => '收起';

  @override
  String get chatMetaSystemReminder => '系统提醒';

  @override
  String get chatMetaRuntimeContext => '运行时上下文';

  @override
  String get chatMetaInjected => '系统注入';

  @override
  String chatMetaChip(String label, int count) {
    return '$label · $count 字';
  }

  @override
  String get chatThinkingActive => '💭 思考中…';

  @override
  String chatThinkingActiveCount(int count) {
    return '💭 思考中 · $count 字';
  }

  @override
  String chatThinkingActiveExpanded(int count) {
    return '💭 思考中 · $count 字（点按收起）';
  }

  @override
  String chatThoughtCollapsed(int count) {
    return '💭 已思考 · $count 字（点按展开）';
  }

  @override
  String chatThoughtExpanded(int count) {
    return '💭 已思考 · $count 字（点按收起）';
  }

  @override
  String get chatToolCallLabel => '工具调用';

  @override
  String get chatToolArgs => '调用参数';

  @override
  String get chatToolResult => '运行结果';

  @override
  String get presetsSheetTitle => '选择 Agent 预设';

  @override
  String get presetsWorkspaceSection => '在哪个工作区打开';

  @override
  String get presetsWorkspaceDefault => '引擎默认';

  @override
  String get presetsQuickCreate => '直接新建（默认预设）';

  @override
  String get presetsDefaultChip => '默认';

  @override
  String get presetsBrokenChip => '配置损坏';

  @override
  String get presetsLoadFailed => '预设读取失败，可用「直接新建」走默认预设。';

  @override
  String get workspacesUnarchiveFailed => '恢复失败';

  @override
  String get workspacesArchive => '归档';

  @override
  String get workspacesArchiveFailed => '归档失败';

  @override
  String get workspacesPin => '置顶';

  @override
  String get workspacesUnpin => '取消置顶';

  @override
  String get workspacesPinFailed => '置顶失败';

  @override
  String get workspacesArchiveBusyTitle => '这个会话还在跑';

  @override
  String get workspacesArchiveBusyBody => '归档前要先停下来：';

  @override
  String get workspacesArchiveBusyStopAndArchive => '停掉并归档';

  @override
  String get workspacesArchiveBusyCancel => '取消';

  @override
  String get workspacesArchiveActivityTurn => '正在进行的对话';

  @override
  String get workspacesArchiveActivityJob => '后台任务';

  @override
  String get workspacesArchiveActivitySubagent => '子智能体';

  @override
  String get workspacesArchiveActivitySchedule => '定时任务';

  @override
  String workspacesArchiveActivityOther(Object kind) {
    return '其他（$kind）';
  }

  @override
  String get workspacesArchiveActivityJoin => '、';

  @override
  String workspacesArchiveActivityWith(Object label, Object names) {
    return '$label：$names';
  }

  @override
  String get workspacesArchiveDone => '已归档';

  @override
  String get workspacesSyncing => '正在同步工作区成员…';

  @override
  String get settingsDiagnosticsTitle => '诊断日志';

  @override
  String get settingsDiagnosticsSub => '本地脱敏日志，仅存本机';

  @override
  String diagnosticsMeta(String size, String lines) {
    return '$size · 共 $lines 行';
  }

  @override
  String get diagnosticsEmpty => '暂无日志。';

  @override
  String get diagnosticsCopied => '日志已复制';

  @override
  String get diagnosticsShare => '分享日志';

  @override
  String get diagnosticsCopyAll => '复制全部';

  @override
  String get diagnosticsClear => '清空日志';

  @override
  String get diagnosticsCancel => '取消';

  @override
  String get diagnosticsClearTitle => '清空日志？';

  @override
  String get diagnosticsClearBody => '将删除本机上的日志文件。';

  @override
  String get diagnosticsCleared => '日志已清空';

  @override
  String get diagnosticsShareSubject => 'DSH Remote 诊断日志';

  @override
  String get authCauseExpired => '会话已过期';

  @override
  String get authCauseRevoked => '凭证已被吊销';

  @override
  String get authCauseMaxAge => '已超过 30 天上限';

  @override
  String get authCauseUnknown => '原因未知';

  @override
  String get consoleCredentialDead => '凭证已失效，不会自动恢复';

  @override
  String consoleCredentialDeadWhy(Object cause) {
    return '$cause · 需要重新配对才能继续';
  }

  @override
  String get consoleGoRepair => '去重新配对';

  @override
  String get diagnosticsChannelLabel => '日志通道';

  @override
  String get diagnosticsChannelAll => '全部';

  @override
  String get diagnosticsChannelApp => '运行';

  @override
  String get diagnosticsChannelCrash => '崩溃';

  @override
  String get diagnosticsChannelAudit => '操作';

  @override
  String get diagnosticsChannelEmpty => '该通道暂无日志。';

  @override
  String get settingsUpdateCheckTitle => '检查更新';

  @override
  String get settingsUpdateCheckSub => '向 GitHub 查询有没有新版本（只提示，不自动安装）';

  @override
  String get updateCheckIdle => '未检查';

  @override
  String get updateCheckChecking => '正在检查…';

  @override
  String updateCheckUpToDate(Object version) {
    return '已是最新版本（$version）';
  }

  @override
  String updateCheckAvailable(Object latest) {
    return '发现新版本 $latest';
  }

  @override
  String updateCheckFailed(Object reason) {
    return '检查失败：$reason';
  }

  @override
  String get updateCheckOpen => '打开下载页';

  @override
  String updateCheckSize(Object mb) {
    return '$mb MB';
  }

  @override
  String get updateErrBadJson => '返回内容不是 JSON 对象';

  @override
  String get updateErrNoTag => '该 release 没有版本号';
}
