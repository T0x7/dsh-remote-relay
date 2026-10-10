import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L10n
/// returned by `L10n.of(context)`.
///
/// Applications need to include `L10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L10n.localizationsDelegates,
///   supportedLocales: L10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L10n.supportedLocales
/// property.
abstract class L10n {
  L10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L10n of(BuildContext context) {
    return Localizations.of<L10n>(context, L10n)!;
  }

  static const LocalizationsDelegate<L10n> delegate = _L10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @tabMachines.
  ///
  /// In en, this message translates to:
  /// **'Machines'**
  String get tabMachines;

  /// No description provided for @tabConsole.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get tabConsole;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @consoleTitle.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get consoleTitle;

  /// No description provided for @consoleBody.
  ///
  /// In en, this message translates to:
  /// **'Chat, tasks and approvals land in M2.\nPair a machine first under Machines.'**
  String get consoleBody;

  /// No description provided for @machinesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No machines yet'**
  String get machinesEmptyTitle;

  /// No description provided for @machinesEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Run dsh-remote-client pair on your computer (or open the plugin\'s Remote Control card), then scan the QR to add it.'**
  String get machinesEmptyBody;

  /// No description provided for @machinesAddFab.
  ///
  /// In en, this message translates to:
  /// **'Add machine'**
  String get machinesAddFab;

  /// No description provided for @machinesScanOrPaste.
  ///
  /// In en, this message translates to:
  /// **'Scan / paste link'**
  String get machinesScanOrPaste;

  /// No description provided for @cardExpiredHint.
  ///
  /// In en, this message translates to:
  /// **'Session expired · tap to re-pair'**
  String get cardExpiredHint;

  /// No description provided for @cardSessionLine.
  ///
  /// In en, this message translates to:
  /// **'{left} left · day {day}/30'**
  String cardSessionLine(Object day, Object left);

  /// No description provided for @machinesEngineUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Tunnel is up, but the engine is not answering · check dsh on your machine'**
  String get machinesEngineUnreachable;

  /// No description provided for @chipExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get chipExpired;

  /// No description provided for @chipAutoRenew.
  ///
  /// In en, this message translates to:
  /// **'Auto-renew'**
  String get chipAutoRenew;

  /// No description provided for @pairingTitle.
  ///
  /// In en, this message translates to:
  /// **'Add machine'**
  String get pairingTitle;

  /// No description provided for @pairingHint.
  ///
  /// In en, this message translates to:
  /// **'Paste pairing link (https://relay…/?sessionId=…)'**
  String get pairingHint;

  /// No description provided for @pairingParse.
  ///
  /// In en, this message translates to:
  /// **'Parse link'**
  String get pairingParse;

  /// No description provided for @errTokenRetired.
  ///
  /// In en, this message translates to:
  /// **'Not a signed link (the token form is retired)'**
  String get errTokenRetired;

  /// No description provided for @errWindowExpired.
  ///
  /// In en, this message translates to:
  /// **'Link expired or outside the 1 min–24 h window'**
  String get errWindowExpired;

  /// No description provided for @errMalformed.
  ///
  /// In en, this message translates to:
  /// **'Malformed link: {reason}'**
  String errMalformed(Object reason);

  /// No description provided for @errNotUrl.
  ///
  /// In en, this message translates to:
  /// **'Not a valid URL'**
  String get errNotUrl;

  /// No description provided for @confirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm machine'**
  String get confirmTitle;

  /// No description provided for @confirmSessionLine.
  ///
  /// In en, this message translates to:
  /// **'Valid 24 h · auto-renews before expiry'**
  String get confirmSessionLine;

  /// No description provided for @kvRelay.
  ///
  /// In en, this message translates to:
  /// **'Relay'**
  String get kvRelay;

  /// No description provided for @kvMachine.
  ///
  /// In en, this message translates to:
  /// **'Machine'**
  String get kvMachine;

  /// No description provided for @confirmSecurity.
  ///
  /// In en, this message translates to:
  /// **'Credentials live only in this device\'s secure storage (Keychain / Keystore); the link is verified before anything is stored.'**
  String get confirmSecurity;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionLockAndConnect.
  ///
  /// In en, this message translates to:
  /// **'Lock & connect'**
  String get actionLockAndConnect;

  /// No description provided for @verifyingLink.
  ///
  /// In en, this message translates to:
  /// **'Verifying the link (invalid credentials are never stored)…'**
  String get verifyingLink;

  /// No description provided for @qrExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'QR expired'**
  String get qrExpiredTitle;

  /// No description provided for @qrExpiredBody.
  ///
  /// In en, this message translates to:
  /// **'The machine\'s QR expired or was replaced (each mint replaces the old one). Refresh it on the computer and retry.'**
  String get qrExpiredBody;

  /// No description provided for @unreachableTitle.
  ///
  /// In en, this message translates to:
  /// **'Relay unreachable'**
  String get unreachableTitle;

  /// No description provided for @unreachableBody.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the relay — check the phone network and the relay address.'**
  String get unreachableBody;

  /// No description provided for @actionRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get actionRetry;

  /// No description provided for @detailSectionTunnel.
  ///
  /// In en, this message translates to:
  /// **'Tunnel'**
  String get detailSectionTunnel;

  /// No description provided for @detailSectionSession.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get detailSectionSession;

  /// No description provided for @detailSectionDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices · {line}'**
  String detailSectionDevices(Object line);

  /// No description provided for @detailSectionActions.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get detailSectionActions;

  /// No description provided for @stateConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get stateConnected;

  /// No description provided for @stateConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get stateConnecting;

  /// No description provided for @stateReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting'**
  String get stateReconnecting;

  /// No description provided for @stateManualOff.
  ///
  /// In en, this message translates to:
  /// **'Manually off'**
  String get stateManualOff;

  /// No description provided for @stateDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get stateDisabled;

  /// No description provided for @stateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get stateUnknown;

  /// No description provided for @kvState.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get kvState;

  /// No description provided for @kvReported.
  ///
  /// In en, this message translates to:
  /// **'Reported'**
  String get kvReported;

  /// No description provided for @detailRemaining.
  ///
  /// In en, this message translates to:
  /// **'{left} left'**
  String detailRemaining(Object left);

  /// No description provided for @detailCapLine.
  ///
  /// In en, this message translates to:
  /// **'Session life: day {day}/30 (re-scan after it ends)'**
  String detailCapLine(Object day);

  /// No description provided for @detailPairedOnline.
  ///
  /// In en, this message translates to:
  /// **'{paired} paired / {online} online'**
  String detailPairedOnline(Object online, Object paired);

  /// No description provided for @detailSnapshotMissing.
  ///
  /// In en, this message translates to:
  /// **'Snapshot unavailable'**
  String get detailSnapshotMissing;

  /// No description provided for @detailThisSession.
  ///
  /// In en, this message translates to:
  /// **'This session'**
  String get detailThisSession;

  /// No description provided for @deviceOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get deviceOnline;

  /// No description provided for @deviceOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get deviceOffline;

  /// No description provided for @devicePairedSuffix.
  ///
  /// In en, this message translates to:
  /// **' · paired'**
  String get devicePairedSuffix;

  /// No description provided for @actionCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy full web-UI link (24 h)'**
  String get actionCopyLink;

  /// No description provided for @actionDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect relay'**
  String get actionDisconnect;

  /// No description provided for @actionReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect relay'**
  String get actionReconnect;

  /// No description provided for @actionRevokeAll.
  ///
  /// In en, this message translates to:
  /// **'Revoke all pairings…'**
  String get actionRevokeAll;

  /// No description provided for @revokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke all pairings?'**
  String get revokeTitle;

  /// No description provided for @revokeBody.
  ///
  /// In en, this message translates to:
  /// **'Every device (including this phone) loses access immediately. The machine must mint a new QR.'**
  String get revokeBody;

  /// No description provided for @actionRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get actionRevoke;

  /// No description provided for @snackDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Relay disconnected'**
  String get snackDisconnected;

  /// No description provided for @snackReconnected.
  ///
  /// In en, this message translates to:
  /// **'Relay reconnected'**
  String get snackReconnected;

  /// No description provided for @snackRejected.
  ///
  /// In en, this message translates to:
  /// **'Action rejected by the engine'**
  String get snackRejected;

  /// No description provided for @snackRevoked.
  ///
  /// In en, this message translates to:
  /// **'Revoked {n} session(s)'**
  String snackRevoked(Object n);

  /// No description provided for @snackLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied 24 h web-UI link — open it in a browser'**
  String get snackLinkCopied;

  /// No description provided for @snackMintFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not mint a link (relay unreachable or expired)'**
  String get snackMintFailed;

  /// No description provided for @expiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Session expired'**
  String get expiredTitle;

  /// No description provided for @expiredChipWindow.
  ///
  /// In en, this message translates to:
  /// **'24 h window expired'**
  String get expiredChipWindow;

  /// No description provided for @expiredChipRevoked.
  ///
  /// In en, this message translates to:
  /// **'Revoked'**
  String get expiredChipRevoked;

  /// No description provided for @expiredChipMaxAge.
  ///
  /// In en, this message translates to:
  /// **'30-day cap reached'**
  String get expiredChipMaxAge;

  /// No description provided for @expiredChipUnknown.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expiredChipUnknown;

  /// No description provided for @expiredCauseWindow.
  ///
  /// In en, this message translates to:
  /// **'The 24 h window elapsed; auto-renewal did not complete'**
  String get expiredCauseWindow;

  /// No description provided for @expiredCauseMaxAge.
  ///
  /// In en, this message translates to:
  /// **'Absolute session lifetime reached (day {day}) — re-pair on the computer'**
  String expiredCauseMaxAge(Object day);

  /// No description provided for @expiredCauseRevoked.
  ///
  /// In en, this message translates to:
  /// **'This machine\'s pairing was revoked on another device or computer'**
  String get expiredCauseRevoked;

  /// No description provided for @expiredCauseUnknown.
  ///
  /// In en, this message translates to:
  /// **'The session no longer exists server-side'**
  String get expiredCauseUnknown;

  /// No description provided for @expiredScopeHint.
  ///
  /// In en, this message translates to:
  /// **'Only this machine is affected — others keep working.'**
  String get expiredScopeHint;

  /// No description provided for @expiredRepairHint.
  ///
  /// In en, this message translates to:
  /// **'Open dsh Settings → Remote Control on the computer, refresh the QR, then scan it to recover.'**
  String get expiredRepairHint;

  /// No description provided for @actionRescan.
  ///
  /// In en, this message translates to:
  /// **'Re-scan'**
  String get actionRescan;

  /// No description provided for @actionDeleteMachine.
  ///
  /// In en, this message translates to:
  /// **'Delete this machine…'**
  String get actionDeleteMachine;

  /// No description provided for @settingsLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Biometric lock'**
  String get settingsLockTitle;

  /// No description provided for @settingsLockSubProbing.
  ///
  /// In en, this message translates to:
  /// **'Checking what this device can verify…'**
  String get settingsLockSubProbing;

  /// No description provided for @settingsLockSubBiometric.
  ///
  /// In en, this message translates to:
  /// **'Credentials decrypt only after unlock · verified by system biometrics'**
  String get settingsLockSubBiometric;

  /// No description provided for @settingsLockSubDeviceCredential.
  ///
  /// In en, this message translates to:
  /// **'No biometrics enrolled — your device passcode or pattern will be used'**
  String get settingsLockSubDeviceCredential;

  /// No description provided for @settingsLockSubUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device has no biometrics available — unlocking must be manual'**
  String get settingsLockSubUnsupported;

  /// No description provided for @settingsPinsTitle.
  ///
  /// In en, this message translates to:
  /// **'Certificate pinning (TOFU)'**
  String get settingsPinsTitle;

  /// No description provided for @settingsPinsNone.
  ///
  /// In en, this message translates to:
  /// **'No certificate pinned · re-pair an https relay to lock one'**
  String get settingsPinsNone;

  /// No description provided for @settingsPinsCount.
  ///
  /// In en, this message translates to:
  /// **'{n} pinned · view fingerprints'**
  String settingsPinsCount(Object n);

  /// No description provided for @settingsRemindersTitle.
  ///
  /// In en, this message translates to:
  /// **'In-app reminders'**
  String get settingsRemindersTitle;

  /// No description provided for @settingsRemindersSub.
  ///
  /// In en, this message translates to:
  /// **'Tunnel down · task finished (only while the app is open — no push)'**
  String get settingsRemindersSub;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageSub.
  ///
  /// In en, this message translates to:
  /// **'Follow system · 中文 / English (only these)'**
  String get settingsLanguageSub;

  /// No description provided for @settingsAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// No description provided for @settingsAboutSub.
  ///
  /// In en, this message translates to:
  /// **'v0.1.0 · tunnel protocol v:1 · MIT'**
  String get settingsAboutSub;

  /// No description provided for @settingsFooter.
  ///
  /// In en, this message translates to:
  /// **'Zero telemetry · zero crash reporting · zero third-party SDKs\nOpen source with dsh-remote-relay'**
  String get settingsFooter;

  /// No description provided for @pinsHowTofu.
  ///
  /// In en, this message translates to:
  /// **'TOFU: the relay certificate\'s fingerprint is remembered on first connect and must match on every connect after that; a mismatch breaks the link.'**
  String get pinsHowTofu;

  /// No description provided for @pinsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No pinned relay yet'**
  String get pinsEmptyTitle;

  /// No description provided for @pinsNoPinNeeded.
  ///
  /// In en, this message translates to:
  /// **'Plain http — no pin needed'**
  String get pinsNoPinNeeded;

  /// No description provided for @pinsFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Certificate fingerprint (SHA-256)'**
  String get pinsFingerprint;

  /// No description provided for @pinsReadOnlyNote.
  ///
  /// In en, this message translates to:
  /// **'This page is read-only. Dropping a pin downgrades the link to \"trust whatever answers first\"; to change a fingerprint, re-pair on the computer.'**
  String get pinsReadOnlyNote;

  /// No description provided for @languageOptionZh.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get languageOptionZh;

  /// No description provided for @languageOptionEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageOptionEn;

  /// No description provided for @languageEffective.
  ///
  /// In en, this message translates to:
  /// **'In effect now: {value}'**
  String languageEffective(Object value);

  /// No description provided for @languageEffectiveUnknown.
  ///
  /// In en, this message translates to:
  /// **'In effect now: unknown (no translation for the system language)'**
  String get languageEffectiveUnknown;

  /// No description provided for @languageStartupNote.
  ///
  /// In en, this message translates to:
  /// **'The interface language is decided when the app starts; your choice is saved and read on the next launch.'**
  String get languageStartupNote;

  /// No description provided for @aboutAppVersion.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get aboutAppVersion;

  /// No description provided for @aboutProtocolVersion.
  ///
  /// In en, this message translates to:
  /// **'Tunnel protocol version'**
  String get aboutProtocolVersion;

  /// No description provided for @aboutLicense.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get aboutLicense;

  /// No description provided for @aboutSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get aboutSource;

  /// No description provided for @aboutNoOtaNote.
  ///
  /// In en, this message translates to:
  /// **'No OTA and no self-update: the source is the artifact — rebuild to upgrade.'**
  String get aboutNoOtaNote;

  /// No description provided for @lockTitle.
  ///
  /// In en, this message translates to:
  /// **'dsh remote is locked'**
  String get lockTitle;

  /// No description provided for @lockSub.
  ///
  /// In en, this message translates to:
  /// **'Session credentials decrypt only after unlock'**
  String get lockSub;

  /// No description provided for @lockAction.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockAction;

  /// No description provided for @lockReason.
  ///
  /// In en, this message translates to:
  /// **'Unlock to decrypt your session credentials'**
  String get lockReason;

  /// No description provided for @lockVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying…'**
  String get lockVerifying;

  /// No description provided for @lockFailed.
  ///
  /// In en, this message translates to:
  /// **'Not verified — try again'**
  String get lockFailed;

  /// No description provided for @lockCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get lockCancelled;

  /// No description provided for @lockUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The system could not verify — check this device\'s screen lock and biometrics settings'**
  String get lockUnavailable;

  /// No description provided for @lockNoBiometrics.
  ///
  /// In en, this message translates to:
  /// **'This device has no biometrics available'**
  String get lockNoBiometrics;

  /// No description provided for @lockNoBiometricsTried.
  ///
  /// In en, this message translates to:
  /// **'This device has no biometrics or screen lock (system verification was tried)'**
  String get lockNoBiometricsTried;

  /// No description provided for @lockFootnote.
  ///
  /// In en, this message translates to:
  /// **'Verified by system biometrics or your device passcode · credentials stay in the system keystore'**
  String get lockFootnote;

  /// No description provided for @lockFootnotePlain.
  ///
  /// In en, this message translates to:
  /// **'This device has no biometrics, so unlocking needs you in person'**
  String get lockFootnotePlain;

  /// No description provided for @err_network_unreachable.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the relay — check the network and relay address'**
  String get err_network_unreachable;

  /// No description provided for @err_tls_cert_changed.
  ///
  /// In en, this message translates to:
  /// **'The relay certificate changed — if this was not you, delete the machine and re-pair'**
  String get err_tls_cert_changed;

  /// No description provided for @err_auth_expired.
  ///
  /// In en, this message translates to:
  /// **'Session expired (24 h window)'**
  String get err_auth_expired;

  /// No description provided for @err_auth_revoked.
  ///
  /// In en, this message translates to:
  /// **'The pairing was revoked'**
  String get err_auth_revoked;

  /// No description provided for @err_auth_max_age.
  ///
  /// In en, this message translates to:
  /// **'Session hit its 30-day cap'**
  String get err_auth_max_age;

  /// No description provided for @err_auth_missing.
  ///
  /// In en, this message translates to:
  /// **'No session credential'**
  String get err_auth_missing;

  /// No description provided for @err_ratelimit_hit.
  ///
  /// In en, this message translates to:
  /// **'Too many requests — try again shortly'**
  String get err_ratelimit_hit;

  /// No description provided for @err_engine_down.
  ///
  /// In en, this message translates to:
  /// **'The engine on the machine did not respond (it may have exited)'**
  String get err_engine_down;

  /// No description provided for @err_payload_too_large.
  ///
  /// In en, this message translates to:
  /// **'Response exceeded the 32 MiB cap'**
  String get err_payload_too_large;

  /// No description provided for @err_concurrency_exceeded.
  ///
  /// In en, this message translates to:
  /// **'Too many large responses in flight'**
  String get err_concurrency_exceeded;

  /// No description provided for @err_api_privileged.
  ///
  /// In en, this message translates to:
  /// **'That action is loopback-only (engine privileged method)'**
  String get err_api_privileged;

  /// No description provided for @err_ws_device_replaced.
  ///
  /// In en, this message translates to:
  /// **'Connected on another device; reconnecting the event stream'**
  String get err_ws_device_replaced;

  /// No description provided for @consoleReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Connection lost, reconnecting…'**
  String get consoleReconnecting;

  /// No description provided for @err_pair_qr_invalid.
  ///
  /// In en, this message translates to:
  /// **'The QR/link is invalid or expired'**
  String get err_pair_qr_invalid;

  /// No description provided for @err_renew_failed.
  ///
  /// In en, this message translates to:
  /// **'Auto-renewal failed — re-scan soon'**
  String get err_renew_failed;

  /// No description provided for @err_storage_error.
  ///
  /// In en, this message translates to:
  /// **'Secure storage is not writable'**
  String get err_storage_error;

  /// No description provided for @err_engine_timeout.
  ///
  /// In en, this message translates to:
  /// **'The engine took too long — retrying'**
  String get err_engine_timeout;

  /// No description provided for @err_engine_unknown.
  ///
  /// In en, this message translates to:
  /// **'The engine returned an unknown error'**
  String get err_engine_unknown;

  /// No description provided for @pairingScan.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get pairingScan;

  /// No description provided for @scanTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan to pair'**
  String get scanTitle;

  /// No description provided for @scanHint.
  ///
  /// In en, this message translates to:
  /// **'Point at the plugin Remote Control card, or the QR printed by pair'**
  String get scanHint;

  /// No description provided for @cameraUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable'**
  String get cameraUnavailable;

  /// No description provided for @cameraError.
  ///
  /// In en, this message translates to:
  /// **'Error: {code}\nUse the paste-link entry instead.'**
  String cameraError(Object code);

  /// No description provided for @actionBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// No description provided for @actionOpenWeb.
  ///
  /// In en, this message translates to:
  /// **'Open full web UI in browser'**
  String get actionOpenWeb;

  /// No description provided for @snackOpeningWeb.
  ///
  /// In en, this message translates to:
  /// **'Opening the full UI (24 h link)…'**
  String get snackOpeningWeb;

  /// No description provided for @snackCopyFallback.
  ///
  /// In en, this message translates to:
  /// **'Could not open a browser — link copied'**
  String get snackCopyFallback;

  /// No description provided for @renewFailedChip.
  ///
  /// In en, this message translates to:
  /// **'Renewal failed'**
  String get renewFailedChip;

  /// No description provided for @err_engine_session_gone.
  ///
  /// In en, this message translates to:
  /// **'This session no longer exists (it may have been deleted on the other end)'**
  String get err_engine_session_gone;

  /// No description provided for @err_session_writer_held.
  ///
  /// In en, this message translates to:
  /// **'The other end is editing this session — try again shortly'**
  String get err_session_writer_held;

  /// No description provided for @err_session_agent_busy.
  ///
  /// In en, this message translates to:
  /// **'This child session is held by the agent; act from the parent session'**
  String get err_session_agent_busy;

  /// No description provided for @err_subagent_read_only.
  ///
  /// In en, this message translates to:
  /// **'This subagent is read-only and cannot accept input'**
  String get err_subagent_read_only;

  /// No description provided for @err_model_unavailable.
  ///
  /// In en, this message translates to:
  /// **'The selected model or its provider is unavailable'**
  String get err_model_unavailable;

  /// No description provided for @err_engine_unsupported.
  ///
  /// In en, this message translates to:
  /// **'This engine build does not support the operation — upgrade dsh'**
  String get err_engine_unsupported;

  /// No description provided for @err_engine_unavailable.
  ///
  /// In en, this message translates to:
  /// **'The engine is temporarily unavailable — retrying'**
  String get err_engine_unavailable;

  /// No description provided for @err_engine_cancelled.
  ///
  /// In en, this message translates to:
  /// **'Operation cancelled'**
  String get err_engine_cancelled;

  /// No description provided for @consoleNoMachine.
  ///
  /// In en, this message translates to:
  /// **'No machine to control yet'**
  String get consoleNoMachine;

  /// No description provided for @consoleNoMachineBody.
  ///
  /// In en, this message translates to:
  /// **'Pair a machine on the Machines tab first — the console drives its agent'**
  String get consoleNoMachineBody;

  /// No description provided for @consoleNoSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a session to start'**
  String get consoleNoSessionTitle;

  /// No description provided for @consoleNoSessionBody.
  ///
  /// In en, this message translates to:
  /// **'Open the list to resume an engine-side session (the same one your desktop sees), or start a new one'**
  String get consoleNoSessionBody;

  /// No description provided for @segmentChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get segmentChat;

  /// No description provided for @segmentTasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get segmentTasks;

  /// No description provided for @segmentWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get segmentWorkspace;

  /// No description provided for @segmentHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get segmentHost;

  /// No description provided for @segmentTrajectory.
  ///
  /// In en, this message translates to:
  /// **'Trace'**
  String get segmentTrajectory;

  /// No description provided for @workspacesTitle.
  ///
  /// In en, this message translates to:
  /// **'Workspaces · {machine}'**
  String workspacesTitle(Object machine);

  /// No description provided for @workspacesUngrouped.
  ///
  /// In en, this message translates to:
  /// **'Ungrouped'**
  String get workspacesUngrouped;

  /// No description provided for @workspacesEmpty.
  ///
  /// In en, this message translates to:
  /// **'This machine hosts no workspace with sessions yet'**
  String get workspacesEmpty;

  /// No description provided for @workspacesLoadingSessions.
  ///
  /// In en, this message translates to:
  /// **'Reading this machine\'s sessions…'**
  String get workspacesLoadingSessions;

  /// No description provided for @workspacesUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Workspace registry unavailable: the engine\'s workspace/follow stream did not answer'**
  String get workspacesUnavailable;

  /// No description provided for @workspacesEmptyGroup.
  ///
  /// In en, this message translates to:
  /// **'No sessions in this workspace yet'**
  String get workspacesEmptyGroup;

  /// No description provided for @workspacesSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search workspaces or sessions'**
  String get workspacesSearchHint;

  /// No description provided for @workspacesMore.
  ///
  /// In en, this message translates to:
  /// **'{count} more sessions'**
  String workspacesMore(Object count);

  /// No description provided for @workspacesSessionCount.
  ///
  /// In en, this message translates to:
  /// **'{count} sessions'**
  String workspacesSessionCount(Object count);

  /// No description provided for @segmentTasksSoon.
  ///
  /// In en, this message translates to:
  /// **'The tasks page arrives in T2.8'**
  String get segmentTasksSoon;

  /// No description provided for @segmentHostSoon.
  ///
  /// In en, this message translates to:
  /// **'The host page arrives in T2.8'**
  String get segmentHostSoon;

  /// No description provided for @sessionsTitleShort.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get sessionsTitleShort;

  /// No description provided for @sessionsTruncated.
  ///
  /// In en, this message translates to:
  /// **'Showing the {shown} most recent of {total} sessions'**
  String sessionsTruncated(Object shown, Object total);

  /// No description provided for @sessionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Sessions · {machine}'**
  String sessionsTitle(Object machine);

  /// No description provided for @sessionsNew.
  ///
  /// In en, this message translates to:
  /// **'New session'**
  String get sessionsNew;

  /// No description provided for @sessionsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No sessions yet'**
  String get sessionsEmpty;

  /// No description provided for @sessionsEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Start one and talk to the agent from your phone — the desktop sees the same session'**
  String get sessionsEmptyBody;

  /// No description provided for @sessionsUntitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled session'**
  String get sessionsUntitled;

  /// No description provided for @sessionsRunning.
  ///
  /// In en, this message translates to:
  /// **'running'**
  String get sessionsRunning;

  /// No description provided for @sessionsFooter.
  ///
  /// In en, this message translates to:
  /// **'Sessions live on the engine · tap to resume (same session as the web client)'**
  String get sessionsFooter;

  /// No description provided for @sessionsRowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{when} · {turns} turns'**
  String sessionsRowSubtitle(Object turns, Object when);

  /// No description provided for @sessionsChildSubtitle.
  ///
  /// In en, this message translates to:
  /// **'subagent · {when}'**
  String sessionsChildSubtitle(Object when);

  /// No description provided for @chatComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Message the agent…'**
  String get chatComposerHint;

  /// No description provided for @chatSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSend;

  /// No description provided for @chatReadOnly.
  ///
  /// In en, this message translates to:
  /// **'This subagent is read-only and cannot accept input'**
  String get chatReadOnly;

  /// No description provided for @chatFromSubagent.
  ///
  /// In en, this message translates to:
  /// **'from'**
  String get chatFromSubagent;

  /// No description provided for @chatApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'Approval requested'**
  String get chatApprovalTitle;

  /// No description provided for @chatAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get chatAllow;

  /// No description provided for @chatReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get chatReject;

  /// No description provided for @chatQuestionPending.
  ///
  /// In en, this message translates to:
  /// **'The agent is waiting for your answer'**
  String get chatQuestionPending;

  /// No description provided for @chatQuestionProgress.
  ///
  /// In en, this message translates to:
  /// **'{answered}/{total} answered'**
  String chatQuestionProgress(Object answered, Object total);

  /// No description provided for @chatQuestionSubmit.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get chatQuestionSubmit;

  /// No description provided for @chatQuestionAbandon.
  ///
  /// In en, this message translates to:
  /// **'Abandon'**
  String get chatQuestionAbandon;

  /// No description provided for @chatQuestionAbandonReason.
  ///
  /// In en, this message translates to:
  /// **'The user abandoned this question on the phone'**
  String get chatQuestionAbandonReason;

  /// No description provided for @chatFreeTextHint.
  ///
  /// In en, this message translates to:
  /// **'Free text (leave empty to skip)'**
  String get chatFreeTextHint;

  /// No description provided for @chatCustomAlongsideHint.
  ///
  /// In en, this message translates to:
  /// **'Extra note (optional, alongside your picks)'**
  String get chatCustomAlongsideHint;

  /// No description provided for @chatPlanReviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Plan awaiting approval'**
  String get chatPlanReviewTitle;

  /// No description provided for @workspaceRootLabel.
  ///
  /// In en, this message translates to:
  /// **'session workspace'**
  String get workspaceRootLabel;

  /// No description provided for @workspaceUncategorized.
  ///
  /// In en, this message translates to:
  /// **'Uncategorized'**
  String get workspaceUncategorized;

  /// No description provided for @workspaceParent.
  ///
  /// In en, this message translates to:
  /// **'Parent'**
  String get workspaceParent;

  /// No description provided for @workspaceTruncated.
  ///
  /// In en, this message translates to:
  /// **'Too many entries — showing the first ones only'**
  String get workspaceTruncated;

  /// No description provided for @workspaceEmpty.
  ///
  /// In en, this message translates to:
  /// **'This directory is empty'**
  String get workspaceEmpty;

  /// No description provided for @workspaceSize.
  ///
  /// In en, this message translates to:
  /// **'{bytes} B'**
  String workspaceSize(Object bytes);

  /// No description provided for @workspaceBack.
  ///
  /// In en, this message translates to:
  /// **'Back to the listing'**
  String get workspaceBack;

  /// No description provided for @workspaceCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy contents'**
  String get workspaceCopy;

  /// No description provided for @workspaceCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get workspaceCopied;

  /// No description provided for @workspaceMoreLines.
  ///
  /// In en, this message translates to:
  /// **'Next {lines} lines'**
  String workspaceMoreLines(Object lines);

  /// No description provided for @chatContextPercent.
  ///
  /// In en, this message translates to:
  /// **'context {percent}%'**
  String chatContextPercent(Object percent);

  /// No description provided for @chatContextUnknown.
  ///
  /// In en, this message translates to:
  /// **'context unknown'**
  String get chatContextUnknown;

  /// No description provided for @chatTokensPerSecond.
  ///
  /// In en, this message translates to:
  /// **'{rate} tok/s'**
  String chatTokensPerSecond(Object rate);

  /// No description provided for @chatCachePercent.
  ///
  /// In en, this message translates to:
  /// **'cache {percent}%'**
  String chatCachePercent(Object percent);

  /// No description provided for @chatTurnsElapsed.
  ///
  /// In en, this message translates to:
  /// **'{turns} turns'**
  String chatTurnsElapsed(Object turns);

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @modelTitle.
  ///
  /// In en, this message translates to:
  /// **'Model & reasoning effort'**
  String get modelTitle;

  /// No description provided for @modelFollowDefault.
  ///
  /// In en, this message translates to:
  /// **'Follow default'**
  String get modelFollowDefault;

  /// No description provided for @modelFollowDefaultBody.
  ///
  /// In en, this message translates to:
  /// **'This session has never chosen a model, so it follows the deployment default. Tap a model to pin one.'**
  String get modelFollowDefaultBody;

  /// No description provided for @modelPickedBody.
  ///
  /// In en, this message translates to:
  /// **'This session has pinned a model; the engine returns the normalized selection.'**
  String get modelPickedBody;

  /// No description provided for @modelUseThis.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get modelUseThis;

  /// No description provided for @modelEffortChip.
  ///
  /// In en, this message translates to:
  /// **'{model} · {effort}'**
  String modelEffortChip(Object effort, Object model);

  /// No description provided for @modelEffortDefault.
  ///
  /// In en, this message translates to:
  /// **'default'**
  String get modelEffortDefault;

  /// No description provided for @modelCatalogFailures.
  ///
  /// In en, this message translates to:
  /// **'These providers could not be loaded (the rest are unaffected)'**
  String get modelCatalogFailures;

  /// No description provided for @modelSheetFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the model catalog'**
  String get modelSheetFailed;

  /// No description provided for @contextTitle.
  ///
  /// In en, this message translates to:
  /// **'Context & statistics'**
  String get contextTitle;

  /// No description provided for @contextNotReported.
  ///
  /// In en, this message translates to:
  /// **'The engine has not reported usage yet — shown as unknown, not 0%.'**
  String get contextNotReported;

  /// No description provided for @contextProjected.
  ///
  /// In en, this message translates to:
  /// **'Projected'**
  String get contextProjected;

  /// No description provided for @contextPressure.
  ///
  /// In en, this message translates to:
  /// **'Current pressure'**
  String get contextPressure;

  /// No description provided for @contextWindow.
  ///
  /// In en, this message translates to:
  /// **'Context window'**
  String get contextWindow;

  /// No description provided for @contextBreakdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Composition'**
  String get contextBreakdownTitle;

  /// No description provided for @contextBreakdownCaveat.
  ///
  /// In en, this message translates to:
  /// **'(fixed-density estimates; do not reconcile with the total above)'**
  String get contextBreakdownCaveat;

  /// No description provided for @contextSegmentSystem.
  ///
  /// In en, this message translates to:
  /// **'System prompt'**
  String get contextSegmentSystem;

  /// No description provided for @contextSegmentTools.
  ///
  /// In en, this message translates to:
  /// **'Tool definitions'**
  String get contextSegmentTools;

  /// No description provided for @contextSegmentMessages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get contextSegmentMessages;

  /// No description provided for @contextUsageTitle.
  ///
  /// In en, this message translates to:
  /// **'Usage & statistics'**
  String get contextUsageTitle;

  /// No description provided for @contextUsageUncached.
  ///
  /// In en, this message translates to:
  /// **'Uncached input'**
  String get contextUsageUncached;

  /// No description provided for @contextUsageCacheRead.
  ///
  /// In en, this message translates to:
  /// **'Cache read'**
  String get contextUsageCacheRead;

  /// No description provided for @contextUsageCacheWrite.
  ///
  /// In en, this message translates to:
  /// **'Cache write'**
  String get contextUsageCacheWrite;

  /// No description provided for @contextUsageOutput.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get contextUsageOutput;

  /// No description provided for @contextTurns.
  ///
  /// In en, this message translates to:
  /// **'Turns'**
  String get contextTurns;

  /// No description provided for @teamTitle.
  ///
  /// In en, this message translates to:
  /// **'Subagent team'**
  String get teamTitle;

  /// No description provided for @teamCount.
  ///
  /// In en, this message translates to:
  /// **'{count} subagents'**
  String teamCount(Object count);

  /// No description provided for @teamEmpty.
  ///
  /// In en, this message translates to:
  /// **'This session has no subagents yet'**
  String get teamEmpty;

  /// No description provided for @teamCatalogUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This session exposes no subagent catalog'**
  String get teamCatalogUnavailable;

  /// No description provided for @teamReadOnly.
  ///
  /// In en, this message translates to:
  /// **'read-only'**
  String get teamReadOnly;

  /// No description provided for @teamModeTerminal.
  ///
  /// In en, this message translates to:
  /// **'terminal · cannot be given more work'**
  String get teamModeTerminal;

  /// No description provided for @teamModeContinuable.
  ///
  /// In en, this message translates to:
  /// **'can be continued'**
  String get teamModeContinuable;

  /// No description provided for @teamFooter.
  ///
  /// In en, this message translates to:
  /// **'Tap a subagent for its read-only output; lineage tags in the chat point back here'**
  String get teamFooter;

  /// No description provided for @teamBadgeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Subagent team'**
  String get teamBadgeTooltip;

  /// No description provided for @jobsEmpty.
  ///
  /// In en, this message translates to:
  /// **'This session has no jobs'**
  String get jobsEmpty;

  /// No description provided for @jobsStateRunning.
  ///
  /// In en, this message translates to:
  /// **'running'**
  String get jobsStateRunning;

  /// No description provided for @jobsStateDone.
  ///
  /// In en, this message translates to:
  /// **'finished'**
  String get jobsStateDone;

  /// No description provided for @jobsStateFailed.
  ///
  /// In en, this message translates to:
  /// **'failed'**
  String get jobsStateFailed;

  /// No description provided for @jobsStatePending.
  ///
  /// In en, this message translates to:
  /// **'pending'**
  String get jobsStatePending;

  /// No description provided for @jobsKill.
  ///
  /// In en, this message translates to:
  /// **'Kill'**
  String get jobsKill;

  /// No description provided for @jobsKillRequested.
  ///
  /// In en, this message translates to:
  /// **'Kill requested'**
  String get jobsKillRequested;

  /// No description provided for @jobsAlreadyFinished.
  ///
  /// In en, this message translates to:
  /// **'That job had already finished'**
  String get jobsAlreadyFinished;

  /// No description provided for @hostSessions.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get hostSessions;

  /// No description provided for @hostModel.
  ///
  /// In en, this message translates to:
  /// **'Current model'**
  String get hostModel;

  /// No description provided for @hostPlugins.
  ///
  /// In en, this message translates to:
  /// **'Mounted plugins'**
  String get hostPlugins;

  /// No description provided for @hostPluginDisabled.
  ///
  /// In en, this message translates to:
  /// **'disabled'**
  String get hostPluginDisabled;

  /// No description provided for @hostPluginsNote.
  ///
  /// In en, this message translates to:
  /// **'From the engine\'s pluginManager/listBundles — switches flip a whole bundle (applied on engine restart)'**
  String get hostPluginsNote;

  /// No description provided for @hostBundleModules.
  ///
  /// In en, this message translates to:
  /// **'modules'**
  String get hostBundleModules;

  /// No description provided for @hostPluginCoreLocked.
  ///
  /// In en, this message translates to:
  /// **'Core module'**
  String get hostPluginCoreLocked;

  /// No description provided for @hostPluginUnaddressable.
  ///
  /// In en, this message translates to:
  /// **'Unaddressable'**
  String get hostPluginUnaddressable;

  /// No description provided for @hostPluginRestartRequired.
  ///
  /// In en, this message translates to:
  /// **'Recorded — applies after an engine restart'**
  String get hostPluginRestartRequired;

  /// No description provided for @hostMetricsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This engine version exposes no host metrics (no events.host or equivalent route), so no figures are guessed.'**
  String get hostMetricsUnavailable;

  /// No description provided for @trajectoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'This session has no trace records yet'**
  String get trajectoryEmpty;

  /// No description provided for @trajectoryNoSession.
  ///
  /// In en, this message translates to:
  /// **'Open a session first — there is nothing to trace otherwise'**
  String get trajectoryNoSession;

  /// No description provided for @trajectoryTruncated.
  ///
  /// In en, this message translates to:
  /// **'The window keeps the {kept} most recent records ({dropped} older ones dropped; scroll up to load them back)'**
  String trajectoryTruncated(Object dropped, Object kept);

  /// No description provided for @trajectoryLoadEarlier.
  ///
  /// In en, this message translates to:
  /// **'Load earlier records'**
  String get trajectoryLoadEarlier;

  /// No description provided for @trajectoryLoadingEarlier.
  ///
  /// In en, this message translates to:
  /// **'Loading earlier records…'**
  String get trajectoryLoadingEarlier;

  /// No description provided for @trajectoryEarlierFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load earlier records: {reason}'**
  String trajectoryEarlierFailed(Object reason);

  /// No description provided for @trajectoryBetweenTurns.
  ///
  /// In en, this message translates to:
  /// **'Between turns'**
  String get trajectoryBetweenTurns;

  /// No description provided for @trajectoryTurn.
  ///
  /// In en, this message translates to:
  /// **'Turn {turn}'**
  String trajectoryTurn(Object turn);

  /// No description provided for @trajectoryRequest.
  ///
  /// In en, this message translates to:
  /// **'Request #{request}'**
  String trajectoryRequest(Object request);

  /// No description provided for @trajectoryLaneSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get trajectoryLaneSystem;

  /// No description provided for @trajectoryLaneMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get trajectoryLaneMessage;

  /// No description provided for @trajectoryLaneTool.
  ///
  /// In en, this message translates to:
  /// **'Tool'**
  String get trajectoryLaneTool;

  /// No description provided for @trajectoryNoTiming.
  ///
  /// In en, this message translates to:
  /// **'This record has no drawable duration (the engine recorded no start)'**
  String get trajectoryNoTiming;

  /// No description provided for @trajectoryInspector.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get trajectoryInspector;

  /// No description provided for @trajectoryTabPayload.
  ///
  /// In en, this message translates to:
  /// **'Payload'**
  String get trajectoryTabPayload;

  /// No description provided for @trajectoryTabTiming.
  ///
  /// In en, this message translates to:
  /// **'Timing'**
  String get trajectoryTabTiming;

  /// No description provided for @trajectoryTabUsage.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get trajectoryTabUsage;

  /// No description provided for @trajectoryRangeActive.
  ///
  /// In en, this message translates to:
  /// **'Filtered {from}–{to}'**
  String trajectoryRangeActive(Object from, Object to);

  /// No description provided for @trajectoryRangeClear.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get trajectoryRangeClear;

  /// No description provided for @trajectoryToolError.
  ///
  /// In en, this message translates to:
  /// **'error'**
  String get trajectoryToolError;

  /// No description provided for @trajectoryToolReturn.
  ///
  /// In en, this message translates to:
  /// **'returned'**
  String get trajectoryToolReturn;

  /// No description provided for @trajectoryHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a record for its raw payload · drag on the timeline to filter by interval'**
  String get trajectoryHint;

  /// No description provided for @trajectoryTtft.
  ///
  /// In en, this message translates to:
  /// **'TTFT'**
  String get trajectoryTtft;

  /// No description provided for @trajectoryDecode.
  ///
  /// In en, this message translates to:
  /// **'Decode'**
  String get trajectoryDecode;

  /// No description provided for @trajectoryTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get trajectoryTotal;

  /// No description provided for @trajectoryStarted.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get trajectoryStarted;

  /// No description provided for @trajectoryEnded.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get trajectoryEnded;

  /// No description provided for @trajectoryEmptyRange.
  ///
  /// In en, this message translates to:
  /// **'No records in the selected interval'**
  String get trajectoryEmptyRange;

  /// No description provided for @workspacesFilter.
  ///
  /// In en, this message translates to:
  /// **'Archive view'**
  String get workspacesFilter;

  /// No description provided for @workspacesFilterHide.
  ///
  /// In en, this message translates to:
  /// **'Hide archived'**
  String get workspacesFilterHide;

  /// No description provided for @workspacesFilterShow.
  ///
  /// In en, this message translates to:
  /// **'Show archived'**
  String get workspacesFilterShow;

  /// No description provided for @workspacesFilterOnly.
  ///
  /// In en, this message translates to:
  /// **'Archived only'**
  String get workspacesFilterOnly;

  /// No description provided for @workspacesArchivedBadge.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get workspacesArchivedBadge;

  /// No description provided for @workspacesArchivedHint.
  ///
  /// In en, this message translates to:
  /// **'An archived session runs nothing — tap Unarchive to bring it back'**
  String get workspacesArchivedHint;

  /// No description provided for @workspacesArchivedNone.
  ///
  /// In en, this message translates to:
  /// **'No archived sessions'**
  String get workspacesArchivedNone;

  /// No description provided for @workspacesUnarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get workspacesUnarchive;

  /// No description provided for @workspacesDeadBadge.
  ///
  /// In en, this message translates to:
  /// **'Gone'**
  String get workspacesDeadBadge;

  /// No description provided for @workspacesDeadHint.
  ///
  /// In en, this message translates to:
  /// **'The engine no longer has this session — usually a host-side job that wrote its log straight to disk, or a registry leftover after cleanup. Archive to clear it from the list.'**
  String get workspacesDeadHint;

  /// No description provided for @chatFoldExpand.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count} chars)'**
  String chatFoldExpand(int count);

  /// No description provided for @chatFoldCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get chatFoldCollapse;

  /// No description provided for @chatMetaSystemReminder.
  ///
  /// In en, this message translates to:
  /// **'System reminder'**
  String get chatMetaSystemReminder;

  /// No description provided for @chatMetaRuntimeContext.
  ///
  /// In en, this message translates to:
  /// **'Runtime context'**
  String get chatMetaRuntimeContext;

  /// No description provided for @chatMetaInjected.
  ///
  /// In en, this message translates to:
  /// **'System message'**
  String get chatMetaInjected;

  /// No description provided for @chatMetaChip.
  ///
  /// In en, this message translates to:
  /// **'{label} · {count} chars'**
  String chatMetaChip(String label, int count);

  /// No description provided for @chatThinkingActive.
  ///
  /// In en, this message translates to:
  /// **'💭 Thinking…'**
  String get chatThinkingActive;

  /// No description provided for @chatThinkingActiveCount.
  ///
  /// In en, this message translates to:
  /// **'💭 Thinking · {count} chars'**
  String chatThinkingActiveCount(int count);

  /// No description provided for @chatThinkingActiveExpanded.
  ///
  /// In en, this message translates to:
  /// **'💭 Thinking · {count} chars (tap to collapse)'**
  String chatThinkingActiveExpanded(int count);

  /// No description provided for @chatThoughtCollapsed.
  ///
  /// In en, this message translates to:
  /// **'💭 Thought · {count} chars (tap to expand)'**
  String chatThoughtCollapsed(int count);

  /// No description provided for @chatThoughtExpanded.
  ///
  /// In en, this message translates to:
  /// **'💭 Thought · {count} chars (tap to collapse)'**
  String chatThoughtExpanded(int count);

  /// No description provided for @chatToolCallLabel.
  ///
  /// In en, this message translates to:
  /// **'Tool call'**
  String get chatToolCallLabel;

  /// No description provided for @chatToolArgs.
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get chatToolArgs;

  /// No description provided for @chatToolResult.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get chatToolResult;

  /// No description provided for @presetsSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick an agent preset'**
  String get presetsSheetTitle;

  /// No description provided for @presetsQuickCreate.
  ///
  /// In en, this message translates to:
  /// **'New session (default preset)'**
  String get presetsQuickCreate;

  /// No description provided for @presetsDefaultChip.
  ///
  /// In en, this message translates to:
  /// **'default'**
  String get presetsDefaultChip;

  /// No description provided for @presetsBrokenChip.
  ///
  /// In en, this message translates to:
  /// **'broken config'**
  String get presetsBrokenChip;

  /// No description provided for @presetsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load presets. Use “New session” for the default preset.'**
  String get presetsLoadFailed;

  /// No description provided for @workspacesUnarchiveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not unarchive'**
  String get workspacesUnarchiveFailed;

  /// No description provided for @workspacesArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get workspacesArchive;

  /// No description provided for @workspacesArchiveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not archive'**
  String get workspacesArchiveFailed;

  /// No description provided for @workspacesPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get workspacesPin;

  /// No description provided for @workspacesUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get workspacesUnpin;

  /// No description provided for @workspacesPinFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not pin'**
  String get workspacesPinFailed;

  /// No description provided for @workspacesArchiveBusyTitle.
  ///
  /// In en, this message translates to:
  /// **'This session is still running'**
  String get workspacesArchiveBusyTitle;

  /// No description provided for @workspacesArchiveBusyBody.
  ///
  /// In en, this message translates to:
  /// **'Archiving means stopping it first:'**
  String get workspacesArchiveBusyBody;

  /// No description provided for @workspacesArchiveBusyStopAndArchive.
  ///
  /// In en, this message translates to:
  /// **'Stop and archive'**
  String get workspacesArchiveBusyStopAndArchive;

  /// No description provided for @workspacesArchiveBusyCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get workspacesArchiveBusyCancel;

  /// No description provided for @workspacesArchiveActivityTurn.
  ///
  /// In en, this message translates to:
  /// **'an in-progress turn'**
  String get workspacesArchiveActivityTurn;

  /// No description provided for @workspacesArchiveActivityJob.
  ///
  /// In en, this message translates to:
  /// **'background jobs'**
  String get workspacesArchiveActivityJob;

  /// No description provided for @workspacesArchiveActivitySubagent.
  ///
  /// In en, this message translates to:
  /// **'subagents'**
  String get workspacesArchiveActivitySubagent;

  /// No description provided for @workspacesArchiveActivitySchedule.
  ///
  /// In en, this message translates to:
  /// **'schedules'**
  String get workspacesArchiveActivitySchedule;

  /// No description provided for @workspacesArchiveActivityOther.
  ///
  /// In en, this message translates to:
  /// **'other ({kind})'**
  String workspacesArchiveActivityOther(Object kind);

  /// No description provided for @workspacesArchiveActivityJoin.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get workspacesArchiveActivityJoin;

  /// No description provided for @workspacesArchiveActivityWith.
  ///
  /// In en, this message translates to:
  /// **'{label}: {names}'**
  String workspacesArchiveActivityWith(Object label, Object names);

  /// No description provided for @workspacesArchiveDone.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get workspacesArchiveDone;

  /// No description provided for @workspacesSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing workspace membership…'**
  String get workspacesSyncing;

  /// No description provided for @settingsDiagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics log'**
  String get settingsDiagnosticsTitle;

  /// No description provided for @settingsDiagnosticsSub.
  ///
  /// In en, this message translates to:
  /// **'Sanitized local log — stays on this device'**
  String get settingsDiagnosticsSub;

  /// No description provided for @diagnosticsMeta.
  ///
  /// In en, this message translates to:
  /// **'{size} · {lines} lines'**
  String diagnosticsMeta(String size, String lines);

  /// No description provided for @diagnosticsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No log entries yet.'**
  String get diagnosticsEmpty;

  /// No description provided for @diagnosticsCopied.
  ///
  /// In en, this message translates to:
  /// **'Log copied'**
  String get diagnosticsCopied;

  /// No description provided for @diagnosticsShare.
  ///
  /// In en, this message translates to:
  /// **'Share log'**
  String get diagnosticsShare;

  /// No description provided for @diagnosticsCopyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy all'**
  String get diagnosticsCopyAll;

  /// No description provided for @diagnosticsClear.
  ///
  /// In en, this message translates to:
  /// **'Clear log'**
  String get diagnosticsClear;

  /// No description provided for @diagnosticsCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get diagnosticsCancel;

  /// No description provided for @diagnosticsClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear the log?'**
  String get diagnosticsClearTitle;

  /// No description provided for @diagnosticsClearBody.
  ///
  /// In en, this message translates to:
  /// **'Log files on this device will be deleted.'**
  String get diagnosticsClearBody;

  /// No description provided for @diagnosticsCleared.
  ///
  /// In en, this message translates to:
  /// **'Log cleared'**
  String get diagnosticsCleared;

  /// No description provided for @diagnosticsShareSubject.
  ///
  /// In en, this message translates to:
  /// **'dsh remote diagnostics log'**
  String get diagnosticsShareSubject;
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
  const _L10nDelegate();

  @override
  Future<L10n> load(Locale locale) {
    return SynchronousFuture<L10n>(lookupL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_L10nDelegate old) => false;
}

L10n lookupL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return L10nEn();
    case 'zh':
      return L10nZh();
  }

  throw FlutterError(
    'L10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
