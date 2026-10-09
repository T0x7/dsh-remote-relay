import 'package:flutter/foundation.dart';

/// Which machines are **live** right now (design §5 多机器并发策略).
///
/// Only the machine the console is driving may hold a carrier; every other
/// machine is kept fresh by a low-frequency status read instead. The list page
/// therefore has to know who is live, and the console has to be able to say so
/// without either side knowing the other's widget.
///
/// Claims nest: a machine claimed twice (a detail route pushed over the list,
/// then the console) is released only when the last holder lets go, so one
/// closing route cannot un-park a machine another one still drives.
class LiveMachineScope extends ChangeNotifier {
  LiveMachineScope();

  /// The process-wide scope. Both sides default to it and either can be handed
  /// a private one in a test.
  static final LiveMachineScope instance = LiveMachineScope();

  final Map<String, int> _claims = {};

  /// Whether anything is holding [machineId] open.
  bool holds(String machineId) => (_claims[machineId] ?? 0) > 0;

  /// The machines currently held, in claim order.
  Iterable<String> get machineIds => _claims.keys;

  void claim(String machineId) {
    _claims[machineId] = (_claims[machineId] ?? 0) + 1;
    notifyListeners();
  }

  void release(String machineId) {
    final held = _claims[machineId];
    if (held == null) return;
    if (held <= 1) {
      _claims.remove(machineId);
    } else {
      _claims[machineId] = held - 1;
    }
    notifyListeners();
  }
}
