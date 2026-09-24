import 'dart:convert';
import 'dart:typed_data';

import 'package:app/pairing/storage.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

/// Portable snapshot of "who this phone is" — the Owner keypair plus the
/// paired peers — so a new phone can pick up an existing pairing instead of
/// scanning the QR again.
///
/// This exists because the platform key-sync backends (iCloud Keychain /
/// Android Block Store) only restore within the same OS account, and Android's
/// Block Store only restores on a device-restore, not to a second live device.
/// Moving to a phone that is not a restore of the old one needs a file the user
/// carries across.
///
/// ## Security
///
/// The bundle contains the Owner **private** key. Anyone holding the file can
/// impersonate this device to the relay and to paired Pis. That is inherent to
/// the feature — it is a backup of a credential — so the UI must warn plainly
/// and the transport must be user-chosen rather than implicit. The file is
/// written only to a location the user picks.
class IdentityBundle {
  /// Bumped when the envelope shape changes in a way older readers cannot
  /// handle. Readers reject versions they do not know rather than guessing.
  static const int currentFormatVersion = 1;

  /// Identifies the file as ours so a wrong pick fails loudly instead of
  /// producing a nonsense error deep in the key decoder.
  static const String magic = 'remote-pi-identity';

  /// The Ed25519 Owner keypair. Both halves are needed: the public half is the
  /// device's identity on the relay, the private half proves it.
  final OwnerIdentity identity;

  /// Peers this device was paired with. Restoring these is what removes the
  /// re-scan: the relay already knows the Owner pk, so the existing pairing
  /// stays valid.
  final List<PeerRecord> peers;

  /// When the bundle was written (ISO-8601, UTC). Informational only — shown in
  /// the import confirmation so the user can tell two backups apart.
  final String exportedAt;

  const IdentityBundle({
    required this.identity,
    required this.peers,
    required this.exportedAt,
  });

  /// Builds the on-disk JSON. Encoding is UTF-8 JSON rather than raw bytes so
  /// the file stays inspectable: a user who opens it can see it is a key
  /// backup, and support can read the peer list without tooling.
  ///
  /// Keys are base64 (standard, padded) — the same encoding the wire protocol
  /// uses for `epk`, so the values are recognisable across the codebase.
  String encode() {
    return const JsonEncoder.withIndent('  ').convert({
      'magic': magic,
      'format_version': currentFormatVersion,
      'exported_at': exportedAt,
      'owner_pk': base64Encode(identity.ownerPk),
      'owner_sk': base64Encode(identity.ownerSk),
      'peers': peers.map((p) => p.toJson()).toList(),
    });
  }

  /// Parses [raw]. Throws [IdentityBundleFormatException] with a message meant
  /// for the user — this runs on data they just picked, so "wrong file" has to
  /// be distinguishable from "corrupt file".
  static IdentityBundle decode(String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      throw const IdentityBundleFormatException(
        'not_json',
        'That file is not a Remote Pi backup.',
      );
    }
    if (parsed is! Map<String, dynamic>) {
      throw const IdentityBundleFormatException(
        'not_json',
        'That file is not a Remote Pi backup.',
      );
    }
    if (parsed['magic'] != magic) {
      throw const IdentityBundleFormatException(
        'wrong_file',
        'That file is not a Remote Pi backup.',
      );
    }

    final version = parsed['format_version'];
    if (version is! int) {
      throw const IdentityBundleFormatException(
        'corrupt',
        'The backup file is damaged (missing format version).',
      );
    }
    if (version > currentFormatVersion) {
      // A newer app wrote it; we cannot know what changed.
      throw IdentityBundleFormatException(
        'too_new',
        'This backup was written by a newer version of Remote Pi '
        '(format $version). Update the app, then import again.',
      );
    }

    final Uint8List pk;
    final Uint8List sk;
    try {
      pk = base64Decode(parsed['owner_pk'] as String);
      sk = base64Decode(parsed['owner_sk'] as String);
    } on Object {
      throw const IdentityBundleFormatException(
        'corrupt',
        'The backup file is damaged (unreadable key material).',
      );
    }

    final OwnerIdentity identity;
    try {
      identity = OwnerIdentity(ownerPk: pk, ownerSk: sk);
    } on ArgumentError {
      // Right shape, wrong length — truncated or hand-edited.
      throw const IdentityBundleFormatException(
        'corrupt',
        'The backup file is damaged (key material has the wrong length).',
      );
    }

    final peersRaw = parsed['peers'];
    final peers = <PeerRecord>[];
    if (peersRaw is List) {
      for (final entry in peersRaw) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          peers.add(PeerRecord.fromJson(entry));
        } on Object {
          // Skip a malformed peer rather than rejecting the whole bundle: the
          // keypair is the part that cannot be re-derived, and a peer the app
          // cannot read is one the user can simply re-pair.
          continue;
        }
      }
    }

    return IdentityBundle(
      identity: identity,
      peers: peers,
      exportedAt: parsed['exported_at'] as String? ?? '',
    );
  }

  /// Filename suggested to the user. Date-stamped so repeated exports do not
  /// silently overwrite each other in a Downloads folder.
  String suggestedFileName() {
    final d = DateTime.tryParse(exportedAt)?.toUtc();
    final stamp = d == null
        ? 'backup'
        : '${d.year}${_two(d.month)}${_two(d.day)}'
              '-${_two(d.hour)}${_two(d.minute)}';
    return 'remote-pi-identity-$stamp.json';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

/// A user-facing reason the file could not be used. [code] is stable for tests
/// and logging; [message] is what the UI shows.
class IdentityBundleFormatException implements Exception {
  final String code;
  final String message;

  const IdentityBundleFormatException(this.code, this.message);

  @override
  String toString() => 'IdentityBundleFormatException($code): $message';
}
