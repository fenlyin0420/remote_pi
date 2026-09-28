import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/attachments/attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rp_attach_store_');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  /// A real 1×1 PNG — enough for the app to decode and for a test to prove the
  /// bytes survived the round-trip intact.
  final pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  test('put/get round-trips the bytes and reports the blob name', () async {
    final store = AttachmentStore(dir);
    final name = await store.put('att_tc-1', pngBytes);
    expect(name, isNotNull);
    expect(await store.get(name!), orderedEquals(pngBytes));
    expect(await store.pathOf(name!), isNotNull);
  });

  test('the same id overwrites instead of piling up', () async {
    final store = AttachmentStore(dir);
    final first = await store.put('att_tc-1', pngBytes);
    final second = await store.put('att_tc-1', Uint8List.fromList([1, 2, 3]));
    expect(second, first);
    expect(await store.get(first!), orderedEquals([1, 2, 3]));
  });

  test('a wire id can never escape the attachments dir', () async {
    final store = AttachmentStore(dir);
    final name = await store.put('../../etc/passwd', pngBytes);
    expect(name, isNot(contains('/')));
    // A traversal attempt as a lookup is refused, not resolved.
    expect(await store.get('../secrets'), isNull);
    expect(await store.pathOf('../secrets'), isNull);
  });

  test('prune drops the oldest blobs past the cap', () async {
    // A 1 KB cap keeps the test small; the real one is 64 MB. 400 B × 2 = 800
    // fits, the third write trips the cap.
    final small = AttachmentStore(dir, maxTotalBytes: 1024);
    final old = await small.put('att_old', Uint8List(400));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final mid = await small.put('att_new', Uint8List(400));
    expect(await small.get(old!), isNotNull);

    final newest = await small.put('att_newest', Uint8List(400));
    // `put` fires the sweep without awaiting it (housekeeping must not delay a
    // card), so drive it explicitly here to assert on a settled directory.
    await small.prune();
    expect(await small.get(old!), isNull, reason: 'oldest goes first');
    expect(await small.get(mid!), isNotNull);
    expect(await small.get(newest!), isNotNull);
  });

  test('an old leftover .tmp is swept, a fresh one is left alone', () async {
    final store = AttachmentStore(dir);
    await store.put('att_tc-1', pngBytes);

    // Fresh: a write in flight right now — pruning must not eat it.
    final fresh = File('${dir.path}/att_inflight.0.tmp')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9, 9, 9]);
    // Old: a write that never completed. Backdate it past the stale window.
    final stale = File('${dir.path}/att_orphan.0.tmp')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9, 9, 9]);
    stale.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));

    await store.prune();
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('textPreview decodes UTF-8, strips the BOM and caps the length', () {
    expect(AttachmentStore.textPreview(Uint8List.fromList(utf8.encode('olá'))), 'olá');
    expect(
      AttachmentStore.textPreview(
        Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode('hi')]),
      ),
      'hi',
    );
    final long = AttachmentStore.textPreview(
      Uint8List.fromList(utf8.encode('x' * 100)),
      maxChars: 10,
    );
    expect(long, '${'x' * 10}\n…');
    // Binary is not text: no preview rather than mojibake.
    expect(AttachmentStore.textPreview(Uint8List.fromList([0xff, 0xfe, 0x00])), isNull);
  });
}
