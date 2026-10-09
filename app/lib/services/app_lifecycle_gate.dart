import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

/// 前台/后台闸门 (design §5「切后台即断 WS」).
///
/// The app is either in the foreground, where it holds its carrier and reminds,
/// or in the background, where it must hold neither. Both halves live here so
/// every consumer — the console's controller, and anything added later — reads
/// the same answer, and so the mapping from [AppLifecycleState] is written
/// once.
///
/// Deliberately widget-free beyond the enum: a test drives it by calling
/// [handle], which is exactly what `DshRemoteApp`'s `WidgetsBindingObserver`
/// calls in production.
class AppLifecycleGate extends ChangeNotifier {
  /// The app boots in the foreground; only a platform notification moves it.
  AppLifecycleGate() : _foreground = true;

  /// The process-wide gate. Widgets that build before any test seam is passed
  /// read and drive this one; tests inject their own.
  static final AppLifecycleGate instance = AppLifecycleGate();

  bool _foreground;

  /// Whether the app is in the foreground. Background reminders are a
  /// contradiction — §5 has no background push on purpose.
  bool get foreground => _foreground;

  /// The inverse, named for what consumers actually ask ("is the console
  /// parked?") rather than restating [foreground].
  bool get suspended => !_foreground;

  /// Fold a platform lifecycle notification into the gate.
  ///
  /// A repeated state is not an event: iOS sends `inactive` then `paused` on
  /// the way out and `inactive` then `resumed` on the way in, and treating
  /// those as four transitions would tear the carrier down and back up twice
  /// per app switch.
  void handle(AppLifecycleState state) {
    final next = isBackgroundState(state);
    if (next == !_foreground) return;
    _foreground = !next;
    notifyListeners();
  }

  /// Test / console seam: the same transitions without the enum.
  void enterBackground() => _set(false);

  void enterForeground() => _set(true);

  /// `inactive` counts as foreground on purpose: the app switcher snapshot
  /// still renders the app, and a carrier killed at `inactive` would drop on
  /// every notification shade pull.
  static bool isBackgroundState(AppLifecycleState state) =>
      state == AppLifecycleState.paused || state == AppLifecycleState.detached;

  void _set(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    notifyListeners();
  }
}
