import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show PlatformException;

/// Picks one text file from the device and reads it (bounded) into a string.
///
/// Text-ness is decided from the **content**, never from the name: a file is
/// text when its bytes are characters — no NUL byte and decodable as UTF-8
/// (BOM optional) or UTF-16 (BOM required). `Makefile`, `id_rsa.pub`, a `.log`,
/// a `Dockerfile` or a `.gitignore` all qualify; a `.txt` full of binary does
/// not. The picker itself is unrestricted (`FileType.any`), so an extension
/// allow-list is never involved.
abstract class ITextFilePickerService {
  /// Returns the picked file's text, or null when the user cancelled. Throws
  /// [NotTextFileException] when the picked file is not character data.
  Future<PickedTextFile?> pickTextFile();
}

/// A picked file whose bytes decoded as text, ready for preview and sending.
class PickedTextFile {
  /// File name as picked (leaf only, no directories).
  final String name;

  /// Decoded content. UTF-16 sources are re-encoded as UTF-8.
  final String text;

  /// Size of what was read (after the cap), in bytes.
  final int byteLength;

  /// The source was longer than [TextFilePickerService.maxBytes] and was cut
  /// at the cap; [text] ends with an explicit marker for the agent.
  final bool truncated;

  const PickedTextFile({
    required this.name,
    required this.text,
    required this.byteLength,
    this.truncated = false,
  });
}

/// Thrown when the picked file is not character data (see the class docs).
class NotTextFileException implements Exception {
  final String name;
  const NotTextFileException(this.name);

  @override
  String toString() => 'NotTextFileException($name)';
}

class TextFilePickerService implements ITextFilePickerService {
  TextFilePickerService([TextFilePickerBackend? backend])
    : _backend = backend ?? PlatformTextFilePickerBackend();

  final TextFilePickerBackend _backend;

  /// Longest upload accepted. The file travels inline — UTF-8 JSON inside the
  /// relay's ~4 MiB frame budget — so this stays well clear of it (and of what
  /// a phone should hold in memory). Longer files are cut here and marked.
  static const int maxBytes = 256 * 1024;

  /// Appended to [PickedTextFile.text] when the cap cut the file, so the agent
  /// is never silently handed half of a file.
  static const String truncationMarker =
      '\n…[truncated: only the first 256 KB of this file is included]';

  @override
  Future<PickedTextFile?> pickTextFile() async {
    final source = await _backend.pick();
    if (source == null) return null; // user cancelled
    if (source.path == null && source.bytes == null) {
      // The platform reported a pick but handed over nothing to read.
      throw PlatformException(
        code: 'unreadable',
        message: 'No path or bytes for the picked file',
      );
    }
    final read = _readBounded(source);
    final decoded = decodeText(read.bytes, truncated: read.truncated);
    if (decoded == null) throw NotTextFileException(source.name);
    return PickedTextFile(
      name: source.name,
      text: read.truncated ? '$decoded$truncationMarker' : decoded,
      byteLength: read.bytes.length,
      truncated: read.truncated,
    );
  }

  /// Reads at most [maxBytes] from the picked source, reporting whether the
  /// source had more. Reads through the path when there is one so an oversized
  /// file is never materialised in full.
  static ({Uint8List bytes, bool truncated}) _readBounded(
    PickedSource source,
  ) {
    final path = source.path;
    if (path != null) {
      final file = File(path);
      int length;
      try {
        length = file.lengthSync();
      } catch (_) {
        length = -1; // unreadable metadata → read blind and let the read cap
      }
      final limit = length >= 0 && length < maxBytes ? length : maxBytes;
      final handle = file.openSync();
      try {
        final bytes = handle.readSync(limit);
        return (bytes: bytes, truncated: length < 0 || length > limit);
      } finally {
        handle.closeSync();
      }
    }
    final inMemory = source.bytes ?? Uint8List(0);
    if (inMemory.length <= maxBytes) {
      return (bytes: inMemory, truncated: false);
    }
    return (
      bytes: Uint8List.sublistView(inMemory, 0, maxBytes),
      truncated: true,
    );
  }

  /// The acceptance rule, on bytes alone. Returns null when [bytes] are not
  /// character data.
  ///
  /// A UTF-8 or UTF-16 BOM short-circuits the NUL test (both encodings put
  /// NUL bytes in otherwise plain text — UTF-16 does so on every ASCII char).
  /// [truncated] lets a cut tail — which can split a multi-byte sequence —
  /// back off up to three bytes instead of condemning the file.
  static String? decodeText(Uint8List bytes, {bool truncated = false}) {
    if (bytes.isEmpty) return '';

    if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
      return _utf8(Uint8List.sublistView(bytes, 3), truncated: truncated);
    }
    if (_startsWith(bytes, const [0xFF, 0xFE])) {
      return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: true);
    }
    if (_startsWith(bytes, const [0xFE, 0xFF])) {
      return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: false);
    }

    // A NUL byte is the classic binary tell and is never valid in UTF-8 text.
    if (bytes.contains(0)) return null;
    return _utf8(bytes, truncated: truncated);
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static String? _utf8(Uint8List bytes, {required bool truncated}) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      if (!truncated) return null;
      // The tail we cut may have split a 2–4 byte sequence: retry without it.
      for (var cut = 1; cut <= 3 && cut < bytes.length; cut++) {
        try {
          return utf8.decode(Uint8List.sublistView(bytes, 0, bytes.length - cut));
        } on FormatException {
          continue;
        }
      }
      return null;
    }
  }

  static String _utf16(Uint8List bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
}

// ---------------------------------------------------------------------------
// Backend seam
// ---------------------------------------------------------------------------

/// A picked file that has not been read yet: a path when the platform hands
/// one over (mobile caches the pick), or bytes when it can only hand those.
class PickedSource {
  /// Leaf name as reported by the platform picker.
  final String name;
  final String? path;
  final Uint8List? bytes;

  const PickedSource({required this.name, this.path, this.bytes});
}

/// Thin seam over `file_picker` so pick + sniff + cap are unit-testable
/// without a device.
abstract class TextFilePickerBackend {
  /// Pick one file, unrestricted. Returns null when the user cancelled.
  Future<PickedSource?> pick();
}

class PlatformTextFilePickerBackend implements TextFilePickerBackend {
  PlatformTextFilePickerBackend();

  @override
  Future<PickedSource?> pick() async {
    try {
      // `FileType.any` + no `allowedExtensions`: the OS picker must not filter
      // by name. What counts as a text file is decided from the bytes.
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        withData: false,
        allowMultiple: false,
      );
      final picked = (result == null || result.files.isEmpty)
          ? null
          : result.files.first;
      if (picked == null) return null;
      // `withData: false` keeps an oversized pick out of memory; the service
      // then reads a bounded slice through `path`.
      return PickedSource(name: picked.name, path: picked.path, bytes: picked.bytes);
    } on PlatformException {
      rethrow;
    }
  }
}
