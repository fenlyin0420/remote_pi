import 'dart:async';

import 'package:app/data/pairing/identity_transfer_service.dart';
import 'package:app/domain/contracts/identity_transfer.dart';
import 'package:app/domain/entities/identity_bundle.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/settings/states/identity_backup_state.dart';

/// Drives the Settings "Backup & restore" section.
///
/// Kept separate from [SettingsViewModel] because the flows are modal and
/// long-lived (the system file picker can stay open indefinitely), and because
/// a failure here must not disturb the peer list.
///
/// The restore is two-phase: [prepareImport] parses a chosen file and parks it
/// in [pendingBundle] so the UI can show what will be adopted, then
/// [confirmImport] applies it. Nothing is overwritten until the user confirms.
class IdentityBackupViewModel extends ViewModel<IdentityBackupState> {
  final IdentityTransferService _service;
  final _errors = StreamController<String>.broadcast();
  bool _disposed = false;

  /// Parsed-but-not-yet-applied import, held between the confirm dialog's
  /// open and its answer.
  IdentityBundle? _pendingBundle;
  IdentityBundle? get pendingBundle => _pendingBundle;

  IdentityBackupViewModel(this._service) : super(const IdentityBackupIdle());

  /// Failures worth a SnackBar. One message per failure.
  Stream<String> get errors => _errors.stream;

  /// Whether this device can export/import at all. False on platforms without
  /// the native channel (iOS until it is implemented, desktop, web) — the UI
  /// hides the section rather than offering a dead button.
  bool _supported = true;
  bool get supported => _supported;

  /// Asks for a destination and writes the bundle.
  ///
  /// Resolves to the saved file's name, or `null` when cancelled.
  Future<String?> export() async {
    if (state is IdentityBackupBusy) return null;
    _emit(const IdentityBackupBusy(label: 'Preparing backup…'));
    try {
      final name = await _service.export();
      if (name == null) {
        _emit(const IdentityBackupIdle());
        return null;
      }
      _emit(IdentityBackupExported(fileName: name));
      return name;
    } on IdentityTransferException catch (e) {
      _supported = e.code != 'unsupported';
      _emit(const IdentityBackupIdle());
      _errors.add(e.message);
      return null;
    } on Object catch (e) {
      _emit(const IdentityBackupIdle());
      _errors.add('Could not create the backup: $e');
      return null;
    }
  }

  /// Phase 1 — pick and parse. Returns the parsed bundle for the caller to
  /// describe in a confirmation dialog, or `null` if cancelled or invalid.
  ///
  /// On a bad file the error is surfaced and the parked bundle is cleared, so a
  /// rejected import can never be confirmed later by a stale [pendingBundle].
  Future<IdentityBundle?> prepareImport() async {
    if (state is IdentityBackupBusy) return null;
    _pendingBundle = null;
    _emit(const IdentityBackupBusy(label: 'Reading backup…'));
    try {
      final bundle = await _service.peek();
      if (bundle == null) {
        _emit(const IdentityBackupIdle());
        return null;
      }
      _pendingBundle = bundle;
      _emit(const IdentityBackupIdle());
      return bundle;
    } on IdentityBundleFormatException catch (e) {
      _emit(const IdentityBackupIdle());
      _errors.add(e.message);
      return null;
    } on IdentityTransferException catch (e) {
      _supported = e.code != 'unsupported';
      _emit(const IdentityBackupIdle());
      _errors.add(e.message);
      return null;
    } on Object catch (e) {
      _emit(const IdentityBackupIdle());
      _errors.add('Could not read the backup: $e');
      return null;
    }
  }

  /// Phase 2 — apply the bundle parked by [prepareImport].
  ///
  /// No-op if nothing is parked (the user confirmed a stale dialog).
  /// Resolves to the restore summary, or `null` on failure.
  Future<IdentityRestoreResult?> confirmImport() async {
    final bundle = _pendingBundle;
    if (bundle == null) return null;
    _pendingBundle = null;

    _emit(const IdentityBackupBusy(label: 'Restoring…'));
    try {
      final result = await _service.apply(bundle);
      _emit(
        IdentityBackupRestored(
          peerCount: result.peerCount,
          keypairChanged: result.keypairChanged,
        ),
      );
      return result;
    } on Object catch (e) {
      _emit(const IdentityBackupIdle());
      _errors.add('Could not restore the backup: $e');
      return null;
    }
  }

  /// Drops a parked bundle without applying it (dialog dismissed).
  void cancelImport() {
    _pendingBundle = null;
    if (state is! IdentityBackupBusy) _emit(const IdentityBackupIdle());
  }

  /// Clear a terminal state (exported / restored) back to idle so the section
  /// stops showing a stale confirmation.
  void reset() {
    if (state is IdentityBackupBusy) return;
    _pendingBundle = null;
    _emit(const IdentityBackupIdle());
  }

  void _emit(IdentityBackupState next) {
    if (_disposed) return;
    emit(next);
  }

  @override
  void dispose() {
    _disposed = true;
    _errors.close();
    super.dispose();
  }
}
