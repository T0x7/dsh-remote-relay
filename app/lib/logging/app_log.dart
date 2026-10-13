/// App-side logging facade (logging plan P1; design §7.2「全部错误入本地脱敏
/// 日志」+ §8「对 token/psk 脱敏」+ 隐私表「App 私有存储，容量上限滚动覆盖，
/// 随卸载；不随备份出设备」).
///
/// Shape:
/// - [AppLog] — static facade (`AppLog.d/i/w/e/audit/crash`), the only API call
///   sites use.
/// - [LogSink] — where lines land. [FileLogSink] (rolling, redacted, three
///   channels) in the real app; [MemoryLogSink] in tests.
/// - [Redactor] — single chokepoint: applied to every line right before it
///   hits a sink, so call sites stay free to log rich context and never have
///   to remember to scrub. Mirrors `server/src/logger.ts` (same censor token,
///   same field list plus URL queries / JWTs).
///
/// ## 三个通道，三个文件（2026-10-13）
///
/// 原来所有级别挤在一个 `app.log` 里，共用 256KB×2 代的配额。后果是实测过的：
/// journal 的**逐帧**探针（`FollowAssistantStream`，引擎流式输出时 130–250 行/
/// 秒）能在**一次连续输出 30–60 秒内**把两代缓冲全部冲干净，于是
/// `W/[chat] first-frame deadline hit` 这类真正的现场证据被噪声挤掉——用户打开
/// 诊断页只看到一屏 `frame FollowAssistantStream`。
///
/// 所以拆通道，各自配额、各自滚动：
/// - [LogChannel.app] — 诊断日志（`app.log`），debug 探针在这里，release 不落。
/// - [LogChannel.crash] — 崩溃/未捕获异常（`crash.log`）。**release 也落**：
///   崩溃取证是这条通道存在的唯一理由，而崩溃恰恰最需要跨构建保留。
/// - [LogChannel.audit] — 操作日志（`audit.log`）。**release 也落**：回溯
///   「当时人在干什么」在 release 里才有意义，debug 包的行为不代表线上。
///
/// 通道隔离本身就是防噪声的设计：debug 探针再吵也碰不到 crash 记录。
///
/// ## 批量写
///
/// 逐行 `writeFromSync` 是刻意选的（`IOSink.flush()` 会关掉内部 controller，
/// 两行竞争就抛 "StreamSink is bound/closed"），但逐行同步写盘在流式输出时
/// 等于每帧一次同步 I/O。所以缓冲成批：满 [batchBytes] 或超过 [batchInterval]
/// 落一次盘，峰值 200 行/秒从每秒 200 次同步写降到每秒约 3 次。
///
/// Debug vs release: debug 构建把每行镜像到 `debugPrint`（保住 `adb logcat`
/// 习惯，包括 `[e2e]` 探针）；落文件时 debug 行只在 debug 构建写——噪声不进
/// 任何构建的文件。crash / audit 两个通道不看 kDebugMode。
///
/// The sink is bootstrapped in `main()` and never awaited: lines written
/// before the directory resolves buffer in memory and drain once it opens,
/// so the first frame never waits on the filesystem and the first logs are
/// not lost either.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Severity. Plain enum here; the core seam speaks strings and [AppLog.raw]
/// translates. [LogLevel.audit] 不是 core 侧会送来的级别——它只由 [AppLog.audit]
/// 产生，用来在行首把操作日志一眼认出来（`A/[audit]`）。
enum LogLevel { debug, info, warn, error, audit }

extension on LogLevel {
  String get letter => switch (this) {
        LogLevel.debug => 'D',
        LogLevel.info => 'I',
        LogLevel.warn => 'W',
        LogLevel.error => 'E',
        LogLevel.audit => 'A',
      };
}

/// 落哪个文件。拆分理由见文件头。
enum LogChannel { app, crash, audit }

extension on LogChannel {
  /// 默认文件名后缀（`app` → `app.log`）。
  String get fileStem => switch (this) {
        LogChannel.app => 'app',
        LogChannel.crash => 'crash',
        LogChannel.audit => 'audit',
      };
}

/// One log line before formatting. [tag] is a short stable scope id
/// (`relay`, `tofu`, `chat`, `lock` …), not free-form prose.
class LogLine {
  const LogLine({
    required this.ts,
    required this.level,
    required this.tag,
    required this.message,
    this.channel = LogChannel.app,
  });

  final DateTime ts;
  final LogLevel level;
  final String tag;
  final String message;

  /// 默认 [LogChannel.app]，是为了不改动已有调用点（core 的 [AppLog.raw] 缝
  /// 和测试里的构造都只给四个字段）。
  final LogChannel channel;

  /// `2026-10-07T02:30:00.123 W/[tofu] PIN MISMATCH host=…`
  String formatted() =>
      '${ts.toIso8601String()} ${level.letter}/[$tag] $message';
}

/// Where lines land. Throwing implementations are a bug — [FileLogSink] and
/// [MemoryLogSink] both swallow their own I/O failures.
abstract interface class LogSink {
  void write(LogLine line);

  /// Best-effort: resolves once everything written so far has landed. The
  /// diagnostics page awaits this before copy/share/read so the last lines
  /// are included; tests use it to reach a settled state deterministically.
  Future<void> flush();

  /// 当前 + 滚动出的内容，按通道 app → crash → audit。给「复制全部 / 分享」
  /// 用——收件人该看到完整现场，而不是某个被选中的通道。
  Future<String> readAll();

  /// 单个通道的当前 + 滚动内容，最旧一代在前。诊断页分通道查看用。
  Future<String> readChannel(LogChannel channel);

  /// Total bytes on disk across current + rotated files of **all** channels
  /// (memory sink: buffered bytes).
  Future<int> sizeBytes();

  /// 单个通道占用的字节（当前代 + 滚动代）。诊断页按通道查看时用它算元信息
  /// ——否则筛到崩溃通道还显示三个文件加起来的大小，是在说假话。
  Future<int> sizeOf(LogChannel channel);

  /// Existing log files, oldest first — what 「分享」 attaches. Empty when
  /// nothing has been written yet. Ordered app → crash → audit.
  Future<List<File>> files();

  /// Delete every log file / buffer. Used by the diagnostics page.
  Future<void> clear();
}

/// The app-wide facade. Call sites: `AppLog.i('chat', '…')`.
///
/// `sink` is null until [init] runs — tests and any code before `main()`
/// get debugPrint-only behavior, which is exactly right.
abstract final class AppLog {
  /// Installed once by `main()`. Null = mirror-only (tests).
  static LogSink? sink;

  static void d(String tag, String message) =>
      _log(LogLevel.debug, tag, message);
  static void i(String tag, String message) =>
      _log(LogLevel.info, tag, message);
  static void w(String tag, String message) =>
      _log(LogLevel.warn, tag, message);
  static void e(String tag, String message) =>
      _log(LogLevel.error, tag, message);

  /// Adapter for `CoreLog.sink` — levels arrive as wire strings.
  static void raw(String level, String tag, String message) {
    final parsed = switch (level) {
      'debug' => LogLevel.debug,
      'warn' => LogLevel.warn,
      'error' => LogLevel.error,
      _ => LogLevel.info,
    };
    _log(parsed, tag, message);
  }

  /// 操作日志（关键动作与状态迁移）。落 `audit.log`，**release 也落**。
  ///
  /// 只记「人做了什么 + App 处在哪个状态」，不记输入内容、不记界面细节：
  /// 形如 `action=chat.prompt.send session=abc12312 chars=42`。attrs 一律走
  /// [Redactor] 的 key=value 规则，所以别在这里塞需要脱敏的值——塞了也会被
  /// 脱，但那时已经晚了（设计上调用点只该放标识符与计数）。
  static void audit(String action, {Map<String, Object?> attrs = const {}}) {
    final buffer = StringBuffer('action=$action');
    attrs.forEach((key, value) {
      if (value != null) buffer.write(' $key=$value');
    });
    final message = buffer.toString();
    if (kDebugMode) debugPrint('A/[audit] $message');
    _emit(LogLevel.audit, 'audit', message, LogChannel.audit);
  }

  /// 崩溃/未捕获异常。落 `crash.log`，**release 也落**，且**永不丢弃**——
  /// 这是「App 崩了能查」的唯一入口，丢一条就等于这条崩溃没发生过。
  ///
  /// [stack] 附在 message 后面（原样换行），诊断页按 `\n` 拆行时栈帧就是
  /// 独立行，这是刻意的手感，不用给每帧补时间戳前缀。
  static void crash(String tag, Object error,
      [StackTrace? stack, String? context]) {
    final head = StringBuffer('$error');
    if (context != null && context.isNotEmpty) head.write(' context=$context');
    final message = stack == null ? head.toString() : '${head.toString()}\n$stack';
    if (kDebugMode) debugPrint('E/[$tag] $message');
    _emit(LogLevel.error, tag, message, LogChannel.crash);
  }

  /// Idempotent; the app shell calls it in `main()`. Never await it — the
  /// sink buffers until its directory resolves.
  static void init({required Future<Directory> Function() resolveDir}) {
    sink ??= FileLogSink(resolveDir: resolveDir);
  }

  static void _log(LogLevel level, String tag, String message) {
    // Mirror to the console in debug builds — the `[e2e]` probe workflow and
    // every `adb logcat` habit keep working unchanged.
    if (kDebugMode) debugPrint('${level.letter}/[$tag] $message');
    // Release: debug 行是探针噪声，不进任何构建的文件。
    if (!kDebugMode && level == LogLevel.debug) return;
    _emit(level, tag, message, LogChannel.app);
  }

  static void _emit(
      LogLevel level, String tag, String message, LogChannel channel) {
    try {
      sink?.write(LogLine(
          ts: DateTime.now(),
          level: level,
          tag: tag,
          message: message,
          channel: channel));
    } catch (_) {
      // Logging must never break the caller, ever.
    }
  }
}

/// Secret scrubber — the single chokepoint before any sink.
///
/// Field list mirrors `server/src/logger.ts` redact paths (`psk`,
/// `pairingToken`, `sessionSecret`, `cookie`, `authorization`) plus the two
/// shapes the App actually handles: Bearer headers and signed pairing URLs.
/// Order matters: JWT first (a bare token), then Bearer, then key=value.
abstract final class Redactor {
  static const censor = '[REDACTED]';

  /// `Authorization: Bearer <token>` header shape — must run BEFORE the kv
  /// rule, which would otherwise eat `Bearer` as `authorization`'s value and
  /// leave the real token standing.
  static final RegExp _headerBearer =
      RegExp(r'\bauthorization\s*:\s*bearer\s+\S+', caseSensitive: false);

  /// `eyJ….….…` three-segment JWT-ish token (8+ chars per segment).
  static final RegExp _jwt =
      RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}');

  /// `Bearer <token>` headers.
  static final RegExp _bearer =
      RegExp(r'\bbearer\s+\S+', caseSensitive: false);

  /// Sensitive key=value / key: "value" shapes, JSON-ish and plain. Deliberately
  /// NOT in the list: `sessionId` and host names — server discipline says those
  /// identifiers are exactly what logs are for. The lookahead stops the rule
  /// from eating its own censor output (an earlier rule's `[REDACTED]` must
  /// survive as a value).
  static final RegExp _secretKv = RegExp(
    r'\b(psk|pairingToken|pairing_token|sessionSecret|session_secret|token|'
    r'secret|password|authorization|cookie)\b["]?'
    r'\s*[:=]\s*["]?(?!\[REDACTED\])[^"\s,;&}]{4,}["]?',
    caseSensitive: false,
  );

  /// http(s) URLs — queries carry signed pairing tokens (?t=…) so the whole
  /// query is stripped, scheme+host+path kept for diagnosis.
  static final RegExp _url = RegExp(r'https?://[^\s]+');

  static String apply(String input) {
    var s = input;
    s = s.replaceAllMapped(_headerBearer, (_) => 'Authorization: $censor');
    s = s.replaceAllMapped(_jwt, (_) => censor);
    s = s.replaceAllMapped(_bearer, (_) => 'Bearer $censor');
    s = s.replaceAllMapped(_secretKv, (m) => '${m.group(1)}=$censor');
    s = s.replaceAllMapped(_url, (m) => _stripQuery(m.group(0)!));
    return s;
  }

  static String _stripQuery(String url) {
    var end = url.length;
    final q = url.indexOf('?');
    final f = url.indexOf('#');
    if (q >= 0) end = q;
    if (f >= 0 && f < end) end = f;
    return url.substring(0, end);
  }
}

/// 多通道滚动文件 sink。内部每通道一个 [_RollingFile]，各自配额、各自滚动：
///
/// | 通道 | 文件 | 默认配额 | release |
/// |---|---|---|---|
/// | app | `app.log` | 256KB | debug 行不落 |
/// | crash | `crash.log` | 64KB | 落 |
/// | audit | `audit.log` | 128KB | 落 |
///
/// 每通道保留「当前代 + 一代滚动」= 实际容量是配额的两倍。崩溃记录最怕丢，
/// 所以它的配额最小但**独立**：debug 探针再吵也挤不到它。
///
/// 目录解析异步（移动端 path_provider）；解析前到达的行进内存缓冲（封顶
/// [_RollingFile._pendingCap]）并在打开后排空。每行都在 [_RollingFile] 里过
/// [Redactor.apply]——sink 是脱敏的最后一道防线，调用点是第一道。
class FileLogSink implements LogSink {
  FileLogSink({
    required this.resolveDir,
    this.maxBytes = 256 * 1024,
    this.crashMaxBytes = 64 * 1024,
    this.auditMaxBytes = 128 * 1024,
    this.fileName = 'app.log',
    this.batchBytes = 4 * 1024,
    this.batchInterval = const Duration(milliseconds: 250),
  });

  /// Directory seam: the app injects path_provider's cache dir; tests inject
  /// a system-temp directory.
  final Future<Directory> Function() resolveDir;
  final int maxBytes;
  final int crashMaxBytes;
  final int auditMaxBytes;
  final String fileName;
  final int batchBytes;
  final Duration batchInterval;

  /// app 通道沿用可配的 [fileName]（历史文件名的连续性），另两个按通道名定。
  late final Map<LogChannel, _RollingFile> _channels = {
    LogChannel.app: _RollingFile(
      resolveDir: resolveDir,
      fileName: fileName,
      maxBytes: maxBytes,
      batchBytes: batchBytes,
      batchInterval: batchInterval,
    ),
    LogChannel.crash: _RollingFile(
      resolveDir: resolveDir,
      fileName: '${LogChannel.crash.fileStem}.log',
      maxBytes: crashMaxBytes,
      batchBytes: batchBytes,
      batchInterval: batchInterval,
    ),
    LogChannel.audit: _RollingFile(
      resolveDir: resolveDir,
      fileName: '${LogChannel.audit.fileStem}.log',
      maxBytes: auditMaxBytes,
      batchBytes: batchBytes,
      batchInterval: batchInterval,
    ),
  };

  /// 稳定的通道顺序：读、分享、大小统计都按它走。
  static const channelOrder = [
    LogChannel.app,
    LogChannel.crash,
    LogChannel.audit,
  ];

  @override
  void write(LogLine line) {
    _channels[line.channel]?.write(line);
  }

  @override
  Future<void> flush() async {
    for (final channel in channelOrder) {
      await _channels[channel]!.flush();
    }
  }

  @override
  Future<String> readAll() async {
    await flush();
    final parts = <String>[];
    for (final channel in channelOrder) {
      final content = await _channels[channel]!.read();
      if (content.isNotEmpty) parts.add(content);
    }
    return parts.join();
  }

  @override
  Future<String> readChannel(LogChannel channel) async {
    await _channels[channel]!.flush();
    return _channels[channel]!.read();
  }

  @override
  Future<int> sizeBytes() async {
    var total = 0;
    for (final channel in channelOrder) {
      total += await _channels[channel]!.sizeBytes();
    }
    return total;
  }

  @override
  Future<int> sizeOf(LogChannel channel) async => _channels[channel]!.sizeBytes();

  @override
  Future<List<File>> files() async {
    final out = <File>[];
    for (final channel in channelOrder) {
      out.addAll(await _channels[channel]!.files());
    }
    return out;
  }

  @override
  Future<void> clear() async {
    for (final channel in channelOrder) {
      await _channels[channel]!.clear();
    }
  }
}

/// 单通道的滚动文件 + 批量缓冲。
///
/// 逐行 `writeFromSync` 而不是 `IOSink` 的 `openWrite`：这个 SDK 的
/// `IOSink.flush()` 实现会关掉内部 stream controller（`_isBound = true;
/// controller.close()`），write-then-flush-per-line 在两行竞争时就抛
/// "StreamSink is bound/closed"，sink 会静默死掉。`writeFromSync` 没有
/// controller 生命周期可踩，而且它也是更好的崩溃证据：`write()` 返回时字节
/// 已经落盘。
///
/// 代价是逐行一次同步 I/O——流式输出时每帧一次。所以加一层批缓冲：攒够
/// [batchBytes] 或过了 [batchInterval] 才落盘。批与批之间仍然逐字节顺序
/// 写，滚动永远不吞最新内容。
class _RollingFile {
  _RollingFile({
    required this.resolveDir,
    required this.fileName,
    required this.maxBytes,
    required this.batchBytes,
    required this.batchInterval,
  });

  static const _pendingCap = 500;

  final Future<Directory> Function() resolveDir;
  final String fileName;
  final int maxBytes;
  final int batchBytes;
  final Duration batchInterval;

  final List<LogLine> _pending = [];
  // 缓冲的是 LogLine 而不是字节：未打开/滚动中时要把整批**退回** pending，
  // 存了字节就只剩一个没法还原成行的 byte soup。
  final List<LogLine> _buffer = [];
  int _bufferBytes = 0;
  File? _current;
  File? _rotated;

  RandomAccessFile? _raf;
  int _bytes = 0;
  bool _failed = false;
  bool _opening = false;
  bool _rotating = false;
  Timer? _batchTimer;

  void write(LogLine line) {
    if (_failed) return;
    // Rotation check MUST come before the `_raf == null` one: during a
    // rotation the handle is intentionally null, and treating that as
    // "never opened" would start a second `_ensureOpen()` racing the
    // rotation — two handles on two inodes, the loser's lines evaporate
    // with the rename (a deterministic loss the rotation test caught).
    if (_rotating) {
      _pushPending(line);
      return;
    }
    if (_raf == null) {
      _pushPending(line);
      _ensureOpen();
      return;
    }
    _writeNow(line);
  }

  void _pushPending(LogLine line) {
    if (_pending.length >= _pendingCap) _pending.removeAt(0);
    _pending.add(line);
  }

  void _writeNow(LogLine line) {
    _buffer.add(line);
    _bufferBytes += utf8.encode(line.formatted()).length + 1;
    if (_bufferBytes >= batchBytes) {
      _flushBuffer();
    } else {
      _scheduleBatch();
    }
  }

  /// 攒批：一次短 Timer，期间到达的行并进同一批。
  void _scheduleBatch() {
    if (_batchTimer != null || _failed) return;
    _batchTimer = Timer(batchInterval, () {
      _batchTimer = null;
      _flushBuffer();
    });
  }

  /// 把缓冲落盘，**守住 maxBytes 这条容量上限**。
  ///
  /// 滚动判定必须在「按行铺」而不是「整批一次灌」：整批灌的话，一个还没写过
  /// 任何内容的文件会把整批接下去——上限当场失效（这正是 256KB 契约被悄悄
  /// 破坏的形状）。所以一轮只写「塞得下的那段」，塞满了先滚动再续写。
  void _flushBuffer() {
    _batchTimer?.cancel();
    _batchTimer = null;
    while (_buffer.isNotEmpty) {
      if (_failed) return;
      if (_rotating || _raf == null) {
        // 没打开 / 正在滚动：整批退回 pending 队首（保持先后），下一轮排空。
        final queued = _buffer.reversed.toList(growable: false);
        _buffer.clear();
        _bufferBytes = 0;
        _pending.insertAll(0, queued);
        while (_pending.length > _pendingCap) {
          _pending.removeAt(0);
        }
        return;
      }
      if (_bytes >= maxBytes) {
        // 当前代满了 → 先滚动，滚动完成后 _rotate 末尾会自己排空 pending。
        unawaited(_rotate());
        return;
      }
      var fit = 0;
      var fitBytes = 0;
      for (final line in _buffer) {
        final size = utf8.encode(line.formatted()).length + 1;
        // `fit > 0` 是刻意的：空文件至少要接下第一行，哪怕它自己就超配额，
        // 否则那一行永远没地方去。接下之后 `_bytes >= maxBytes` 会触发滚动。
        if (fit > 0 && _bytes + fitBytes + size > maxBytes) break;
        fit++;
        fitBytes += size;
      }
      final chunk = <int>[];
      for (var i = 0; i < fit; i++) {
        final line = _buffer[i];
        // Redactor.apply 在这里——sink 是脱敏的最后一道防线，调用点是第一道。
        chunk.addAll(utf8.encode('${Redactor.apply(line.formatted())}\n'));
      }
      _buffer.removeRange(0, fit);
      _bufferBytes -= fitBytes;
      try {
        _raf!.writeFromSync(chunk);
        _bytes += fitBytes;
      } catch (_) {
        // Disk gone mid-write: stop rather than spam. Console mirror survives.
        _failed = true;
        return;
      }
    }
  }

  void _ensureOpen() {
    if (_opening || _raf != null) return;
    _opening = true;
    unawaited(() async {
      try {
        final dir = await resolveDir();
        await dir.create(recursive: true);
        _current = File('${dir.path}/$fileName');
        _rotated = File('${dir.path}/$fileName.old');
        // First launch: the file doesn't exist yet and `length()` THROWS on a
        // missing path — treating that as failure would permanently silence
        // the sink on every fresh install (a test caught exactly this).
        _bytes = await _current!.exists() ? await _current!.length() : 0;
        _raf = await _current!.open(mode: FileMode.append);
        _drainPending();
      } catch (_) {
        // No filesystem → console mirror only. Never retry-storm.
        _failed = true;
        _pending.clear();
      } finally {
        _opening = false;
      }
    }());
  }

  /// 把 pending 变成缓冲行（不是直接落盘——刚打开时往往一整批）。
  void _drainPending() {
    if (_raf == null || _pending.isEmpty) return;
    final queued = List<LogLine>.of(_pending);
    _pending.clear();
    for (final line in queued) {
      _writeNow(line);
    }
  }

  Future<void> _rotate() async {
    _rotating = true;
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } catch (_) {/* keep rotating even if the old handle is stuck */}
    try {
      await _rotated?.delete();
    } catch (_) {/* first rotation has no predecessor */}
    try {
      await _current!.rename(_rotated!.path);
    } catch (_) {/* unrotatable is fine: keep appending to the same file */}
    _bytes = 0;
    try {
      _raf = await _current!.open(mode: FileMode.append);
    } catch (_) {
      _failed = true;
      _rotating = false;
      return;
    }
    _rotating = false;
    // 滚完之后把没写下的行接上新文件——「滚动永远不吞最新内容」。
    _drainPending();
    _flushBuffer();
  }

  /// Both generations, oldest first — the shared iteration order for
  /// read/size/share/clear. Null-aware elements skip the not-yet-open ones.
  List<File> get _logFiles => [?_rotated, ?_current];

  Future<String> read() async {
    final parts = <String>[];
    for (final file in _logFiles) {
      try {
        parts.add(await file.readAsString());
      } catch (_) {/* unreadable generation skipped */}
    }
    return parts.join();
  }

  Future<void> flush() async {
    // writeFromSync is already durable; flush only waits out an in-flight
    // open/rotate and drains queued lines. Bounded — a stuck filesystem must
    // not hang the diagnostics page forever.
    var guard = 0;
    while (guard++ < 200) {
      if (!_opening && !_rotating && _raf != null) {
        _drainPending();
        _flushBuffer();
      }
      // ⚠️ 别把 `_raf == null` 算进 busy：**从没写过**的通道 `_raf` 永远是
      // null，那意思是「无事可做」而不是「还在忙」。算进去的话，诊断页每开
      // 一个空通道就空转 200×5ms——真机（小米 12:15）实测打开要 7 秒多，
      // 而旧代码是立刻返回的。这条是纯回归。
      final busy = _opening ||
          _rotating ||
          _pending.isNotEmpty ||
          _buffer.isNotEmpty ||
          _batchTimer != null;
      if (!busy) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<int> sizeBytes() async {
    // 缓冲里的字节也算「已写入的体积」——诊断页的容量提示不能因为攒批而
    // 少报正在写的那一批。
    var total = _bufferBytes;
    for (final file in _logFiles) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  Future<List<File>> files() async {
    final out = <File>[];
    for (final file in _logFiles) {
      try {
        if (await file.exists()) out.add(file);
      } catch (_) {}
    }
    return out;
  }

  Future<void> clear() async {
    _batchTimer?.cancel();
    _batchTimer = null;
    _buffer.clear();
    _bufferBytes = 0;
    _pending.clear();
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } catch (_) {}
    for (final file in _logFiles) {
      try {
        await file.delete();
      } catch (_) {}
    }
    _bytes = 0;
    if (_current != null) {
      try {
        _raf = await _current!.open(mode: FileMode.append);
      } catch (_) {/* next write reopens via pending path */}
    }
  }
}

/// In-memory sink — tests and the diagnostics page fallback. Caps at
/// [_RollingFile._pendingCap] lines, oldest dropped, same as the file sink's
/// pre-open buffer. Keeps the [LogLine]s (not the formatted strings) so
/// [readChannel] works exactly like the file sink's.
class MemoryLogSink implements LogSink {
  final List<LogLine> _lines = [];
  bool cleared = false;

  @override
  void write(LogLine line) {
    if (_lines.length >= 500) _lines.removeAt(0);
    _lines.add(line);
  }

  @override
  Future<String> readAll() async {
    final parts = <String>[];
    for (final channel in FileLogSink.channelOrder) {
      final part = _render(channel);
      if (part.isNotEmpty) parts.add(part);
    }
    return parts.join();
  }

  @override
  Future<String> readChannel(LogChannel channel) async => _render(channel);

  String _render(LogChannel channel) {
    final selected =
        _lines.where((line) => line.channel == channel).toList(growable: false);
    if (selected.isEmpty) return '';
    return '${selected.map((line) => Redactor.apply(line.formatted())).join('\n')}\n';
  }

  @override
  Future<void> flush() async {} // writes are synchronous

  @override
  Future<int> sizeBytes() async {
    // A plain loop: fold under an async-arrow context infers T as
    // FutureOr<int> and the analyzer rejects `n + …`.
    var total = 0;
    for (final line in _lines) {
      total += utf8.encode(Redactor.apply(line.formatted())).length;
    }
    return total;
  }

  @override
  Future<int> sizeOf(LogChannel channel) async {
    var total = 0;
    for (final line in _lines) {
      if (line.channel != channel) continue;
      total += utf8.encode(Redactor.apply(line.formatted())).length;
    }
    return total;
  }

  @override
  Future<List<File>> files() async => const [];

  @override
  Future<void> clear() async {
    cleared = true;
    _lines.clear();
  }

  /// Test lens: the buffered lines without re-parsing.
  List<String> get lines =>
      List.unmodifiable(_lines.map((l) => Redactor.apply(l.formatted())));
}