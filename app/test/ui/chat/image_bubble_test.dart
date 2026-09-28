// Plan/30 — ImageBubble renders a static thumbnail from base64 + optional
// caption, with a broken-image fallback for bad data.
//
// The other half is layout: the bubble's box is reserved from the picture's
// header, so its height on the frame the decode lands is the height it had on
// the frame before (see `image_frame.dart` for what a row that grows mid-scroll
// does to a scrolling finger).

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1×1 PNG — the engine can actually decode this one, which matters: a fixture
// it rejects surfaces as an `ErrorWidget` whenever the (real, async) decode
// happens to complete inside a test, and takes `find.byType(Image)` with it.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==';

// Real PNGs: 300×2400 (a phone screenshot) and 400×100 (wide and short). They
// inline small because they are 1-bit palette files.
const _tall =
    'iVBORw0KGgoAAAANSUhEUgAAASwAAAlgAQAAAAAaczeoAAAAcUlEQVR42u3BAQ0AAADCoPdP'
    'bQ8HFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwYba8AAaU4yKwAAAAA'
    'SUVORK5CYII=';
const _wide =
    'iVBORw0KGgoAAAANSUhEUgAAAZAAAABkAQAAAACAsFvaAAAAG0lEQVR42u3BAQ0AAADCoPdP'
    'bQ8HFAAAAADwYBPsAAEwqsp8AAAAAElFTkSuQmCC';

void main() {
  Future<void> pump(WidgetTester tester, MessageImage image, String caption) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // The bubble lives in a 300 pt column in the chat (see
            // `message_bubble.dart`); the frame's arithmetic depends on it.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: ImageBubble(image: image, caption: caption),
            ),
          ),
        ),
      ),
    );
  }

  double imageHeight(WidgetTester tester) =>
      tester.getSize(find.byType(Image)).height;

  testWidgets('renders the image and the caption', (tester) async {
    await pump(
      tester,
      const MessageImage(data: _png, mime: 'image/jpeg'),
      'a kitten',
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('a kitten'), findsOneWidget);
  });

  testWidgets('renders without a caption when empty', (tester) async {
    await pump(tester, const MessageImage(data: _png, mime: 'image/jpeg'), '');
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('falls back to a broken-image glyph on bad base64', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(data: 'not valid base64 !!', mime: 'image/jpeg'),
      '',
    );
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a screenshot is capped before its bitmap exists', (
    tester,
  ) async {
    // 300×2400: taller than the cap, so the box is 300×220 — and it is that
    // tall on the first pump, before anything is decoded.
    await pump(tester, const MessageImage(data: _tall, mime: 'image/png'), '');
    expect(imageHeight(tester), ImageBubble.maxHeight);
    await tester.pump();
    expect(imageHeight(tester), ImageBubble.maxHeight);
  });

  testWidgets('a wide picture is reserved at its own height, not the cap', (
    tester,
  ) async {
    // 400×100 in a 300 pt row → 75 pt tall, which is exactly the box `Image`
    // would have chosen for itself once decoded.
    await pump(tester, const MessageImage(data: _wide, mime: 'image/png'), '');
    expect(imageHeight(tester), closeTo(75, 0.01));
  });

  testWidgets('the same payload is decoded once, not once per row', (
    tester,
  ) async {
    // A row is thrown away when it scrolls out of view, so the bytes have to
    // come from somewhere shared — otherwise every pass re-decodes the picture
    // *and* hands Flutter's image cache a key it can never hit.
    await pump(tester, const MessageImage(data: _tall, mime: 'image/png'), '');
    final first = tester.widget<Image>(find.byType(Image));

    await tester.pumpWidget(const SizedBox());
    await pump(tester, const MessageImage(data: _tall, mime: 'image/png'), '');
    final second = tester.widget<Image>(find.byType(Image));

    // (`Image.memory` wraps the bytes in a ResizeImage once it is given a
    // decoded-width hint, so unwrap to the payload before comparing.)
    final firstBytes = _payload(first.image);
    final secondBytes = _payload(second.image);
    expect(
      identical(firstBytes, secondBytes),
      isTrue,
      reason: 'the byte list identity is what Flutter\'s image cache keys on',
    );
  });

  testWidgets('the bitmap is decoded at display size, not photo size', (
    tester,
  ) async {
    await pump(tester, const MessageImage(data: _tall, mime: 'image/png'), '');
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    expect(
      (provider as ResizeImage).width,
      (300 * tester.view.devicePixelRatio).round(),
    );
  });

  test('the fixtures say what the layout tests assume', () {
    expect(probeImageSize(base64Decode(_tall)), const ImageSize(300, 2400));
    expect(probeImageSize(base64Decode(_wide)), const ImageSize(400, 100));
  });
}

Uint8List _payload(ImageProvider provider) =>
    ((provider as ResizeImage).imageProvider as MemoryImage).bytes;
