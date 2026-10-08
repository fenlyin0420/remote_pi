import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'mesh_envelope.dart';

/// One member of an Owner's mesh — exactly one paired Pi, with its
/// local nickname and the relay URL where the pairing happened.
///
/// Mirrors the shape documented in plan/24 § "Estrutura do mesh blob".
@immutable
class MeshMember {
  final String remoteEpk;
  final String relayUrl;
  final String pairedAt;
  final String? nickname;

  const MeshMember({
    required this.remoteEpk,
    required this.relayUrl,
    required this.pairedAt,
    this.nickname,
  });

  /// JSON shape used inside the canonical blob. `nickname` is omitted
  /// when null — keeping the wire form minimal and matching the Rust
  /// `#[serde(skip_serializing_if = "Option::is_none")]` rule on the
  /// relay side.
  Map<String, Object?> toJson() => {
        'paired_at': pairedAt,
        'relay_url': relayUrl,
        'remote_epk': remoteEpk,
        if (nickname != null) 'nickname': nickname,
      };

  static MeshMember fromJson(Map<String, Object?> json) {
    final remoteEpk = json['remote_epk'];
    final relayUrl = json['relay_url'];
    final pairedAt = json['paired_at'];
    final nickname = json['nickname'];
    if (remoteEpk is! String || relayUrl is! String || pairedAt is! String) {
      throw const FormatException(
        'MeshMember: missing required string fields',
      );
    }
    if (nickname != null && nickname is! String) {
      throw const FormatException(
        'MeshMember: nickname must be a string when present',
      );
    }
    return MeshMember(
      remoteEpk: remoteEpk,
      relayUrl: relayUrl,
      pairedAt: pairedAt,
      nickname: nickname as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MeshMember &&
          other.remoteEpk == remoteEpk &&
          other.relayUrl == relayUrl &&
          other.pairedAt == pairedAt &&
          other.nickname == nickname);

  @override
  int get hashCode => Object.hash(remoteEpk, relayUrl, pairedAt, nickname);
}

/// Plan 24 — signed-membership payload published to the relay's
/// `POST /mesh/<owner_pk_hash>` endpoint.
///
/// Canonical JSON shape (keys sorted lexicographically, no whitespace):
///
/// ```json
/// {
///   "issued_at": 1747958400000,
///   "members": [{"paired_at":"…","relay_url":"…","remote_epk":"…"}],
///   "owner_pk": "<base64>",
///   "version": 18
/// }
/// ```
///
/// The same canonicalization rules are enforced by the relay
/// (`relay/src/mesh/verify.rs`) and the pi-remote self-revoke
/// client. Any divergence breaks Ed25519 verification — when in doubt,
/// compare bytes from [toCanonicalBytes].
@immutable
class MeshBlob {
  /// Monotonically increasing — relay rejects `new <= current` with 409.
  final int version;

  /// Milliseconds since Unix epoch (UTC).
  final int issuedAt;

  /// Owner Ed25519 public key, 32 bytes.
  final Uint8List ownerPk;

  /// Paired Pis (and their nicknames). Ordering is preserved on the
  /// wire — clients should sort/dedupe themselves before constructing
  /// the blob if they want stable hashes between equivalent
  /// memberships.
  final List<MeshMember> members;

  MeshBlob({
    required this.version,
    required this.issuedAt,
    required Uint8List ownerPk,
    List<MeshMember> members = const [],
  })  : ownerPk = Uint8List.fromList(ownerPk),
        members = List.unmodifiable(members) {
    if (this.ownerPk.length != 32) {
      throw ArgumentError.value(
        this.ownerPk.length,
        'ownerPk.length',
        'Ed25519 public key must be exactly 32 bytes',
      );
    }
    if (version <= 0) {
      throw ArgumentError.value(
        version,
        'version',
        'mesh blob version must be a positive integer',
      );
    }
  }

  /// Canonical bytes used both for signing and verification.
  ///
  /// JCS-lite: keys sorted lexicographically, no whitespace, compact
  /// separators. Implemented by walking the structure manually rather
  /// than relying on `jsonEncode` defaults — which compact correctly
  /// but do not order keys. The result is the exact byte sequence the
  /// relay re-hashes when verifying the Ed25519 signature.
  Uint8List toCanonicalBytes() {
    final root = _sortedMap({
      'issued_at': issuedAt,
      'members': members.map((m) => _sortedMap(m.toJson())).toList(growable: false),
      'owner_pk': base64.encode(ownerPk),
      'version': version,
    });
    return Uint8List.fromList(utf8.encode(jsonEncode(root)));
  }

  /// Parses the canonical-bytes form back into a [MeshBlob].
  /// Tolerant of key order on the wire (parses any valid JSON) — the
  /// canonical form is enforced when *producing*, not when consuming.
  /// Throws [FormatException] on malformed input.
  static MeshBlob fromCanonicalBytes(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw FormatException('MeshBlob: not valid UTF-8 JSON (${e.message})');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('MeshBlob: root must be a JSON object');
    }
    final version = decoded['version'];
    final issuedAt = decoded['issued_at'];
    final ownerPkB64 = decoded['owner_pk'];
    final membersRaw = decoded['members'];
    if (version is! int || version <= 0) {
      throw const FormatException(
        'MeshBlob: version must be a positive integer',
      );
    }
    if (issuedAt is! int) {
      throw const FormatException('MeshBlob: issued_at must be an integer');
    }
    if (ownerPkB64 is! String) {
      throw const FormatException('MeshBlob: owner_pk must be base64 string');
    }
    if (membersRaw is! List) {
      throw const FormatException('MeshBlob: members must be a list');
    }
    final members = <MeshMember>[];
    for (final raw in membersRaw) {
      if (raw is! Map<String, Object?>) {
        throw const FormatException('MeshBlob: each member must be a JSON object');
      }
      members.add(MeshMember.fromJson(raw));
    }
    return MeshBlob(
      version: version,
      issuedAt: issuedAt,
      ownerPk: base64.decode(ownerPkB64),
      members: members,
    );
  }

  /// Produce an [MeshEnvelope] signed by [ownerKey] (must be the
  /// Ed25519 keypair whose public key matches [ownerPk]).
  Future<MeshEnvelope> signWith(SimpleKeyPair ownerKey) async {
    final bytes = toCanonicalBytes();
    final sig = await Ed25519().sign(bytes, keyPair: ownerKey);
    return MeshEnvelope(
      blob: bytes,
      sig: Uint8List.fromList(sig.bytes),
    );
  }

  /// Verify the [envelope]'s signature against [ownerPk]. Returns
  /// `true` if the sig is valid AND the embedded blob's owner_pk
  /// matches.
  static Future<bool> verifyEnvelope(MeshEnvelope envelope) async {
    final MeshBlob inner;
    try {
      inner = fromCanonicalBytes(envelope.blob);
    } on FormatException {
      return false;
    }
    final pk = SimplePublicKey(inner.ownerPk, type: KeyPairType.ed25519);
    return Ed25519().verify(
      envelope.blob,
      signature: Signature(envelope.sig, publicKey: pk),
    );
  }
}

/// Walk a `Map` and return a fresh `SplayTreeMap` view that orders
/// keys lexicographically. Used recursively by [MeshBlob.toCanonicalBytes].
SplayTreeMap<String, Object?> _sortedMap(Map<String, Object?> input) {
  return SplayTreeMap<String, Object?>.of(input);
}
