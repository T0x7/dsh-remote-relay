// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class L10nEn extends L10n {
  L10nEn([String locale = 'en']) : super(locale);

  @override
  String get tabMachines => 'Machines';

  @override
  String get tabConsole => 'Console';

  @override
  String get tabSettings => 'Settings';

  @override
  String get consoleTitle => 'Console';

  @override
  String get consoleBody =>
      'Chat, tasks and approvals land in M2.\nPair a machine first under Machines.';

  @override
  String get machinesEmptyTitle => 'No machines yet';

  @override
  String get machinesEmptyBody =>
      'Run dsh-remote-client pair on your computer (or open the plugin\'s Remote Control card), then scan the QR to add it.';

  @override
  String get machinesAddFab => 'Add machine';

  @override
  String get machinesScanOrPaste => 'Scan / paste link';

  @override
  String get cardExpiredHint => 'Session expired · tap to re-pair';

  @override
  String cardSessionLine(Object day, Object left) {
    return '$left left · day $day/30';
  }

  @override
  String get machinesEngineUnreachable =>
      'Tunnel is up, but the engine is not answering · check dsh on your machine';

  @override
  String get chipExpired => 'Expired';

  @override
  String get chipAutoRenew => 'Auto-renew';

  @override
  String get pairingTitle => 'Add machine';

  @override
  String get pairingHint => 'Paste pairing link (https://relay…/?sessionId=…)';

  @override
  String get pairingParse => 'Parse link';

  @override
  String get errTokenRetired => 'Not a signed link (the token form is retired)';

  @override
  String get errWindowExpired =>
      'Link expired or outside the 1 min–24 h window';

  @override
  String errMalformed(Object reason) {
    return 'Malformed link: $reason';
  }

  @override
  String get errNotUrl => 'Not a valid URL';

  @override
  String get confirmTitle => 'Confirm machine';

  @override
  String get confirmSessionLine => 'Valid 24 h · auto-renews before expiry';

  @override
  String get kvRelay => 'Relay';

  @override
  String get kvMachine => 'Machine';

  @override
  String get confirmSecurity =>
      'Credentials live only in this device\'s secure storage (Keychain / Keystore); the link is verified before anything is stored.';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionLockAndConnect => 'Lock & connect';

  @override
  String get verifyingLink =>
      'Verifying the link (invalid credentials are never stored)…';

  @override
  String get qrExpiredTitle => 'QR expired';

  @override
  String get qrExpiredBody =>
      'The machine\'s QR expired or was replaced (each mint replaces the old one). Refresh it on the computer and retry.';

  @override
  String get unreachableTitle => 'Relay unreachable';

  @override
  String get unreachableBody =>
      'Cannot reach the relay — check the phone network and the relay address.';

  @override
  String get actionRetry => 'Retry';

  @override
  String get detailSectionTunnel => 'Tunnel';

  @override
  String get detailSectionSession => 'Session';

  @override
  String detailSectionDevices(Object line) {
    return 'Devices · $line';
  }

  @override
  String get detailSectionActions => 'Actions';

  @override
  String get stateConnected => 'Connected';

  @override
  String get stateConnecting => 'Connecting';

  @override
  String get stateReconnecting => 'Reconnecting';

  @override
  String get stateManualOff => 'Manually off';

  @override
  String get stateDisabled => 'Disabled';

  @override
  String get stateUnknown => 'Unknown';

  @override
  String get kvState => 'State';

  @override
  String get kvReported => 'Reported';

  @override
  String detailRemaining(Object left) {
    return '$left left';
  }

  @override
  String detailCapLine(Object day) {
    return 'Session life: day $day/30 (re-scan after it ends)';
  }

  @override
  String detailPairedOnline(Object online, Object paired) {
    return '$paired paired / $online online';
  }

  @override
  String get detailSnapshotMissing => 'Snapshot unavailable';

  @override
  String get detailThisSession => 'This session';

  @override
  String get deviceOnline => 'online';

  @override
  String get deviceOffline => 'offline';

  @override
  String get devicePairedSuffix => ' · paired';

  @override
  String get actionCopyLink => 'Copy full web-UI link (24 h)';

  @override
  String get actionDisconnect => 'Disconnect relay';

  @override
  String get actionReconnect => 'Reconnect relay';

  @override
  String get actionRevokeAll => 'Revoke all pairings…';

  @override
  String get revokeTitle => 'Revoke all pairings?';

  @override
  String get revokeBody =>
      'Every device (including this phone) loses access immediately. The machine must mint a new QR.';

  @override
  String get actionRevoke => 'Revoke';

  @override
  String get snackDisconnected => 'Relay disconnected';

  @override
  String get snackReconnected => 'Relay reconnected';

  @override
  String get snackRejected => 'Action rejected by the engine';

  @override
  String snackRevoked(Object n) {
    return 'Revoked $n session(s)';
  }

  @override
  String get snackLinkCopied =>
      'Copied 24 h web-UI link — open it in a browser';

  @override
  String get snackMintFailed =>
      'Could not mint a link (relay unreachable or expired)';

  @override
  String get expiredTitle => 'Session expired';

  @override
  String get expiredChipWindow => '24 h window expired';

  @override
  String get expiredChipRevoked => 'Revoked';

  @override
  String get expiredChipMaxAge => '30-day cap reached';

  @override
  String get expiredChipUnknown => 'Expired';

  @override
  String get expiredCauseWindow =>
      'The 24 h window elapsed; auto-renewal did not complete';

  @override
  String expiredCauseMaxAge(Object day) {
    return 'Absolute session lifetime reached (day $day) — re-pair on the computer';
  }

  @override
  String get expiredCauseRevoked =>
      'This machine\'s pairing was revoked on another device or computer';

  @override
  String get expiredCauseUnknown => 'The session no longer exists server-side';

  @override
  String get expiredScopeHint =>
      'Only this machine is affected — others keep working.';

  @override
  String get expiredRepairHint =>
      'Open dsh Settings → Remote Control on the computer, refresh the QR, then scan it to recover.';

  @override
  String get actionRescan => 'Re-scan';

  @override
  String get actionDeleteMachine => 'Delete this machine…';

  @override
  String get settingsLockTitle => 'Biometric lock';

  @override
  String get settingsLockSubProbing => 'Checking what this device can verify…';

  @override
  String get settingsLockSubBiometric =>
      'Credentials decrypt only after unlock · verified by system biometrics';

  @override
  String get settingsLockSubDeviceCredential =>
      'No biometrics enrolled — your device passcode or pattern will be used';

  @override
  String get settingsLockSubUnsupported =>
      'This device has no biometrics available — unlocking must be manual';

  @override
  String get settingsPinsTitle => 'Certificate pinning (TOFU)';

  @override
  String get settingsPinsNone =>
      'No certificate pinned · re-pair an https relay to lock one';

  @override
  String settingsPinsCount(Object n) {
    return '$n pinned · view fingerprints';
  }

  @override
  String get settingsRemindersTitle => 'In-app reminders';

  @override
  String get settingsRemindersSub =>
      'Tunnel down · task finished (only while the app is open — no push)';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageSub => 'Follow system · 中文 / English (only these)';

  @override
  String get settingsAboutTitle => 'About';

  @override
  String get settingsAboutSub => 'v0.0.1 · tunnel protocol v:1 · MIT';

  @override
  String get settingsFooter =>
      'Zero telemetry · zero crash reporting · zero third-party SDKs\nOpen source with dsh-remote-relay';

  @override
  String get pinsHowTofu =>
      'TOFU: the relay certificate\'s fingerprint is remembered on first connect and must match on every connect after that; a mismatch breaks the link.';

  @override
  String get pinsEmptyTitle => 'No pinned relay yet';

  @override
  String get pinsNoPinNeeded => 'Plain http — no pin needed';

  @override
  String get pinsFingerprint => 'Certificate fingerprint (SHA-256)';

  @override
  String get pinsReadOnlyNote =>
      'This page is read-only. Dropping a pin downgrades the link to \"trust whatever answers first\"; to change a fingerprint, re-pair on the computer.';

  @override
  String get languageOptionZh => '中文';

  @override
  String get languageOptionEn => 'English';

  @override
  String languageEffective(Object value) {
    return 'In effect now: $value';
  }

  @override
  String get languageEffectiveUnknown =>
      'In effect now: unknown (no translation for the system language)';

  @override
  String get languageStartupNote =>
      'The interface language is decided when the app starts; your choice is saved and read on the next launch.';

  @override
  String get aboutAppVersion => 'App version';

  @override
  String get aboutProtocolVersion => 'Tunnel protocol version';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutSource => 'Source';

  @override
  String get aboutNoOtaNote =>
      'No OTA and no self-update: the source is the artifact — rebuild to upgrade.';

  @override
  String get lockTitle => 'DSH Remote is locked';

  @override
  String get lockSub => 'Session credentials decrypt only after unlock';

  @override
  String get lockAction => 'Unlock';

  @override
  String get lockReason => 'Unlock to decrypt your session credentials';

  @override
  String get lockVerifying => 'Verifying…';

  @override
  String get lockFailed => 'Not verified — try again';

  @override
  String get lockCancelled => 'Cancelled';

  @override
  String get lockUnavailable =>
      'The system could not verify — check this device\'s screen lock and biometrics settings';

  @override
  String get lockNoBiometrics => 'This device has no biometrics available';

  @override
  String get lockNoBiometricsTried =>
      'This device has no biometrics or screen lock (system verification was tried)';

  @override
  String get lockFootnote =>
      'Verified by system biometrics or your device passcode · credentials stay in the system keystore';

  @override
  String get lockFootnotePlain =>
      'This device has no biometrics, so unlocking needs you in person';

  @override
  String get err_network_unreachable =>
      'Cannot reach the relay — check the network and relay address';

  @override
  String get err_tls_cert_changed =>
      'The relay certificate changed — if this was not you, delete the machine and re-pair';

  @override
  String get err_auth_expired => 'Session expired (24 h window)';

  @override
  String get err_auth_revoked => 'The pairing was revoked';

  @override
  String get err_auth_max_age => 'Session hit its 30-day cap';

  @override
  String get err_auth_missing => 'No session credential';

  @override
  String get err_ratelimit_hit => 'Too many requests — try again shortly';

  @override
  String get err_engine_down =>
      'The engine on the machine did not respond (it may have exited)';

  @override
  String get err_payload_too_large => 'Response exceeded the 32 MiB cap';

  @override
  String get err_concurrency_exceeded => 'Too many large responses in flight';

  @override
  String get err_api_privileged =>
      'That action is loopback-only (engine privileged method)';

  @override
  String get err_ws_device_replaced =>
      'Connected on another device; reconnecting the event stream';

  @override
  String get consoleReconnecting => 'Connection lost, reconnecting…';

  @override
  String get err_pair_qr_invalid => 'The QR/link is invalid or expired';

  @override
  String get err_renew_failed => 'Auto-renewal failed — re-scan soon';

  @override
  String get err_storage_error => 'Secure storage is not writable';

  @override
  String get err_engine_timeout => 'The engine took too long — retrying';

  @override
  String get err_engine_unknown => 'The engine returned an unknown error';

  @override
  String get pairingScan => 'Scan QR';

  @override
  String get scanTitle => 'Scan to pair';

  @override
  String get scanHint =>
      'Point at the plugin Remote Control card, or the QR printed by pair';

  @override
  String get cameraUnavailable => 'Camera unavailable';

  @override
  String cameraError(Object code) {
    return 'Error: $code\nUse the paste-link entry instead.';
  }

  @override
  String get actionBack => 'Back';

  @override
  String get actionOpenWeb => 'Open full web UI in browser';

  @override
  String get snackOpeningWeb => 'Opening the full UI (24 h link)…';

  @override
  String get snackCopyFallback => 'Could not open a browser — link copied';

  @override
  String get renewFailedChip => 'Renewal failed';

  @override
  String get err_engine_session_gone =>
      'This session no longer exists (it may have been deleted on the other end)';

  @override
  String get err_session_writer_held =>
      'The other end is editing this session — try again shortly';

  @override
  String get err_session_agent_busy =>
      'This child session is held by the agent; act from the parent session';

  @override
  String get err_subagent_read_only =>
      'This subagent is read-only and cannot accept input';

  @override
  String get err_model_unavailable =>
      'The selected model or its provider is unavailable';

  @override
  String get err_engine_unsupported =>
      'This engine build does not support the operation — upgrade dsh';

  @override
  String get err_engine_unavailable =>
      'The engine is temporarily unavailable — retrying';

  @override
  String get err_engine_cancelled => 'Operation cancelled';

  @override
  String get consoleNoMachine => 'No machine to control yet';

  @override
  String get consoleNoMachineBody =>
      'Pair a machine on the Machines tab first — the console drives its agent';

  @override
  String get consoleNoSessionTitle => 'Pick a session to start';

  @override
  String get consoleNoSessionBody =>
      'Open the list to resume an engine-side session (the same one your desktop sees), or start a new one';

  @override
  String get segmentChat => 'Chat';

  @override
  String get segmentTasks => 'Tasks';

  @override
  String get segmentWorkspace => 'Workspace';

  @override
  String get segmentHost => 'Host';

  @override
  String get segmentTrajectory => 'Trace';

  @override
  String workspacesTitle(Object machine) {
    return 'Workspaces · $machine';
  }

  @override
  String get workspacesUngrouped => 'Ungrouped';

  @override
  String get workspacesEmpty =>
      'This machine hosts no workspace with sessions yet';

  @override
  String get workspacesLoadingSessions => 'Reading this machine\'s sessions…';

  @override
  String get workspacesUnavailable =>
      'Workspace registry unavailable: the engine\'s workspace/follow stream did not answer';

  @override
  String get workspacesEmptyGroup => 'No sessions in this workspace yet';

  @override
  String get workspacesSearchHint => 'Search workspaces or sessions';

  @override
  String workspacesMore(Object count) {
    return '$count more sessions';
  }

  @override
  String workspacesSessionCount(Object count) {
    return '$count sessions';
  }

  @override
  String get segmentTasksSoon => 'The tasks page arrives in T2.8';

  @override
  String get segmentHostSoon => 'The host page arrives in T2.8';

  @override
  String get sessionsTitleShort => 'Sessions';

  @override
  String sessionsTruncated(Object shown, Object total) {
    return 'Showing the $shown most recent of $total sessions';
  }

  @override
  String sessionsTitle(Object machine) {
    return 'Sessions · $machine';
  }

  @override
  String get sessionsNew => 'New session';

  @override
  String get sessionsEmpty => 'No sessions yet';

  @override
  String get sessionsEmptyBody =>
      'Start one and talk to the agent from your phone — the desktop sees the same session';

  @override
  String get sessionsUntitled => 'Untitled session';

  @override
  String get sessionsRunning => 'running';

  @override
  String get sessionsFooter =>
      'Sessions live on the engine · tap to resume (same session as the web client)';

  @override
  String sessionsRowSubtitle(Object turns, Object when) {
    return '$when · $turns turns';
  }

  @override
  String sessionsChildSubtitle(Object when) {
    return 'subagent · $when';
  }

  @override
  String get chatComposerHint => 'Message the agent…';

  @override
  String get chatSend => 'Send';

  @override
  String get chatReadOnly =>
      'This subagent is read-only and cannot accept input';

  @override
  String get chatFromSubagent => 'from';

  @override
  String get chatApprovalTitle => 'Approval requested';

  @override
  String get chatAllow => 'Allow';

  @override
  String get chatReject => 'Reject';

  @override
  String get chatQuestionPending => 'The agent is waiting for your answer';

  @override
  String chatQuestionProgress(Object answered, Object total) {
    return '$answered/$total answered';
  }

  @override
  String get chatQuestionSubmit => 'Submit';

  @override
  String get chatQuestionAbandon => 'Abandon';

  @override
  String get chatQuestionAbandonReason =>
      'The user abandoned this question on the phone';

  @override
  String get chatFreeTextHint => 'Free text (leave empty to skip)';

  @override
  String get chatCustomAlongsideHint =>
      'Extra note (optional, alongside your picks)';

  @override
  String get chatPlanReviewTitle => 'Plan awaiting approval';

  @override
  String get workspaceRootLabel => 'session workspace';

  @override
  String get workspaceUncategorized => 'Uncategorized';

  @override
  String get workspaceParent => 'Parent';

  @override
  String get workspaceTruncated =>
      'Too many entries — showing the first ones only';

  @override
  String get workspaceEmpty => 'This directory is empty';

  @override
  String workspaceSize(Object bytes) {
    return '$bytes B';
  }

  @override
  String get workspaceBack => 'Back to the listing';

  @override
  String get workspaceCopy => 'Copy contents';

  @override
  String get workspaceCopied => 'Copied';

  @override
  String workspaceMoreLines(Object lines) {
    return 'Next $lines lines';
  }

  @override
  String chatContextPercent(Object percent) {
    return 'context $percent%';
  }

  @override
  String get chatContextUnknown => 'context unknown';

  @override
  String chatTokensPerSecond(Object rate) {
    return '$rate tok/s';
  }

  @override
  String chatCachePercent(Object percent) {
    return 'cache $percent%';
  }

  @override
  String chatTurnsElapsed(Object turns) {
    return '$turns turns';
  }

  @override
  String get retry => 'Retry';

  @override
  String get modelTitle => 'Model & reasoning effort';

  @override
  String get modelFollowDefault => 'Follow default';

  @override
  String get modelFollowDefaultBody =>
      'This session has never chosen a model, so it follows the deployment default. Tap a model to pin one.';

  @override
  String get modelPickedBody =>
      'This session has pinned a model; the engine returns the normalized selection.';

  @override
  String get modelUseThis => 'Use';

  @override
  String modelEffortChip(Object effort, Object model) {
    return '$model · $effort';
  }

  @override
  String get modelEffortDefault => 'default';

  @override
  String get modelCatalogFailures =>
      'These providers could not be loaded (the rest are unaffected)';

  @override
  String get modelSheetFailed => 'Could not read the model catalog';

  @override
  String get contextTitle => 'Context & statistics';

  @override
  String get contextNotReported =>
      'The engine has not reported usage yet — shown as unknown, not 0%.';

  @override
  String get contextProjected => 'Projected';

  @override
  String get contextPressure => 'Current pressure';

  @override
  String get contextWindow => 'Context window';

  @override
  String get contextBreakdownTitle => 'Composition';

  @override
  String get contextBreakdownCaveat =>
      '(fixed-density estimates; do not reconcile with the total above)';

  @override
  String get contextSegmentSystem => 'System prompt';

  @override
  String get contextSegmentTools => 'Tool definitions';

  @override
  String get contextSegmentMessages => 'Messages';

  @override
  String get contextUsageTitle => 'Usage & statistics';

  @override
  String get contextUsageUncached => 'Uncached input';

  @override
  String get contextUsageCacheRead => 'Cache read';

  @override
  String get contextUsageCacheWrite => 'Cache write';

  @override
  String get contextUsageOutput => 'Output';

  @override
  String get contextTurns => 'Turns';

  @override
  String get teamTitle => 'Subagent team';

  @override
  String teamCount(Object count) {
    return '$count subagents';
  }

  @override
  String get teamEmpty => 'This session has no subagents yet';

  @override
  String get teamCatalogUnavailable =>
      'This session exposes no subagent catalog';

  @override
  String get teamReadOnly => 'read-only';

  @override
  String get teamModeTerminal => 'terminal · cannot be given more work';

  @override
  String get teamModeContinuable => 'can be continued';

  @override
  String get teamFooter =>
      'Tap a subagent to open its conversation; the card\'s mode says whether you can keep talking to it';

  @override
  String get teamBadgeTooltip => 'Subagent team';

  @override
  String get jobsEmpty => 'This session has no jobs';

  @override
  String get jobsStateRunning => 'running';

  @override
  String get jobsStateDone => 'finished';

  @override
  String get jobsStateFailed => 'failed';

  @override
  String get jobsStatePending => 'pending';

  @override
  String get jobsKill => 'Kill';

  @override
  String get jobsKillRequested => 'Kill requested';

  @override
  String get jobsNoFirstFrame =>
      'The job list never sent its first frame (engine did not answer)';

  @override
  String get jobsAlreadyFinished => 'That job had already finished';

  @override
  String get hostSessions => 'Sessions';

  @override
  String get hostModel => 'Current model';

  @override
  String get hostPlugins => 'Mounted plugins';

  @override
  String get hostPluginDisabled => 'disabled';

  @override
  String get hostPluginsNote =>
      'From the engine\'s pluginManager/listBundles — switches flip a whole bundle (applied on engine restart)';

  @override
  String get hostBundleModules => 'modules';

  @override
  String get hostPluginCoreLocked => 'Core module';

  @override
  String get hostPluginUnaddressable => 'Unaddressable';

  @override
  String get hostPluginRestartRequired =>
      'Recorded — applies after an engine restart';

  @override
  String get hostMetricsUnavailable =>
      'This engine version exposes no host metrics (no events.host or equivalent route), so no figures are guessed.';

  @override
  String get trajectoryEmpty => 'This session has no trace records yet';

  @override
  String get trajectoryNoSession =>
      'Open a session first — there is nothing to trace otherwise';

  @override
  String trajectoryTruncated(Object dropped, Object kept) {
    return 'The window keeps the $kept most recent records ($dropped older ones dropped; scroll up to load them back)';
  }

  @override
  String get trajectoryLoadEarlier => 'Load earlier records';

  @override
  String get trajectoryLoadingEarlier => 'Loading earlier records…';

  @override
  String trajectoryEarlierFailed(Object reason) {
    return 'Could not load earlier records: $reason';
  }

  @override
  String get trajectoryBetweenTurns => 'Between turns';

  @override
  String trajectoryTurn(Object turn) {
    return 'Turn $turn';
  }

  @override
  String trajectoryRequest(Object request) {
    return 'Request #$request';
  }

  @override
  String get trajectoryLaneSystem => 'System';

  @override
  String get trajectoryLaneMessage => 'Message';

  @override
  String get trajectoryLaneTool => 'Tool';

  @override
  String get trajectoryNoTiming =>
      'This record has no drawable duration (the engine recorded no start)';

  @override
  String get trajectoryInspector => 'Record';

  @override
  String get trajectoryTabPayload => 'Payload';

  @override
  String get trajectoryTabTiming => 'Timing';

  @override
  String get trajectoryTabUsage => 'Usage';

  @override
  String trajectoryRangeActive(Object from, Object to) {
    return 'Filtered $from–$to';
  }

  @override
  String get trajectoryRangeClear => 'Clear filter';

  @override
  String get trajectoryToolError => 'error';

  @override
  String get trajectoryToolReturn => 'returned';

  @override
  String get trajectoryHint =>
      'Tap a record for its raw payload · drag on the timeline to filter by interval';

  @override
  String get trajectoryTtft => 'TTFT';

  @override
  String get trajectoryDecode => 'Decode';

  @override
  String get trajectoryTotal => 'Total';

  @override
  String get trajectoryStarted => 'Start';

  @override
  String get trajectoryEnded => 'End';

  @override
  String get trajectoryEmptyRange => 'No records in the selected interval';

  @override
  String get workspacesFilter => 'Archive view';

  @override
  String get workspacesFilterHide => 'Hide archived';

  @override
  String get workspacesFilterShow => 'Show archived';

  @override
  String get workspacesFilterOnly => 'Archived only';

  @override
  String get workspacesArchivedBadge => 'Archived';

  @override
  String get workspacesArchivedHint =>
      'An archived session runs nothing — tap Unarchive to bring it back';

  @override
  String get workspacesArchivedNone => 'No archived sessions';

  @override
  String get workspacesUnarchive => 'Unarchive';

  @override
  String get workspacesDeadBadge => 'Gone';

  @override
  String get workspacesDeadHint =>
      'The engine no longer has this session — usually a host-side job that wrote its log straight to disk, or a registry leftover after cleanup. Archive to clear it from the list.';

  @override
  String chatFoldExpand(int count) {
    return 'Show all ($count chars)';
  }

  @override
  String get chatFoldCollapse => 'Collapse';

  @override
  String get chatMetaSystemReminder => 'System reminder';

  @override
  String get chatMetaRuntimeContext => 'Runtime context';

  @override
  String get chatMetaInjected => 'System message';

  @override
  String chatMetaChip(String label, int count) {
    return '$label · $count chars';
  }

  @override
  String get chatThinkingActive => '💭 Thinking…';

  @override
  String chatThinkingActiveCount(int count) {
    return '💭 Thinking · $count chars';
  }

  @override
  String chatThinkingActiveExpanded(int count) {
    return '💭 Thinking · $count chars (tap to collapse)';
  }

  @override
  String chatThoughtCollapsed(int count) {
    return '💭 Thought · $count chars (tap to expand)';
  }

  @override
  String chatThoughtExpanded(int count) {
    return '💭 Thought · $count chars (tap to collapse)';
  }

  @override
  String get chatToolCallLabel => 'Tool call';

  @override
  String get chatToolArgs => 'Arguments';

  @override
  String get chatToolResult => 'Result';

  @override
  String get presetsSheetTitle => 'Pick an agent preset';

  @override
  String get presetsWorkspaceSection => 'Where to open it';

  @override
  String get presetsWorkspaceDefault => 'Engine default';

  @override
  String get presetsQuickCreate => 'New session (default preset)';

  @override
  String get presetsDefaultChip => 'default';

  @override
  String get presetsBrokenChip => 'broken config';

  @override
  String get presetsLoadFailed =>
      'Could not load presets. Use “New session” for the default preset.';

  @override
  String get workspacesUnarchiveFailed => 'Could not unarchive';

  @override
  String get workspacesArchive => 'Archive';

  @override
  String get workspacesArchiveFailed => 'Could not archive';

  @override
  String get workspacesPin => 'Pin';

  @override
  String get workspacesUnpin => 'Unpin';

  @override
  String get workspacesPinFailed => 'Could not pin';

  @override
  String get workspacesArchiveBusyTitle => 'This session is still running';

  @override
  String get workspacesArchiveBusyBody => 'Archiving means stopping it first:';

  @override
  String get workspacesArchiveBusyStopAndArchive => 'Stop and archive';

  @override
  String get workspacesArchiveBusyCancel => 'Cancel';

  @override
  String get workspacesArchiveActivityTurn => 'an in-progress turn';

  @override
  String get workspacesArchiveActivityJob => 'background jobs';

  @override
  String get workspacesArchiveActivitySubagent => 'subagents';

  @override
  String get workspacesArchiveActivitySchedule => 'schedules';

  @override
  String workspacesArchiveActivityOther(Object kind) {
    return 'other ($kind)';
  }

  @override
  String get workspacesArchiveActivityJoin => ', ';

  @override
  String workspacesArchiveActivityWith(Object label, Object names) {
    return '$label: $names';
  }

  @override
  String get workspacesArchiveDone => 'Archived';

  @override
  String get workspacesSyncing => 'Syncing workspace membership…';

  @override
  String get settingsDiagnosticsTitle => 'Diagnostics log';

  @override
  String get settingsDiagnosticsSub =>
      'Sanitized local log — stays on this device';

  @override
  String diagnosticsMeta(String size, String lines) {
    return '$size · $lines lines';
  }

  @override
  String get diagnosticsEmpty => 'No log entries yet.';

  @override
  String get diagnosticsCopied => 'Log copied';

  @override
  String get diagnosticsShare => 'Share log';

  @override
  String get diagnosticsCopyAll => 'Copy all';

  @override
  String get diagnosticsClear => 'Clear log';

  @override
  String get diagnosticsCancel => 'Cancel';

  @override
  String get diagnosticsClearTitle => 'Clear the log?';

  @override
  String get diagnosticsClearBody =>
      'Log files on this device will be deleted.';

  @override
  String get diagnosticsCleared => 'Log cleared';

  @override
  String get diagnosticsShareSubject => 'DSH Remote diagnostics log';

  @override
  String get authCauseExpired => 'Session expired';

  @override
  String get authCauseRevoked => 'Credential revoked';

  @override
  String get authCauseMaxAge => 'Past the 30-day cap';

  @override
  String get authCauseUnknown => 'Cause unknown';

  @override
  String get consoleCredentialDead =>
      'Credential expired — it will not recover on its own';

  @override
  String consoleCredentialDeadWhy(Object cause) {
    return '$cause · re-pair to continue';
  }

  @override
  String get consoleGoRepair => 'Re-pair now';

  @override
  String get diagnosticsChannelLabel => 'Log channel';

  @override
  String get diagnosticsChannelAll => 'All';

  @override
  String get diagnosticsChannelApp => 'Runtime';

  @override
  String get diagnosticsChannelCrash => 'Crash';

  @override
  String get diagnosticsChannelAudit => 'Actions';

  @override
  String get diagnosticsChannelEmpty => 'No entries in this channel.';

  @override
  String get settingsUpdateCheckTitle => 'Check for updates';

  @override
  String get settingsUpdateCheckSub =>
      'Ask GitHub whether a newer build exists (prompt only, never auto-installs)';

  @override
  String get updateCheckIdle => 'Not checked yet';

  @override
  String get updateCheckChecking => 'Checking…';

  @override
  String updateCheckUpToDate(Object version) {
    return 'Up to date ($version)';
  }

  @override
  String updateCheckAvailable(Object latest) {
    return 'New version $latest available';
  }

  @override
  String updateCheckFailed(Object reason) {
    return 'Check failed: $reason';
  }

  @override
  String get updateCheckOpen => 'Open download page';

  @override
  String updateCheckSize(Object mb) {
    return '$mb MB';
  }

  @override
  String get updateErrBadJson => 'Response was not a JSON object';

  @override
  String get updateErrNoTag => 'That release has no version tag';
}
