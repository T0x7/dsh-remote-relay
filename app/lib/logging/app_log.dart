/// App-side logging facade (logging plan P1; design §7.2「全部错误入本地脱敏
/// 日志」+ §8「对 token/psk 脱敏」+ 隐私表「App 私有存储，容量上限滚动覆盖，
/// 随卸载；不随备份出设备」).
///
/// Shape:
/// - [AppLog] — static facade (`AppLog.d/i/w/e`), the only API call sites use.
/// - [LogSink] — where lines land. [FileLogSink] (rolling, redacted) in the
///   real app; [MemoryLogSink] in tests.
/// - [Redactor] — single chokepoint: applied to every line right before it
///   hits a sink, so call sites stay free to log rich context and never have
///   to remember to scrub. Mirrors `server/src/logger.ts` (same censor token,
///   same field list plus URL queries / JWTs).
///
/// Debug vs release: debug builds mirror every line to `debugPrint` (keeps
/// the existing logcat workflow, e.g. the `[e2e] frame` probes) AND write the
/// file; release builds write info-and-above to the file only — debug-level
/// chatter is compiled-out noise there, not evidence.
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
/// translates.
enum LogLevel { debug, info, warn, error }

/// One log line before formatting. [tag] is a short stable scope id
/// (`relay`, `tofu`, `chat`, `lock` …), not free-form prose.
class LogLine {
  const LogLine({
    required this.ts,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime ts;
  final LogLevel level;
  final String tag;
  final String message;

  /// `2026-10-07T02:30:00.123 W/[tofu] PIN MISMATCH host=…`
  String formatted() =>
      '${ts.toIso8601String()} ${level.letter}/[$tag] $message';
}

extension on LogLevel {
  String get letter => switch (this) {
        LogLevel.debug => 'D',
        LogLevel.info => 'I',
        LogLevel.warn => 'W',
        LogLevel.error => 'E',
      };
}

/// Where lines land. Throwing implementations are a bug — [FileLogSink] and
/// [MemoryLogSink] both swallow their own I/O failures.
abstract interface class LogSink {
  void write(LogLine line);

  /// Best-effort: resolves once everything written so far has landed. The
  /// diagnostics page awaits this before copy/share/read so the last lines
  /// are included; tests use it to reach a settled state deterministically.
  Future<void> flush();

  /// Current + rotated content, oldest first. Best-effort: on read failure
  /// returns whatever was readable (possibly empty).
  Future<String> readAll();

  /// Total bytes on disk across current + rotated files (memory sink:
  /// buffered bytes).
  Future<int> sizeBytes();

  /// Existing log files, oldest first — what 「分享」 attaches. Empty when
  /// nothing has been written yet.
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

  /// Adapter for [CoreLog.sink] — levels arrive as wire strings.
  static void raw(String level, String tag, String message) {
    final parsed = switch (level) {
      'debug' => LogLevel.debug,
      'warn' => LogLevel.warn,
      'error' => LogLevel.error,
      _ => LogLevel.info,
    };
    _log(parsed, tag, message);
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
    // Release: info+ to file; debug lines are probe noise there.
    if (!kDebugMode && level == LogLevel.debug) return;
    try {
      sink?.write(LogLine(
          ts: DateTime.now(), level: level, tag: tag, message: message));
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

/// Rolling file sink: `<dir>/app.log` plus one generation `<dir>/app.log.old`
/// — total ceiling ≈ 2×[maxBytes], oldest overwritten first (design 隐私表
/// 「容量上限滚动覆盖」).
///
/// The directory resolves asynchronously (path_provider on mobile); lines
/// arriving earlier buffer in memory (capped) and drain on open. Every line
/// passes through [Redactor.apply] right here — sinks are the last line of
/// defense, call sites are the first (identifiers, not secrets).
class FileLogSink implements LogSink {
  FileLogSink({
    required this.resolveDir,
    this.maxBytes = 256 * 1024,
    this.fileName = 'app.log',
  });

  /// Directory seam: the app injects path_provider's cache dir; tests inject
  /// a system-temp directory.
  final Future<Directory> Function() resolveDir;
  final int maxBytes;
  final String fileName;

  static const _pendingCap = 500;

  final List<LogLine> _pending = [];
  File? _current;
  File? _rotated;

  /// RandomAccessFile, NOT `IOSink` from `openWrite`: this SDK's
  /// `IOSink.flush()` implementation closes the internal stream controller
  /// (`_isBound = true; controller.close()`), so the write-then-flush-per-line
  /// pattern throws "StreamSink is bound/closed" the moment two lines race —
  /// the second `add()` lands on a closed controller and the sink dies
  /// silently. `writeFromSync` has no controller lifecycle to trip over, and
  /// it is also better crash evidence: when `write()` returns, bytes are on
  /// disk. Volume here is lines, not megabytes — sync is fine.
  RandomAccessFile? _raf;
  int _bytes = 0;
  bool _failed = false;
  bool _opening = false;
  bool _rotating = false;

  @override
  void write(LogLine line) {
    if (_failed) return;
    // Rotation check MUST come before the `_raf == null` one: during a
    // rotation the handle is intentionally null, and treating that as
    // "never opened" would start a second `_ensureOpen()` racing the
    // rotation — two handles on two inodes, the loser's lines evaporate
    // with the rename (a deterministic loss the rotation test caught).
    if (_rotating) {
      _pending.add(line);
      return;
    }
    if (_raf == null) {
      if (_pending.length >= _pendingCap) _pending.removeAt(0);
      _pending.add(line);
      _ensureOpen();
      return;
    }
    _writeNow(line);
  }

  void _writeNow(LogLine line) {
    final encoded = utf8.encode('${Redactor.apply(line.formatted())}\n');
    if (_bytes + encoded.length > maxBytes && _bytes > 0) {
      _rotate();
      _pending.add(line);
      return;
    }
    try {
      _raf!.writeFromSync(encoded);
      _bytes += encoded.length;
    } catch (_) {
      // Disk gone mid-write: stop rather than spam. Console mirror survives.
      _failed = true;
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
        final queued = List<LogLine>.of(_pending);
        _pending.clear();
        for (final line in queued) {
          write(line);
        }
      } catch (_) {
        // No filesystem → console mirror only. Never retry-storm.
        _failed = true;
        _pending.clear();
      } finally {
        _opening = false;
      }
    }());
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
    _raf = await _current!.open(mode: FileMode.append);
    final queued = List<LogLine>.of(_pending);
    _pending.clear();
    _rotating = false;
    for (final line in queued) {
      write(line);
    }
  }

  /// Both generations, oldest first — the shared iteration order for
  /// read/size/share/clear. Null-aware elements skip the not-yet-open ones.
  List<File> get _logFiles => [?_rotated, ?_current];

  @override
  Future<String> readAll() async {
    await flush();
    final parts = <String>[];
    for (final file in _logFiles) {
      try {
        parts.add(await file.readAsString());
      } catch (_) {/* unreadable generation skipped */}
    }
    return parts.join();
  }

  @override
  Future<void> flush() async {
    // writeFromSync is already durable; flush only waits out an in-flight
    // open/rotate and drains queued lines. Bounded — a stuck filesystem must
    // not hang the diagnostics page forever.
    var guard = 0;
    while ((_opening || _rotating || _pending.isNotEmpty) && guard++ < 200) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<int> sizeBytes() async {
    var total = 0;
    for (final file in _logFiles) {
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  @override
  Future<List<File>> files() async {
    final out = <File>[];
    for (final file in _logFiles) {
      try {
        if (await file.exists()) out.add(file);
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> clear() async {
    final raf = _raf;
    _raf = null;
    _pending.clear();
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
/// [_pendingCap] lines, oldest dropped, same as [FileLogSink]'s pre-open
/// buffer.
class MemoryLogSink implements LogSink {
  final List<String> _lines = [];
  bool cleared = false;

  @override
  void write(LogLine line) {
    if (_lines.length >= 500) _lines.removeAt(0);
    _lines.add(Redactor.apply(line.formatted()));
  }

  @override
  Future<String> readAll() async => _lines.isEmpty ? '' : '${_lines.join('\n')}\n';

  @override
  Future<void> flush() async {} // writes are synchronous

  @override
  Future<int> sizeBytes() async {
    // A plain loop: fold under an async-arrow context infers T as
    // FutureOr<int> and the analyzer rejects `n + …`.
    var total = 0;
    for (final line in _lines) {
      total += utf8.encode(line).length;
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
  List<String> get lines => List.unmodifiable(_lines);
}
