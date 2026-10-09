import 'package:dsh_remote_core/net/tofu_pins.dart';
import 'package:dsh_remote_app/data/machine_entry.dart';

/// The TOFU pin table for [entry]'s relay, seeded from the fingerprint learned
/// during pairing (D-025).
///
/// **This is the one place the table is built.** D-025 shipped with the same
/// three-line seeding written out in three places (console, machine detail,
/// renewal scheduler) — and the bug itself was one of a client building the
/// table by hand and forgetting the pin, so a fourth copy was exactly the
/// failure mode waiting to happen.
///
/// A machine paired before D-084 has no stored pin, and the table is then
/// empty. This file used to describe that as "the steady-state client fails
/// closed by design", which was never true: `badCertificateCallback` — the only
/// thing that reads the table — is invoked by dart:io **when validation fails**,
/// so a relay with a publicly-trusted certificate validated normally and the
/// empty table was never consulted. The real consequence is narrower and worth
/// stating plainly: such a machine keeps working, but has **no way to notice a
/// changed certificate**. Re-pairing (which now pins, see
/// `probePeerFingerprint`) is what restores that detection.
MemoryPinStore pinStoreFor(MachineEntry entry) {
  final store = MemoryPinStore();
  final pin = entry.certPin;
  if (pin != null) {
    store.pins[entry.params.relayOrigin.host] = pin;
  }
  return store;
}
