// The reserved image box — the arithmetic that keeps a row's height final
// before its bitmap exists, and the memo that keeps it final on the way back.

import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/image_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  ImageSize? size, {
  double available = 300,
  double maxHeight = 220,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: available,
            child: ImageFrame(
              size: size,
              maxHeight: maxHeight,
              builder: (context, cacheWidth) => ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a picture taller than the cap is capped', (tester) async {
    await _pump(tester, const ImageSize(300, 2400));
    expect(tester.getSize(find.byType(ImageFrame)), const Size(300, 220));
  });

  testWidgets('a picture wider than the row keeps its ratio', (tester) async {
    // 400×100 in a 300-wide row: RenderImage would fit it to 300×75, so that is
    // the box reserved — not the 220 px cap, which would crop it.
    await _pump(tester, const ImageSize(400, 100));
    expect(tester.getSize(find.byType(ImageFrame)), const Size(300, 75));
  });

  testWidgets('a picture narrower than the row keeps its natural height', (
    tester,
  ) async {
    // Same arithmetic as RenderImage under a tight width: a small image is
    // stretched sideways, not scaled up to the cap.
    await _pump(tester, const ImageSize(120, 90), available: 800);
    expect(tester.getSize(find.byType(ImageFrame)), const Size(800, 90));
  });

  testWidgets('an unreadable header still reserves a fixed box', (
    tester,
  ) async {
    await _pump(tester, null);
    expect(tester.getSize(find.byType(ImageFrame)), const Size(300, 220));
  });

  testWidgets('the box is final on the first frame', (tester) async {
    await _pump(tester, const ImageSize(1600, 900), available: 328);
    final first = tester.getSize(find.byType(ImageFrame));
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(find.byType(ImageFrame)), first);
    // 328 × (900/1600) = 184.5
    expect(first.height, closeTo(184.5, 0.01));
  });

  testWidgets('the bitmap is decoded at display size, not full size', (
    tester,
  ) async {
    int? asked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: ImageFrame(
                size: const ImageSize(1568, 2090),
                builder: (context, cacheWidth) {
                  asked = cacheWidth;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      asked,
      (300 * tester.view.devicePixelRatio).round(),
      reason: 'a 1568 px photo does not need a 1568 px bitmap in a 300 pt row',
    );
  });

  group('ImageSizeCache', () {
    test('remembers what it was told, misses what it was not', () {
      final cache = ImageSizeCache();
      expect(cache.sizeOf('a'), isNull);
      cache.remember('a', const ImageSize(10, 20));
      expect(cache.sizeOf('a'), const ImageSize(10, 20));
    });

    test('an unreadable header is remembered as a miss, not re-parsed', () {
      final cache = ImageSizeCache();
      cache.remember('a', null);
      expect(cache.sizeOf('a'), isNull);
      cache.remember('a', const ImageSize(10, 20));
      expect(cache.sizeOf('a'), const ImageSize(10, 20));
    });

    test('drops the oldest entry past its bound', () {
      final cache = ImageSizeCache(maxEntries: 2);
      cache.remember('a', const ImageSize(1, 1));
      cache.remember('b', const ImageSize(2, 2));
      cache.remember('c', const ImageSize(3, 3));
      expect(cache.sizeOf('a'), isNull);
      expect(cache.sizeOf('c'), const ImageSize(3, 3));
    });

    test('clear empties it, so a test never inherits another one', () {
      final cache = ImageSizeCache()..remember('a', const ImageSize(1, 1));
      cache.clear();
      expect(cache.sizeOf('a'), isNull);
    });
  });
}
