import 'package:dsh_remote_core/api/engine_models.dart';

/// One task that just reached a terminal state.
class JobCompletion {
  const JobCompletion({required this.jobId, this.title, this.failed = false});

  final String jobId;

  /// The job's own label, shown verbatim (engine-supplied, never translated).
  final String? title;

  final bool failed;
}

/// Folds `job/list` row frames into "a task just finished" transitions.
///
/// The wire is a **replace**, not a diff (see `JobsPane`), so the same finished
/// job is present in every row frame the pane ever receives. Folding that
/// naively would prompt once per poll; this remembers which ids have already
/// been seen terminal and only reports the transition.
///
/// The first frame ever only **seeds**: a task that finished while the app was
/// closed must not pop a prompt the moment the console opens — §5's reminder is
/// about what happens while the app is in the foreground.
class JobCompletionWatcher {
  JobCompletionWatcher();

  final Set<String> _terminal = {};
  bool _seeded = false;

  /// The terminal states this watcher recognises. `killed` counts: a task the
  /// user stopped is finished, and a `failed` one is finished too.
  static bool isFinished(JobView job) => job.isTerminal;

  /// Feed one `rows` frame; returns the jobs that finished since the last one.
  List<JobCompletion> onRows(List<JobView> jobs) {
    final completed = <JobCompletion>[];
    for (final job in jobs) {
      if (!isFinished(job)) continue;
      if (!_terminal.add(job.jobId)) continue; // already known to be over
      if (!_seeded) continue; // the opening frame only arms the watcher
      completed.add(JobCompletion(
        jobId: job.jobId,
        title: job.title,
        failed: job.failed,
      ));
    }
    _seeded = true;
    return completed;
  }

  /// Forget everything — a new session's job list is a different universe and
  /// its ids must not be judged against this one's.
  void reset() {
    _terminal.clear();
    _seeded = false;
  }
}
