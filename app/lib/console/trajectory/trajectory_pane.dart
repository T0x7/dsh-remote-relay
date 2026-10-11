import 'dart:convert';

import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import 'trajectory_ledger.dart';
import 'trajectory_model.dart';

/// D-042 轨迹视图：事件记录表 + 固定在表上方的时间概览。
///
/// 引擎没有 trajectory 端点，这一屏全部是客户端投影（理由见
/// [TrajectoryProjection]）。三块东西，职责分得很清：
///
/// - **Overview**（顶部固定）：三条语义轨道的耗时投影 + 区间筛选。
/// - **记录表**（可滚）：轮次分组，每行「类型 + 内容」两列。
/// - **检查器**（点行开）：原始载荷 / 计时 / 用量。
///
/// 虚拟化：记录表按 [maxRenderedRows] 截断并**明写**丢了多少，和会话列表
/// 同一个诚实口径。轨迹的价值在「能翻全」，所以这里不做自动跳底，只把
/// 「还有更早」做成一行可点的控件。
class TrajectoryPane extends StatefulWidget {
  const TrajectoryPane({
    super.key,
    required this.ledger,
    required this.gateway,
    required this.sessionId,
    required this.subagentLabel,
  });

  final TrajectoryLedger ledger;
  final EngineGateway gateway;

  /// 引擎会话 id；null 表示还没打开会话。
  final String? sessionId;

  /// 子代理会话的父 id。非 null 时补页要按子代理地址走。
  final String? subagentLabel;

  /// 记录表一次最多建多少行。
  static const maxRenderedRows = 80;

  @override
  State<TrajectoryPane> createState() => _TrajectoryPaneState();
}

class _TrajectoryPaneState extends State<TrajectoryPane> {
  /// 区间筛选（epoch ms，闭区间）；null 表示没筛。
  ({int start, int end})? _range;

  /// 选中的记录；null 表示检查器关着。
  TrajectoryRecord? _selected;

  Future<void> _loadEarlier() async {
    final sessionId = widget.sessionId;
    if (sessionId == null) return;
    final address = widget.subagentLabel == null
        ? PlainSessionAddress(sessionId)
        : SubagentSessionAddress(
            parentSessionId: sessionId,
            childSessionId: sessionId,
            mode: SubagentMode.continuable,
          );
    await widget.ledger.loadEarlier(widget.gateway, address);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final sessionId = widget.sessionId;
    if (sessionId == null) return _Notice(l10n.trajectoryNoSession);

    final projection = widget.ledger.projection;
    if (projection.records.isEmpty) {
      if (widget.ledger.loadingEarlier) return const _Loading();
      return _Notice(l10n.trajectoryEmpty);
    }

    // 区间筛选：闭区间，边界相交即保留（dsh 的语义）；计时未知的记录在
    // 筛选态下被移除——它无法证明自己在区间内。
    final range = _range;
    final visible = <TrajectoryTurn>[];
    if (range == null) {
      visible.addAll(projection.turns);
    } else {
      for (final turn in projection.turns) {
        final kept = [
          for (final r in turn.records)
            if (_inRange(r, range)) r,
        ];
        if (kept.isEmpty) continue;
        visible.add(TrajectoryTurn(
          turn: turn.turn,
          endReason: turn.endReason,
          isError: turn.isError,
          records: kept,
        ));
      }
    }

    final selected = _selected;

    return Column(
      children: [
        _Overview(
          records: projection.records,
          range: range,
          l10n: l10n,
          onRange: (next) => setState(() {
            _range = next;
            _selected = null;
          }),
        ),
        Expanded(
          child: selected == null
              ? _RecordTable(
                  turns: visible,
                  dropped: _dropped(visible, projection),
                  l10n: l10n,
                  loadingEarlier: widget.ledger.loadingEarlier,
                  canLoadEarlier: widget.ledger.hasEarlierHistory,
                  error: widget.ledger.error?.message,
                  onLoadEarlier: _loadEarlier,
                  onSelect: (r) => setState(() => _selected = r),
                )
              : _Inspector(
                  record: selected,
                  l10n: l10n,
                  onClose: () => setState(() => _selected = null),
                ),
        ),
      ],
    );
  }

  /// 筛选后被区间排除掉的行数，如实报出来。
  int _dropped(List<TrajectoryTurn> turns, TrajectoryProjection all) {
    var shown = 0;
    for (final turn in turns) {
      shown += turn.records.length;
    }
    final byRange = all.records.length - shown;
    final byCap = (shown - TrajectoryPane.maxRenderedRows).clamp(0, 1 << 30);
    return byRange + byCap;
  }

  static bool _inRange(TrajectoryRecord r, ({int start, int end}) range) {
    final span = r.span;
    if (span == null) return false;
    return span.end >= range.start && span.start <= range.end;
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.xl),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim),
          ),
        ),
      );
}

/// Overview：三条语义轨道的耗时投影。
///
/// 轨道分配照 dsh `timeline.ts:51-55`（工具/子工具一条、消息与压缩一条、
/// 其余一条）。助手那一行按**真实比例**切成首 token 段与解码段，没有
/// chunk 时间戳就退化成单色——宁可少一段信息，也不画一条编出来的边界。
class _Overview extends StatefulWidget {
  const _Overview({
    required this.records,
    required this.range,
    required this.l10n,
    required this.onRange,
  });

  final List<TrajectoryRecord> records;
  final ({int start, int end})? range;
  final L10n l10n;
  final ValueChanged<({int start, int end})?> onRange;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  /// 拖拽中的两个屏幕坐标。必须放在 state 里：Overview 拖拽期间每帧重画，
  /// stateless 存不住。
  double? _dragFrom;
  double? _dragTo;
  double _width = 1;

  static const _laneColors = [
    AppTheme.inkDim,
    AppTheme.accent,
    Color(0xFF6BA6F5),
  ];

  L10n get l10n => widget.l10n;

  /// 已加载记录的时间域；没有可投影的记录时为 null。
  ({int lo, int hi})? get _domain {
    int? lo;
    int? hi;
    for (final r in widget.records) {
      final span = r.span;
      if (span == null) continue;
      lo = lo == null ? span.start : (span.start < lo ? span.start : lo);
      hi = hi == null ? span.end : (span.end > hi ? span.end : hi);
    }
    if (lo == null || hi == null) return null;
    // 全零跨度（所有记录瞬时完成）会除零，给一个最小窗口。
    return (lo: lo, hi: hi <= lo ? lo + 1 : hi);
  }

  int _toAbsolute(double dx) {
    final domain = _domain!;
    final ratio = (dx / _width).clamp(0.0, 1.0);
    return (domain.lo + ratio * (domain.hi - domain.lo)).round();
  }

  String _ms(int millis) => millis <= 0
      ? '0ms'
      : millis < 1000
          ? '${millis}ms'
          : '${(millis / 1000).toStringAsFixed(millis < 10000 ? 1 : 0)}s';

  void _dragStart(double dx) => setState(() {
        _dragFrom = dx;
        _dragTo = dx;
      });

  void _dragUpdate(double dx) => setState(() {
        _dragFrom ??= dx;
        _dragTo = dx;
      });

  void _cancelDrag() => setState(() {
        _dragFrom = null;
        _dragTo = null;
      });

  void _dragEnd() {
    final from = _dragFrom;
    final to = _dragTo;
    _cancelDrag();
    if (from == null || to == null) return;
    // 误触阈值：手机上 6px 以下当点击，不当区间。
    if ((from - to).abs() < 6) return;
    final a = _toAbsolute(from);
    final b = _toAbsolute(to);
    widget.onRange(a <= b ? (start: a, end: b) : (start: b, end: a));
  }

  @override
  Widget build(BuildContext context) {
    final spans = [
      for (final r in widget.records)
        if (r.span != null) r,
    ];
    if (spans.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.s, AppTheme.l, 0),
        child: Text(
          l10n.trajectoryNoTiming,
          style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
        ),
      );
    }

    final domain = _domain!;
    final range = widget.range;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xs),
          child: Row(
            children: [
              for (var lane = 0; lane < 3; lane++) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _laneColors[lane],
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  switch (lane) {
                    0 => l10n.trajectoryLaneSystem,
                    1 => l10n.trajectoryLaneMessage,
                    _ => l10n.trajectoryLaneTool,
                  },
                  style: const TextStyle(fontSize: 9.5, color: AppTheme.inkDim),
                ),
                const SizedBox(width: AppTheme.m),
              ],
              const Spacer(),
              if (range != null)
                GestureDetector(
                  onTap: () => widget.onRange(null),
                  child: Text(
                    l10n.trajectoryRangeClear,
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.accent),
                  ),
                ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            _width = box.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) => _dragStart(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => _dragUpdate(d.localPosition.dx),
              onHorizontalDragEnd: (_) => _dragEnd(),
              onHorizontalDragCancel: _cancelDrag,
              child: SizedBox(
                height: 54,
                child: CustomPaint(
                  size: Size(box.maxWidth, 54),
                  painter: _TimelinePainter(
                    records: spans,
                    lo: domain.lo,
                    hi: domain.hi,
                    range: range,
                    dragFrom: _dragFrom,
                    dragTo: _dragTo,
                    laneColors: _laneColors,
                  ),
                ),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppTheme.l, AppTheme.xs, AppTheme.l, AppTheme.s),
          child: Text(
            range == null
                ? l10n.trajectoryHint
                : l10n.trajectoryRangeActive(
                    _ms(range.start - domain.lo),
                    _ms(range.end - domain.lo),
                  ),
            style: const TextStyle(fontSize: 10, color: AppTheme.inkDim),
          ),
        ),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.records,
    required this.lo,
    required this.hi,
    required this.range,
    required this.dragFrom,
    required this.dragTo,
    required this.laneColors,
  });

  final List<TrajectoryRecord> records;
  final int lo;
  final int hi;
  final ({int start, int end})? range;
  final double? dragFrom;
  final double? dragTo;
  final List<Color> laneColors;

  @override
  void paint(Canvas canvas, Size size) {
    final span = (hi - lo).toDouble();
    double x(int absolute) => ((absolute - lo) / span) * size.width;

    // 轨道基线
    for (var lane = 0; lane < 3; lane++) {
      final y = 10 + lane * 15.0;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = AppTheme.line
          ..strokeWidth = 1,
      );
    }

    final rangeStart = range == null ? null : x(range!.start);
    final rangeEnd = range == null ? null : x(range!.end);

    for (final record in records) {
      final s = record.span!;
      final left = x(s.start);
      final right = x(s.end);
      final y = 10 + record.kind.lane * 15.0;
      final width = (right - left).clamp(2.0, size.width);
      final inRange = range == null ||
          (s.end >= range!.start && s.start <= range!.end);
      final paint = Paint()
        ..color = laneColors[record.kind.lane]
            .withValues(alpha: inRange ? 0.9 : 0.18);

      if (record.kind == TrajectoryKind.message &&
          record.ttftMs != null &&
          record.decodeMs != null &&
          record.ttftMs! > 0) {
        // 助手条按真实比例切：首 token 段与解码段。
        final total = (record.ttftMs! + record.decodeMs!).toDouble();
        if (total > 0) {
          final split = left + width * (record.ttftMs! / total);
          canvas.drawRect(
            Rect.fromLTRB(left, y - 3, split, y + 3),
            paint..color = laneColors[record.kind.lane].withValues(alpha: 0.35),
          );
          canvas.drawRect(
            Rect.fromLTRB(split, y - 3, left + width, y + 3),
            paint,
          );
          continue;
        }
      }
      canvas.drawRect(Rect.fromLTRB(left, y - 3, left + width, y + 3), paint);
    }

    // 选区
    if (rangeStart != null && rangeEnd != null) {
      canvas.drawRect(
        Rect.fromLTRB(rangeStart, 0, rangeEnd, size.height),
        Paint()..color = AppTheme.accent.withValues(alpha: 0.10),
      );
      for (final edge in [rangeStart, rangeEnd]) {
        canvas.drawLine(
          Offset(edge, 0),
          Offset(edge, size.height),
          Paint()
            ..color = AppTheme.accent
            ..strokeWidth = 1.5,
        );
      }
    } else if (dragFrom != null && dragTo != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          dragFrom! < dragTo! ? dragFrom! : dragTo!,
          0,
          dragFrom! < dragTo! ? dragTo! : dragFrom!,
          size.height,
        ),
        Paint()..color = AppTheme.accent.withValues(alpha: 0.14),
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.records != records ||
      old.range != range ||
      old.dragFrom != dragFrom ||
      old.dragTo != dragTo ||
      old.lo != lo ||
      old.hi != hi;
}

/// 记录表：轮次分组 + 类型/内容两列。
class _RecordTable extends StatelessWidget {
  const _RecordTable({
    required this.turns,
    required this.dropped,
    required this.l10n,
    required this.loadingEarlier,
    required this.canLoadEarlier,
    required this.error,
    required this.onLoadEarlier,
    required this.onSelect,
  });

  final List<TrajectoryTurn> turns;
  final int dropped;
  final L10n l10n;
  final bool loadingEarlier;
  final bool canLoadEarlier;
  final String? error;
  final VoidCallback onLoadEarlier;
  final ValueChanged<TrajectoryRecord> onSelect;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    var budget = TrajectoryPane.maxRenderedRows;
    var truncated = 0;

    for (final turn in turns) {
      if (budget <= 0) {
        truncated += turn.records.length;
        continue;
      }
      rows.add(_TurnHeader(turn: turn, l10n: l10n));
      for (final record in turn.records) {
        if (budget <= 0) {
          truncated++;
          continue;
        }
        budget--;
        rows.add(_RecordRow(
          record: record,
          l10n: l10n,
          onTap: () => onSelect(record),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.m, AppTheme.xs, AppTheme.m, AppTheme.xl),
      children: [
        if (canLoadEarlier || loadingEarlier || error != null) ...[
          if (loadingEarlier)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s),
              child: Text(
                l10n.trajectoryLoadingEarlier,
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
              ),
            )
          else
            Center(
              child: TextButton(
                onPressed: onLoadEarlier,
                child: Text(
                  l10n.trajectoryLoadEarlier,
                  style: const TextStyle(fontSize: 12, color: AppTheme.accent),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s),
              child: Text(
                l10n.trajectoryEarlierFailed(error!),
                style: const TextStyle(fontSize: 11, color: AppTheme.warn),
              ),
            ),
        ],
        if (truncated > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s),
            child: Text(
              l10n.trajectoryTruncated(
                TrajectoryPane.maxRenderedRows,
                truncated,
              ),
              style: const TextStyle(fontSize: 11, color: AppTheme.warn),
            ),
          ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.xl),
            child: Text(
              l10n.trajectoryEmptyRange,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppTheme.inkDim),
            ),
          ),
        ...rows,
      ],
    );
  }
}

class _TurnHeader extends StatelessWidget {
  const _TurnHeader({required this.turn, required this.l10n});

  final TrajectoryTurn turn;
  final L10n l10n;

  @override
  Widget build(BuildContext context) {
    final label = turn.turn == null
        ? l10n.trajectoryBetweenTurns
        : l10n.trajectoryTurn(turn.turn!);
    return Container(
      margin: const EdgeInsets.only(top: AppTheme.m, bottom: AppTheme.xs),
      padding: const EdgeInsets.only(bottom: AppTheme.xs),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            // 轮次边界用稍粗的线，和普通行区分（dsh 同款做法）。
            color: turn.isError ? AppTheme.warn : AppTheme.line,
            width: turn.isError ? 1.5 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            margin: const EdgeInsets.only(right: AppTheme.s),
            color: turn.isError ? AppTheme.warn : AppTheme.accent,
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: turn.isError ? AppTheme.warn : AppTheme.inkDim,
            ),
          ),
          if (turn.endReason != null) ...[
            const SizedBox(width: AppTheme.s),
            Text(
              turn.endReason!,
              style: const TextStyle(fontSize: 10, color: AppTheme.inkDim),
            ),
          ],
          const Spacer(),
          // 请求号未知时**不显示**。引擎还没发过 `request/header` 的窗口
          // 里它就是 null，画一个 `#-` 像是出了错。
          if (turn.records.first.requestNumber case final n?)
            Text(
              '#$n',
              style: const TextStyle(fontSize: 10, color: AppTheme.inkDim),
            ),
        ],
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({
    required this.record,
    required this.l10n,
    required this.onTap,
  });

  final TrajectoryRecord record;
  final L10n l10n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 子工具缩进，和 dsh 的「嵌套子工具略微缩进」一致。
    final indent = record.kind == TrajectoryKind.subtool ? AppTheme.l : 0.0;
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(bottom: 2, left: indent),
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s, vertical: AppTheme.xs),
        decoration: BoxDecoration(
          color: record.isError
              ? AppTheme.warn.withValues(alpha: 0.08)
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.xs),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 类型列
            SizedBox(
              width: 108,
              child: Text(
                record.eventType,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: record.isError ? AppTheme.warn : AppTheme.inkDim,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.s),
            // 内容列
            Expanded(
              child: Text(
                _previewOf(record, l10n),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: record.isError ? AppTheme.warn : AppTheme.ink,
                ),
              ),
            ),
            if (record.durationMs != null) ...[
              const SizedBox(width: AppTheme.s),
              Text(
                _fmt(record.durationMs!),
                style: const TextStyle(
                    fontSize: 9.5, color: AppTheme.inkDim, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// D-049: the sentence a tool-result row shows.
  ///
  /// The projection deliberately emits **parts**, not a finished string: it is a
  /// pure fold with no locale, and baking 「错误」/「返回」 into it shipped
  /// Chinese into the English UI. The two connective words are assembled here,
  /// where `L10n` exists.
  static String _previewOf(TrajectoryRecord record, L10n l10n) {
    final direct = record.preview;
    if (direct != null) return direct.isEmpty ? '—' : direct;
    final parts = record.previewParts;
    if (parts == null) return '—';
    final name = record.toolName ?? 'tool';
    if (parts.isError) {
      final code = parts.errorCode;
      return '$name · ${l10n.trajectoryToolError} ${parts.errorName}'
          '${code == null ? '' : ' ($code)'}';
    }
    return '$name · ${l10n.trajectoryToolReturn}';
  }

  static String _fmt(int ms) => ms < 1000
      ? '${ms}ms'
      : '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)}s';
}

/// 检查器：原始载荷 / 计时 / 用量。
///
/// 手机上不用底部弹层（会盖住记录表），直接整页替换记录表——和 dsh 在
/// 窄屏下「检查器覆盖记录表」的行为一致。
class _Inspector extends StatelessWidget {
  const _Inspector({
    required this.record,
    required this.l10n,
    required this.onClose,
  });

  final TrajectoryRecord record;
  final L10n l10n;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.m, AppTheme.s, AppTheme.s, AppTheme.s),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: Text(l10n.trajectoryInspector,
                      style: const TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                Text(
                  'seq ${record.seq}',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.inkDim, fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.m),
            child: Text(
              record.eventType,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
            ),
          ),
          if (record.toolName != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.m, AppTheme.xs, AppTheme.m, 0),
              child: Text(
                '${record.toolName}${record.callId == null ? '' : ' · ${record.callId}'}',
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
              ),
            ),
          if (record.model != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.m, AppTheme.xs, AppTheme.m, 0),
              child: Text(
                '${record.provider ?? '?'} / ${record.model}',
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim),
              ),
            ),
          const SizedBox(height: AppTheme.s),
          _InspectorSection(
            title: l10n.trajectoryTabTiming,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!record.hasTiming)
                  Text(l10n.trajectoryNoTiming,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.inkDim))
                else ...[
                  _kv(l10n.trajectoryStarted,
                      _stamp(record.startedAt), _mono),
                  if (record.durationMs != null)
                    _kv(l10n.trajectoryTotal,
                        _RecordRow._fmt(record.durationMs!), _mono),
                  if (record.ttftMs != null)
                    _kv(l10n.trajectoryTtft,
                        _RecordRow._fmt(record.ttftMs!), _mono),
                  if (record.decodeMs != null)
                    _kv(l10n.trajectoryDecode,
                        _RecordRow._fmt(record.decodeMs!), _mono),
                ],
              ],
            ),
          ),
          _InspectorSection(
            title: l10n.trajectoryTabUsage,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: record.hasUsage
                  ? [
                      if (record.inputTokens != null)
                        _kv('input', '${record.inputTokens}', _mono),
                      if (record.cacheReadTokens != null)
                        _kv('cache read', '${record.cacheReadTokens}', _mono),
                      if (record.cacheWriteTokens != null)
                        _kv('cache write', '${record.cacheWriteTokens}', _mono),
                      if (record.outputTokens != null)
                        _kv('output', '${record.outputTokens}', _mono),
                      if (record.reasoningTokens != null)
                        _kv('reasoning', '${record.reasoningTokens}', _mono),
                      if (record.reasoningChars != null)
                        _kv('thought', '${record.reasoningChars}', _mono),
                    ]
                  : [
                      Text('—',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.inkDim)),
                    ],
            ),
          ),
          Expanded(
            child: _InspectorSection(
              title: l10n.trajectoryTabPayload,
              grow: true,
              child: SingleChildScrollView(
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(record.raw),
                  style: const TextStyle(
                      fontSize: 10, fontFamily: 'monospace', height: 1.35),
                ),
              ),
            ),
          ),
        ],
      );

  static TextStyle get _mono =>
      const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AppTheme.ink);

  static String _stamp(int? ms) => ms == null
      ? '—'
      : '${DateTime.fromMillisecondsSinceEpoch(ms).hour.toString().padLeft(2, '0')}:'
          '${DateTime.fromMillisecondsSinceEpoch(ms).minute.toString().padLeft(2, '0')}:'
          '${DateTime.fromMillisecondsSinceEpoch(ms).second.toString().padLeft(2, '0')}';

  static Widget _kv(String k, String v, TextStyle style) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(k,
                  style: const TextStyle(fontSize: 10.5, color: AppTheme.inkDim)),
            ),
            Text(v, style: style),
          ],
        ),
      );
}

class _InspectorSection extends StatelessWidget {
  const _InspectorSection({
    required this.title,
    required this.child,
    this.grow = false,
  });

  final String title;
  final Widget child;
  final bool grow;

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.m, 0, AppTheme.m, AppTheme.m),
      child: child,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.inkDim)),
          const SizedBox(height: AppTheme.xs),
          if (grow) Expanded(child: body) else body,
        ],
      ),
    );
  }
}
