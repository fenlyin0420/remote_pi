// Per-room composer drafts (DraftStore over the durable `drafts` box).

import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rp_v2_drafts_');
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  DraftStore makeStore() {
    return DraftStore(LocalBoxes());
  }

  group('DraftStore', () {
    test('read of a fresh room returns null', () async {
      await LocalBoxes.initForTest(dir.path);
      expect(makeStore().read('epk1', 'main'), isNull);
    });

    test('save then read round-trips the verbatim text', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save('epk1', 'main', '  half-typed message\nline two');
      expect(
        store.read('epk1', 'main'),
        '  half-typed message\nline two',
        reason: 'drafts keep the text verbatim (spaces and newlines)',
      );
    });

    test('save with empty text deletes the draft', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save('epk1', 'main', 'sent later');
      expect(store.read('epk1', 'main'), isNotNull);
      await store.save('epk1', 'main', '   ');
      expect(
        store.read('epk1', 'main'),
        isNull,
        reason: 'a cleared composer must leave nothing to re-hydrate',
      );
    });

    test('drafts are keyed per (peer, room)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save('epk1', 'main', 'draft A');
      await store.save('epk1', 'other', 'draft B');
      await store.save('epk2', 'main', 'draft C');
      expect(store.read('epk1', 'main'), 'draft A');
      expect(store.read('epk1', 'other'), 'draft B');
      expect(store.read('epk2', 'main'), 'draft C');
    });

    test('drafts survive a simulated restart (durable box)', () async {
      await LocalBoxes.initForTest(dir.path);
      await makeStore().save('epk1', 'main', 'still here');
      // "Restart": re-init wipes volatile boxes only — drafts must persist.
      await LocalBoxes.initForTest(dir.path);
      expect(makeStore().read('epk1', 'main'), 'still here');
    });
  });
}
