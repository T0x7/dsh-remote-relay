import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_options.dart';

import 'machine_entry.dart';

/// Machine list persistence (design §12): one encrypted JSON blob under a
/// single key. Abstraction point so widget tests run against memory.
abstract class MachinesRepository {
  Future<List<MachineEntry>> load();
  Future<void> saveAll(List<MachineEntry> machines);
}

class SecureMachinesRepository implements MachinesRepository {
  SecureMachinesRepository({FlutterSecureStorage? storage})
      : _storage = storage ??
            // D-054: 加密选项现在是 App 共享的常量，而不是这一处的字面量——
            // 三处各写一遍正是那次偏好被迁移逻辑吃掉的根因。
            const FlutterSecureStorage(
              aOptions: kSecureAndroidOptions,
              iOptions: kSecureIOSOptions,
            );

  static const _key = 'dsh_remote.machines.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<List<MachineEntry>> load() async =>
      MachineEntry.decodeList(await _storage.read(key: _key) ?? '');

  @override
  Future<void> saveAll(List<MachineEntry> machines) =>
      _storage.write(key: _key, value: MachineEntry.encodeList(machines));
}

/// Test double.
class InMemoryMachinesRepository implements MachinesRepository {
  final entries = <MachineEntry>[];

  @override
  Future<List<MachineEntry>> load() async => List.of(entries);

  @override
  Future<void> saveAll(List<MachineEntry> machines) async {
    entries
      ..clear()
      ..addAll(machines);
  }
}

/// ChangeNotifier host the UI subscribes to (list reloads on save).
class MachinesStore extends ChangeNotifier {
  MachinesStore({required this.repo, this.seed = const []}) {
    machines = ValueNotifier<List<MachineEntry>>(List.of(seed));
  }

  final MachinesRepository repo;
  final List<MachineEntry> seed;
  late final ValueNotifier<List<MachineEntry>> machines;

  Future<void> hydrate() async {
    try {
      final loaded = await repo.load();
      if (loaded.isNotEmpty) machines.value = loaded;
    } on Object {
      // Missing platform channel (tests) or corrupted store → start empty.
    }
  }

  Future<void> add(MachineEntry entry) async {
    final next = [...machines.value.where((m) => m.id != entry.id), entry];
    machines.value = next;
    await repo.saveAll(next);
  }

  Future<void> remove(String id) async {
    final next = machines.value.where((m) => m.id != id).toList();
    machines.value = next;
    await repo.saveAll(next);
  }

  Future<void> replaceCredential(MachineEntry updated) => add(updated);

  @override
  void dispose() {
    machines.dispose();
    super.dispose();
  }
}
