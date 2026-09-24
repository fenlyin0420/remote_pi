import 'package:app/domain/contracts/identity_transfer.dart';
import 'package:app/domain/entities/identity_bundle.dart';
import 'package:app/pairing/owner_identity_bridge.dart';
import 'package:app/pairing/storage.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

/// Outcome of [IdentityTransferService.import] — enough for the UI to tell the
/// user what actually came back.
class IdentityRestoreResult {
  /// Peers restored from the bundle.
  final int peerCount;

  /// Whether the bundle's keypair replaced the one this device was using.
  ///
  /// `false` means the file was a backup of *this very device* (same Owner pk)
  /// — a no-op for the keypair, though peers may still have been adopted.
  final bool keypairChanged;

  /// When the bundle was written, for display.
  final String exportedAt;

  const IdentityRestoreResult({
    required this.peerCount,
    required this.keypairChanged,
    required this.exportedAt,
  });
}

/// Assembles and applies [IdentityBundle]s, using [IdentityTransfer] for the
/// user-mediated file I/O.
///
/// Restoring is the delicate half: accepting a keypair changes who this device
/// is to the relay, so every peer handle from the *previous* identity becomes
/// meaningless and must be cleared first. That mirrors what
/// [OwnerIdentityBridge] does when platform key-sync delivers a new key, and
/// reusing the same order matters — see the wipe in [restore].
class IdentityTransferService {
  final IdentityTransfer _transfer;
  final OwnerIdentityBridge _bridge;
  final PairingStorage _pairing;
  final OwnerIdentityStore _identityStore;

  IdentityTransferService({
    required IdentityTransfer transfer,
    required OwnerIdentityBridge bridge,
    required PairingStorage pairing,
    required OwnerIdentityStore identityStore,
  })  : _transfer = transfer,
        _bridge = bridge,
        _pairing = pairing,
        _identityStore = identityStore;

  /// Writes the current identity + peers to a user-chosen file.
  ///
  /// Returns the file's display name, or `null` if the user cancelled.
  /// Throws [IdentityTransferException] on I/O failure, and
  /// [StateError] if called before the identity has booted.
  Future<String?> export() async {
    final identity = _bridge.currentIdentity;
    if (identity == null) {
      throw StateError(
        'IdentityTransferService.export() called before boot() — there is no '
        'identity to export yet.',
      );
    }

    final bundle = IdentityBundle(
      identity: identity,
      peers: await _pairing.listPeers(),
      exportedAt: DateTime.now().toUtc().toIso8601String(),
    );

    return _transfer.export(
      json: bundle.encode(),
      fileName: bundle.suggestedFileName(),
    );
  }

  /// Picks a file, validates it, and applies it.
  ///
  /// Returns `null` if the user cancelled. Throws
  /// [IdentityBundleFormatException] when the file is not a usable backup —
  /// the message is safe to show directly.
  Future<IdentityRestoreResult?> import() async {
    final raw = await _transfer.import();
    if (raw == null) return null;

    // Parse before touching any state: a bad file must leave the device
    // exactly as it was.
    final bundle = IdentityBundle.decode(raw);

    final current = _bridge.currentIdentity;
    final sameKeypair =
        current != null && _sameKey(bundle.identity, current);

    if (!sameKeypair) {
      // The incoming keypair replaces ours, so the peer list we hold belongs
      // to the old identity and points at handles the relay will no longer
      // accept. Clear it before adopting — same reasoning as the
      // platform-sync path in OwnerIdentityBridge.startWatching.
      await _pairing.wipeAll();
      await _identityStore.save(bundle.identity);
      _bridge.adoptIdentity(bundle.identity);
    }

    // Restore peers after the wipe (or on top of an identical key set). These
    // are written silently: importing a backup is a local restore, not a
    // membership change, so it must not push a mesh update to the relay.
    for (final peer in bundle.peers) {
      await _pairing.savePeerSilent(peer);
    }

    return IdentityRestoreResult(
      peerCount: bundle.peers.length,
      keypairChanged: !sameKeypair,
      exportedAt: bundle.exportedAt,
    );
  }

  /// Constant-time-ish comparison of the public halves. The public key *is*
  /// the identity on the wire, so comparing it decides "same device".
  static bool _sameKey(OwnerIdentity a, OwnerIdentity b) {
    if (a.ownerPk.length != b.ownerPk.length) return false;
    var diff = 0;
    for (var i = 0; i < a.ownerPk.length; i++) {
      diff |= a.ownerPk[i] ^ b.ownerPk[i];
    }
    return diff == 0;
  }

  /// Renders a bundle summary for the import confirmation dialog, so the user
  /// can see what they are about to adopt before anything is overwritten.
  static String describe(IdentityBundle bundle) {
    final when = DateTime.tryParse(bundle.exportedAt)?.toLocal();
    final stamp = when == null
        ? 'an unknown date'
        : '${when.year}-${_two(when.month)}-${_two(when.day)} '
              '${_two(when.hour)}:${_two(when.minute)}';
    final peers = bundle.peers.length;
    final peerText = peers == 1 ? '1 paired Pi' : '$peers paired Pis';
    return 'Backup from $stamp, containing $peerText.';
  }

  /// Peek at a file without applying it — same parse, used to show the
  /// confirmation dialog.
  Future<IdentityBundle?> peek() async {
    final raw = await _transfer.import();
    if (raw == null) return null;
    return IdentityBundle.decode(raw);
  }

  /// Applies an already-peeked bundle. Split from [peek] so the user confirms
  /// the *parsed* content rather than a file that is re-read on confirm.
  Future<IdentityRestoreResult> apply(IdentityBundle bundle) async {
    final current = _bridge.currentIdentity;
    final sameKeypair =
        current != null && _sameKey(bundle.identity, current);

    if (!sameKeypair) {
      await _pairing.wipeAll();
      await _identityStore.save(bundle.identity);
      _bridge.adoptIdentity(bundle.identity);
    }

    for (final peer in bundle.peers) {
      await _pairing.savePeerSilent(peer);
    }

    return IdentityRestoreResult(
      peerCount: bundle.peers.length,
      keypairChanged: !sameKeypair,
      exportedAt: bundle.exportedAt,
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
