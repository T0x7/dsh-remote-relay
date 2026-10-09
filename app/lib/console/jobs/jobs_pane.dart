import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_core/api/engine_rpc.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';

import '../inline_error_card.dart';

/// The task list (mockup 屏 F).
///
/// The `job/list` stream **replaces wholesale** rather than diffing, so the
/// first `rows` frame is the complete truth and every later frame supersedes
/// it wholesale. This screen therefore holds one list, not a diff.
///
/// The lifecycle is five wire states — `running` → optional `stopping` → one
/// of `completed` / `killed` / `failed` — collapsed into the three card states
/// the phone shows.
class JobsPane extends StatefulWidget {
  const JobsPane({
    super.key,
    required this.gateway,
    required this.sessionId,
    required this.l10n,
  });

  final EngineGateway gateway;
  final String sessionId;
  final L10n l10n;

  @override
  State<JobsPane> createState() => _JobsPaneState();
}

class _JobsPaneState extends State<JobsPane> {
  List<JobView> _jobs = const [];
  bool _loading = true;
  AppError? _error;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    final stream = widget.gateway.listJobs(sessionId: widget.sessionId);
    stream.items.listen((value) {
      if (!mounted) return;
      final frame = asObject(value);
      if (frame?['type'] != 'rows') return;
      final rows = frame!['jobs'];
      setState(() {
        _loading = false;
        _error = null;
        _jobs = (rows is List<Object?>)
            ? rows.whereType<Map<String, dynamic>>().map(JobView.fromJson).toList()
            : const [];
      });
    });
    stream.errors.listen((Object e) {
      if (!mounted || e is! EngineRemoteError) return;
      setState(() {
        _loading = false;
        _error = e.toAppError();
      });
    });
  }

  Future<void> _kill(JobView job) async {
    final result = await widget.gateway.killJob(
      sessionId: widget.sessionId,
      jobId: job.jobId,
    );
    if (!mounted) return;
    if (!result.isOk) {
      setState(() => _error = result.error!.toAppError());
      return;
    }
    // `already-finished` is a legitimate answer, not a failure.
    final outcome = (result.value! as Map<String, dynamic>)['outcome'];
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(outcome == 'already-finished'
          ? widget.l10n.jobsAlreadyFinished
          : widget.l10n.jobsKillRequested),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    if (_loading) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppTheme.m, AppTheme.m, AppTheme.m, AppTheme.xl),
      children: [
        if (_error != null) ...[
          InlineErrorCard(error: _error!, l10n: l10n),
          const SizedBox(height: AppTheme.m),
        ],
        if (_jobs.isEmpty && _error == null)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Text(l10n.jobsEmpty,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
            ),
          )
        else
          for (final job in _jobs)
            _JobCard(
              job: job,
              l10n: l10n,
              onKill: job.isTerminal ? null : () => _kill(job),
            ),
      ],
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.l10n, this.onKill});

  final JobView job;
  final L10n l10n;
  final VoidCallback? onKill;

  @override
  Widget build(BuildContext context) {
    final (color, stateLabel) = switch (job.state) {
      JobCardState.running => (AppTheme.accent, l10n.jobsStateRunning),
      JobCardState.done => (AppTheme.inkDim, l10n.jobsStateDone),
      JobCardState.failed => (AppTheme.danger, l10n.jobsStateFailed),
      JobCardState.pending => (AppTheme.warn, l10n.jobsStatePending),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.s),
      padding: const EdgeInsets.all(AppTheme.m),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.m),
        border: Border(
          left: BorderSide(color: color, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(job.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Text(stateLabel,
                  style: TextStyle(fontSize: 10.5, color: color)),
            ],
          ),
          if (job.progress != null && job.progress!.isNotEmpty) ...[
            const SizedBox(height: AppTheme.xs),
            Text(job.progress!,
                style: const TextStyle(fontSize: 11, color: AppTheme.inkDim)),
          ],
          if (job.detail != null) ...[
            const SizedBox(height: AppTheme.xs),
            Text(job.detail!,
                style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: job.state == JobCardState.failed
                        ? AppTheme.danger
                        : AppTheme.inkDim)),
          ],
          if (onKill != null) ...[
            const SizedBox(height: AppTheme.s),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onKill,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  foregroundColor: AppTheme.danger,
                ),
                child: Text(l10n.jobsKill),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
