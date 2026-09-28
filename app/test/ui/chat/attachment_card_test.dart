import 'dart:convert';

import 'package:app/domain/contracts/media_saver.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/attachment_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 PNG — small enough to inline, real enough for `Image.memory` to accept.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
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
}
