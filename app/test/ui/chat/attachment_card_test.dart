import 'dart:async';
import 'dart:convert';

import 'package:app/domain/contracts/media_saver.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/attachment_card.dart';
import 'package:app/ui/chat/widgets/image_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 PNG — small enough to inline, real enough for `Image.memory` to accept.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Real PNGs: a 300×2400 phone screenshot (taller than the 220 px cap) and a
/// 400×100 strip (shorter than it), inline-able because they are 1-bit palette
/// files. The pair matters: the first reserves the cap, the second does not, so
/// a test can tell a reserved box from the fallback.
final _tallPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAASwAAAlgAQAAAAAaczeoAAAAcUlEQVR42u3BAQ0AAADCoPdP'
  'bQ8HFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwYba8AAaU4yKwAAAAA'
  'SUVORK5CYII=',
);
final _widePng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAZAAAABkAQAAAACAsFvaAAAAG0lEQVR42u3BAQ0AAADCoPdP'
  'bQ8HFAAAAADwYBPsAAEwqsp8AAAAAElFTkSuQmCC',
);

AttachmentMsg _card({
  String id = 'att_tc-1',
  String mime = 'image/png',
  String? blobName = 'att_tc-1.bin',
  String? note,
  bool resized = false,
  int? originalSize,
  String? error,
  String name = 'shot.png',
}) => AttachmentMsg(
  id: id,
  name: name,
  path: '/home/p/$name',
  mime: mime,
  size: 4096,
  note: note,
  resized: resized,
  originalSize: originalSize,
  blobName: blobName,
  error: error,
);

Future<void> _pump(
  WidgetTester tester,
  AttachmentMsg msg, {
  Map<String, Uint8List> blobs = const {},
  void Function(String id, String path)? onLoad,
  List<String>? saved,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AttachmentCard(
            message: msg,
            loadBytes: (name) async => blobs[name],
            onLoad: (id, path) async => onLoad?.call(id, path),
            onSave: (msg) async {
              saved?.add(msg.name);
              return 'Pictures/Remote Pi/${msg.name}';
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // The memo of image sizes is process-wide, and every test in this file reuses
  // the same blob name.
  setUp(ImageSizeCache.shared.clear);

  testWidgets('an image card renders inline and names the file', (tester) async {
    await _pump(tester, _card(), blobs: {'att_tc-1.bin': _png});

    expect(find.byKey(const Key('attachment-name')), findsOneWidget);
    expect(find.text('shot.png'), findsOneWidget);
    expect(find.textContaining('image/png'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const Key('attachment-load')), findsNothing);
  });

  testWidgets('a downscaled image says so instead of passing for the original', (
    tester,
  ) async {
    await _pump(
      tester,
      _card(resized: true, originalSize: 3 * 1024 * 1024),
      blobs: {'att_tc-1.bin': _png},
    );
    expect(find.textContaining('from 3.0 MB'), findsOneWidget);
  });

  testWidgets('the agent caption shows under the card', (tester) async {
    await _pump(
      tester,
      _card(note: 'the dashboard'),
      blobs: {'att_tc-1.bin': _png},
    );
    expect(find.text('the dashboard'), findsOneWidget);
  });

  testWidgets('a text file previews its content', (tester) async {
    await _pump(
      tester,
      _card(mime: 'text/markdown', name: 'notes.md', blobName: 'att_tc-1.bin'),
      blobs: {'att_tc-1.bin': Uint8List.fromList(utf8.encode('# notas\n- um\n- dois'))},
    );
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.textContaining('notas'), findsOneWidget);
    expect(find.byKey(const Key('attachment-load')), findsNothing);
  });

  testWidgets('a card with no bytes asks the Pi on tap — and only on tap', (
    tester,
  ) async {
    final asked = <String>[];
    await _pump(
      tester,
      _card(blobName: null),
      blobs: const {},
      onLoad: (id, path) => asked.add('$id|$path'),
    );

    // Nothing is pulled just because the card was built.
    expect(asked, isEmpty);
    expect(find.byKey(const Key('attachment-load')), findsOneWidget);
    expect(find.text('tap to load from the Pi'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attachment-load')));
    await tester.pump();
    expect(asked, ['att_tc-1|/home/p/shot.png']);
  });

  testWidgets('a cached blob that is gone degrades to the load affordance', (
    tester,
  ) async {
    // The record says there are bytes, the cache has none (pruned, or a
    // different install): the card must offer to fetch them again.
    await _pump(tester, _card(), blobs: const {});
    expect(find.byKey(const Key('attachment-load')), findsOneWidget);
  });

  testWidgets('an error replaces the preview and says why', (tester) async {
    await _pump(
      tester,
      _card(blobName: null, error: 'app.zip is binary'),
      blobs: const {},
    );
    expect(find.byKey(const Key('attachment-error')), findsOneWidget);
    expect(find.text('app.zip is binary'), findsOneWidget);
    expect(find.byKey(const Key('attachment-load')), findsNothing);
  });

  testWidgets('the path can be copied for use in a shell command', (tester) async {
    await _pump(tester, _card(), blobs: {'att_tc-1.bin': _png});
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.tap(find.byKey(const Key('attachment-copy-path')));
    await tester.pump();
    expect(copied, ['/home/p/shot.png']);
  });

  testWidgets('save writes the file and says where it went', (tester) async {
    final saved = <String>[];
    await _pump(
      tester,
      _card(),
      blobs: {'att_tc-1.bin': _png},
      saved: saved,
    );

    await tester.tap(find.byKey(const Key('attachment-save')));
    await tester.pump();

    expect(saved, ['shot.png']);
    expect(find.textContaining('Pictures/Remote Pi/shot.png'), findsOneWidget);
  });

  testWidgets('a save failure is reported, not swallowed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AttachmentCard(
              message: _card(),
              loadBytes: (name) async => _png,
              onLoad: (_, _) async {},
              onSave: (_) async =>
                  throw const MediaSaveException('missing_file', 'gone already'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('attachment-save')));
    await tester.pump();
    expect(find.text('gone already'), findsOneWidget);
  });

  testWidgets('a card with nothing to save offers no save button', (
    tester,
  ) async {
    await _pump(tester, _card(blobName: null), blobs: const {});
    expect(find.byKey(const Key('attachment-save')), findsNothing);
  });

  testWidgets('tapping the image opens the full-screen viewer', (tester) async {
    await _pump(tester, _card(), blobs: {'att_tc-1.bin': _png});

    await tester.tap(find.byKey(const Key('attachment-open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('viewer-save')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    // Back out of the viewer.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('viewer-save')), findsNothing);
  });

  testWidgets('a long text file offers "show all", which opens the viewer', (
    tester,
  ) async {
    await _pump(
      tester,
      _card(mime: 'text/plain', name: 'log.txt', blobName: 'att_tc-1.bin'),
      blobs: {
        'att_tc-1.bin': Uint8List.fromList(utf8.encode('line\n' * 400)),
      },
    );
    // The inline slice is a screenful, not the whole file.
    expect(find.text('show all'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('attachment-expand')));
    await tester.tap(find.byKey(const Key('attachment-expand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('viewer-save')), findsOneWidget);
  });

  group('the media area is decided before the bytes are', () {
    /// Pumps a card whose blob read is held open, then completes it.
    Future<void> pumpGated(
      WidgetTester tester,
      Completer<Uint8List?> gate,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AttachmentCard(
                message: _card(),
                loadBytes: (_) => gate.future,
                onLoad: (_, _) async {},
                onSave: (_) async => 'Pictures/Remote Pi/x.png',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    double frameHeight(WidgetTester tester) =>
        tester.getSize(find.byType(ImageFrame)).height;

    testWidgets('held open at the finished height, not the load row', (
      tester,
    ) async {
      final gate = Completer<Uint8List?>();
      await pumpGated(tester, gate);

      // Frame one: nothing read yet. It used to be the ~44 px "tap to load"
      // row, which grew to 220 px a frame later — the reflow that made the
      // transcript snap back under a scrolling finger.
      final loading = frameHeight(tester);
      expect(loading, AttachmentCard.maxImageHeight);

      gate.complete(_tallPng);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(frameHeight(tester), loading);
    });

    testWidgets('a size known from a previous pass is exact from frame one', (
      tester,
    ) async {
      // The card's own state does not survive leaving the viewport, so this is
      // what the second scroll past an image sees: the size is in the memo.
      ImageSizeCache.shared.remember('att_tc-1.bin', const ImageSize(400, 100));
      final gate = Completer<Uint8List?>();
      await pumpGated(tester, gate);

      // 400 px wide in an 800 px card: RenderImage takes its natural 100 px
      // height, not the 220 px cap. Reserving the cap would have been a 120 px
      // jump when the bytes landed.
      expect(frameHeight(tester), 100);

      gate.complete(_widePng);
      await tester.pump();
      await tester.pump();
      expect(frameHeight(tester), 100);
    });

    testWidgets('a card with nothing cached stays compact', (tester) async {
      // A metadata-only card from `session_history` has no bytes on disk to
      // hold a media area for; it must not reserve one.
      await _pump(tester, _card(blobName: null), blobs: const {});
      expect(
        tester.getSize(find.byType(AttachmentCard)).height,
        lessThan(120),
      );
    });
  });
}
