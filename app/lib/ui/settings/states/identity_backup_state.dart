/// State machine for the Settings "Backup & restore" section.
///
/// Terminal states ([IdentityBackupExported], [IdentityBackupRestored]) carry
/// the outcome so the section can show a confirmation instead of a generic
/// idle row; [IdentityBackupViewModel.reset] clears them.
sealed class IdentityBackupState {
  const IdentityBackupState();
}

/// Nothing in flight, no recent outcome to show.
class IdentityBackupIdle extends IdentityBackupState {
  const IdentityBackupIdle();

  @override
  bool operator ==(Object other) => other is IdentityBackupIdle;

  @override
  int get hashCode => 0;
}

/// A flow is running. [label] is shown next to the spinner — the file picker
/// is a separate system screen, so the label only covers our own work.
class IdentityBackupBusy extends IdentityBackupState {
  final String label;

  const IdentityBackupBusy({required this.label});

  @override
  bool operator ==(Object other) =>
      other is IdentityBackupBusy && other.label == label;

  @override
  int get hashCode => label.hashCode;
}

/// A backup was written to [fileName].
class IdentityBackupExported extends IdentityBackupState {
  final String fileName;

  const IdentityBackupExported({required this.fileName});

  @override
  bool operator ==(Object other) =>
      other is IdentityBackupExported && other.fileName == fileName;

  @override
  int get hashCode => fileName.hashCode;
}

/// An import completed. [keypairChanged] distinguishes "this is this device's
/// own backup" (peers re-adopted, identity untouched) from a real device swap,
/// which is worth telling the user about because it invalidates whatever the
/// Pi had cached for the previous identity.
class IdentityBackupRestored extends IdentityBackupState {
  final int peerCount;
  final bool keypairChanged;

  const IdentityBackupRestored({
    required this.peerCount,
    required this.keypairChanged,
  });

  @override
  bool operator ==(Object other) =>
      other is IdentityBackupRestored &&
      other.peerCount == peerCount &&
      other.keypairChanged == keypairChanged;

  @override
  int get hashCode => Object.hash(peerCount, keypairChanged);
}
