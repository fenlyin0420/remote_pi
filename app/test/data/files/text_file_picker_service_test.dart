// TextFilePickerService — the content-based text rule, the size cap and the
// read path, through the backend seam (no plugins / device).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/files/text_file_picker_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements TextFilePickerBackend {
  PickedSource? next;

  @override
  Future<PickedSource?> pick() async => next;
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('decodeText — content decides, never the name', () {
    test('plain UTF-8, including multi-byte characters', () {
      expect(TextFilePickerService.decodeText(_bytes('hello\nworld')), 'hello\nworld');
      expect(TextFilePickerService.decodeText(_bytes('# 中文标题\nok')), '# 中文标题\nok');
    });

    test('no extension needed: a Makefile / .gitignore / extensionless config', () {
      for (final name in ['Makefile', '.gitignore', 'id_rsa.pub', 'notes.md', 'x.csv']) {
        expect(
          TextFilePickerService.decodeText(_bytes('name: $name\n')),
          'name: $name\n',
        );
      }
    });

    test('a NUL byte means binary — even under a .txt name', () {
      expect(TextFilePickerService.decodeText(Uint8List.fromList([104, 105, 0, 1])), isNull);
    });

    test('a PNG header is binary; an empty file is vacuously text', () {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]);
      expect(TextFilePickerService.decodeText(png), isNull);
      expect(TextFilePickerService.decodeText(Uint8List(0)), '');
    });

    test('invalid UTF-8 without a NUL is still refused (not silently mangled)', () {
      expect(TextFilePickerService.decodeText(Uint8List.fromList([0xC3, 0x28, 0x41])), isNull);
    });

    test('BOMs: UTF-8 is stripped, UTF-16 (either order) becomes UTF-8', () {
      final utf8Bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ..._bytes('hi')]);
      expect(TextFilePickerService.decodeText(utf8Bom), 'hi');

      final le = Uint8List.fromList([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]);
      expect(TextFilePickerService.decodeText(le), 'hi');

      final be = Uint8List.fromList([0xFE, 0xFF, 0x00, 0x68, 0x00, 0x69]);
      expect(TextFilePickerService.decodeText(be), 'hi');
    });

    test('a cut multi-byte tail is backed off instead of rejecting the file', () {
      // "中" = E4 B8 AD, cut to its first two bytes.
      final cut = Uint8List.fromList([0x61, 0xE4, 0xB8]);
      expect(TextFilePickerService.decodeText(cut, truncated: false), isNull);
      expect(TextFilePickerService.decodeText(cut, truncated: true), 'a');
    });
  });

  test('a picked file comes back decoded with its name, size and no marker', () async {
    final dir = Directory.systemTemp.createTempSync('text-picker-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/server.log')..writeAsStringSync('line1\nline2\n');

    final backend = _FakeBackend()..next = PickedSource(name: 'server.log', path: file.path);
    final picked = await TextFilePickerService(backend).pickTextFile();

    expect(picked, isNotNull);
    expect(picked!.name, 'server.log');
    expect(picked.text, 'line1\nline2\n');
    expect(picked.byteLength, 12);
    expect(picked.truncated, isFalse);
  });

  test('a cancelled pick returns null; a binary pick throws NotTextFileException', () async {
    final backend = _FakeBackend();
    expect(await TextFilePickerService(backend).pickTextFile(), isNull);

    backend.next = PickedSource(name: 'photo.jpg', bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x00]));
    await expectLater(
      TextFilePickerService(backend).pickTextFile(),
      throwsA(isA<NotTextFileException>()),
    );
  });

  test('an oversized file is cut at the cap, flagged, and marks the content', () async {
    final dir = Directory.systemTemp.createTempSync('text-picker-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final big = List.filled(TextFilePickerService.maxBytes + 5000, 0x61); // 'a'
    final file = File('${dir.path}/big.log')..writeAsBytesSync(big);

    final backend = _FakeBackend()..next = PickedSource(name: 'big.log', path: file.path);
    final picked = await TextFilePickerService(backend).pickTextFile();

    expect(picked!.truncated, isTrue);
    expect(picked.byteLength, TextFilePickerService.maxBytes);
    expect(picked.text.endsWith(TextFilePickerService.truncationMarker), isTrue);
    expect(picked.text.length, greaterThan(TextFilePickerService.maxBytes));
  });
}
