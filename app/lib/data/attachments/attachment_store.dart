import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Local cache for the bytes of the files the Pi sent to the phone.
///
/// The bytes never go into the message record: a 2 MB base64 string inside a
/// Hive row would be decoded into memory every time the room is read (and the
/// chat list holds the whole room), so a few attachments would be enough to
/// make scrolling stutter. Records store the file NAME (see
/// `MessageRecord.attachment.blob`) and this store owns the bytes.
///
/// The dir lives next to the Hive boxes (the app's private data dir), so no
/// platform channel and no storage permission is involved — the same reason
/// the app keeps its other caches there.
class AttachmentStore {
  /// Subdirectory of the boxes dir holding the blobs.
  static const String dirName = 'attachments';

  /// Default soft cap on the whole cache. A screenshot is ~200 KB, so this is
  /// a few dozen files; past it the oldest go. Without a cap the app would
  /// grow silently until the user cleared app data.
  static const int defaultMaxBytes = 64 * 1024 * 1024;

  /// A scratch file older than this is a leftover, not a write in progress.
  static const Duration _staleTmpAge = Duration(hours: 1);

  /// Distinguishes concurrent scratch files (see [put]).
  static int _writeSeq = 0;

  /// Serialises the housekeeping sweeps (see [prune]).
  Future<void> _pruneChain = Future<void>.value();

  final Directory root;

  /// Soft cap on the cache. Overridable so a test can exercise the sweep
  /// without writing 64 MB.
  final int maxTotalBytes;

  AttachmentStore(this.root, {this.maxTotalBytes = AttachmentStore.defaultMaxBytes});

  /// Where [box] lives, with `dirName` under it. Hive's box path is
  /// `<dataDir>/<name>.hive`, so the parent is the app's data dir.
  factory AttachmentStore.forBox(String boxPath) {
    final parent = File(boxPath).parent;
    return AttachmentStore(Directory('${parent.path}/$dirName'));
  }

  Directory get _dir => root;

  /// Store [bytes] for [attachmentId] and return the blob name to persist.
  ///
  /// Best-effort on the filesystem side: a failure returns null instead of
  /// throwing, because the card is still worth showing (name, size, path) even
  /// when the bytes could not be cached.
  Future<String?> put(String attachmentId, Uint8List bytes) async {
    final name = _blobName(attachmentId);
    try {
      await _dir.create(recursive: true);
      // Write to a per-write temp name and rename, so a crash mid-write can
      // never leave a half-written blob that would decode into a broken image
      // later. The name is unique per write so two concurrent writes of
      // DIFFERENT ids (or of the same one) can't share a scratch file.
      final tmp = File('${_dir.path}/$name.${_writeSeq++}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${_dir.path}/$name');
    } catch (_) {
      return null;
    }
    // ignore: discarded_futures
    unawaited(prune());
    return name;
  }

  /// The cached bytes for [blobName], or null when absent/unreadable.
  Future<Uint8List?> get(String blobName) async {
    if (blobName.isEmpty || blobName.contains('/') || blobName.contains('\\')) {
      return null;
    }
    try {
      final f = File('${_dir.path}/$blobName');
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Absolute path of a blob, for a caller that wants a real file (the native
  /// side of a future "open with…" action). Null when it isn't there.
  Future<String?> pathOf(String blobName) async {
    if (blobName.isEmpty || blobName.contains('/') || blobName.contains('\\')) {
      return null;
    }
    final p = '${_dir.path}/$blobName';
    return await File(p).exists() ? p : null;
  }

  Future<void> delete(String blobName) async {
    if (blobName.isEmpty || blobName.contains('/')) return;
    try {
      await File('${_dir.path}/$blobName').delete();
    } catch (_) {
      // Already gone.
    }
  }

  /// Delete oldest-first until the cache fits [maxTotalBytes].
  ///
  /// Sweeps are serialised: several cards can land at once, and two sweeps
  /// reading the same directory would each plan a deletion from the same total
  /// (the second deleting a file the first already removed, then aborting on
  /// the vanished entry). One at a time, each seeing a settled directory.
  Future<void> prune() {
    _pruneChain = _pruneChain.then((_) => _sweep()).catchError((Object _) {});
    return _pruneChain;
  }

  Future<void> _sweep() async {
    try {
      if (!await _dir.exists()) return;
      final files = <File>[];
      var total = 0;
      final staleBefore = DateTime.now().subtract(_staleTmpAge);
      await for (final entity in _dir.list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.tmp')) {
          // A leftover from a write that never completed. Only old ones: a
          // concurrent `put` is mid-flight right now and its scratch file is
          // about to be renamed into place.
          try {
            if (entity.statSync().modified.isBefore(staleBefore)) {
              await entity.delete();
            }
          } catch (_) {}
          continue;
        }
        try {
          total += await entity.length();
          files.add(entity);
        } catch (_) {
          // Vanished between listing and stat — nothing to account for.
        }
      }
      if (total <= maxTotalBytes) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final f in files) {
        if (total <= maxTotalBytes) break;
        try {
          final len = await f.length();
          await f.delete();
          total -= len;
        } catch (_) {
          // Keep going: one undeletable file must not stop the sweep.
        }
      }
    } catch (_) {
      // Pruning is housekeeping; never let it surface.
    }
  }

  /// Blob name for an attachment id: `att_<safe id>`. The id comes off the
  /// wire, so it is reduced to a single safe path segment.
  static String _blobName(String attachmentId) {
    final safe = attachmentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final stem = safe.isEmpty ? 'file' : safe;
    return '${stem.length > 80 ? stem.substring(0, 80) : stem}.bin';
  }

  /// Text preview of a text file, capped so a 1 MB file can't be handed to a
  /// Text widget whole. Null when the bytes are not decodable text.
  ///
  /// Mirrors the Pi's own text rule (a BOM decides the encoding, a NUL byte
  /// means binary), so a card never renders mojibake for something the Pi
  /// accepted as text.
  static String? textPreview(Uint8List bytes, {int maxChars = 4000}) {
    try {
      final body = bytes;
      String? text;
      if (body.length >= 2 && body[0] == 0xff && body[1] == 0xfe) {
        text = _decodeUtf16(body.sublist(2), littleEndian: true);
      } else if (body.length >= 2 && body[0] == 0xfe && body[1] == 0xff) {
        text = _decodeUtf16(body.sublist(2), littleEndian: false);
      } else if (!body.contains(0)) {
        final stripped = body.length >= 3 &&
                body[0] == 0xef &&
                body[1] == 0xbb &&
                body[2] == 0xbf
            ? body.sublist(3)
            : body;
        text = const Utf8Decoder(allowMalformed: false).convert(stripped);
      }
      if (text == null) return null;
      return text.length > maxChars ? '${text.substring(0, maxChars)}\n…' : text;
    } catch (_) {
      return null;
    }
  }

  /// UTF-16 → String, BOM already stripped. `dart:convert` has no UTF-16
  /// decoder, and a mislabelled binary must not decode into plausible-looking
  /// mojibake, so a truncated or unpaired surrogate rejects the whole thing.
  static String? _decodeUtf16(Uint8List body, {required bool littleEndian}) {
    if (body.length % 2 != 0) return null;
    final out = StringBuffer();
    for (var i = 0; i < body.length; i += 2) {
      final unit = littleEndian
          ? body[i] | (body[i + 1] << 8)
          : (body[i] << 8) | body[i + 1];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (i + 2 >= body.length) return null;
        final low = littleEndian
            ? body[i + 2] | (body[i + 3] << 8)
            : (body[i + 2] << 8) | body[i + 3];
        if (low < 0xdc00 || low > 0xdfff) return null;
        i += 2;
        out.writeCharCode(0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00));
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return null; // unpaired low surrogate
      } else {
        out.writeCharCode(unit);
      }
    }
    return out.toString();
  }
}
