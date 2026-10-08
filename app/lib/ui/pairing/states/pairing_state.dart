import 'package:app/pairing/storage.dart';

sealed class PairingState {
  const PairingState();
}

/// Initial state — UI not yet showing the scanner.
class PairingIdle extends PairingState {
  const PairingIdle();
}

/// Camera viewfinder visible; waiting for a valid QR scan.
class PairingScanning extends PairingState {
  const PairingScanning();
}

/// QR scanned; opening transport + sending pair_request.
class PairingConnecting extends PairingState {
  final String sessionName;
  const PairingConnecting({required this.sessionName});
}

/// Pi confirmed; channel adopted. UI navigates straight to chat
/// after the post-pair nickname modal is dismissed.
///
/// Plan/27 Wave A — [hostnameHint] is what the pi-remote reported
/// as its OS hostname in `pair_ok.hostname`. The post-pair nickname
/// modal pre-fills its input with it (e.g. "Mac do Jacob") instead
/// of the generic "Pi" placeholder. `null` on legacy Pis that
/// haven't been upgraded yet.
class PairingPaired extends PairingState {
  final PeerRecord peer;
  final String? hostnameHint;
  const PairingPaired({required this.peer, this.hostnameHint});

  @override
  bool operator ==(Object other) =>
      other is PairingPaired &&
      other.peer.remoteEpk == peer.remoteEpk &&
      other.hostnameHint == hostnameHint;

  @override
  int get hashCode => Object.hash(peer.remoteEpk, hostnameHint);
}

/// QR parse, transport, or pair_request failed.
class PairingError extends PairingState {
  final String message;
  final bool canRetry;
  const PairingError({required this.message, this.canRetry = true});
}
