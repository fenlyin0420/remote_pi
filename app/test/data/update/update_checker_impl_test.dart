// The update check reads two things in sequence: the release *feed* (atom, a
// plain web endpoint with no API rate limit) to find the newest release of
// this build's channel, and the *manifest* (latest.json) that release
// carries as an asset on GitHub's CDN.
//
// These tests drive the real Dio with the real transformer over a stub
// adapter that answers per URL, so channel selection, feed parsing, manifest
// decoding (both shapes Dio can hand back), cross-validation and the feed
// cache are tested end to end, not against a mock's mood.

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const String _feedUrl = 'http://update.test/releases.atom';

/// One canned answer: body, status, content-type.
class _Res {
  const _Res(this.body, this.status, this.contentType);

  final String body;
  final int status;
  final String contentType;
}

/// Answers per URL; counts hits so the cache tests can see what happened.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.responses, {this.errorType});

  /// URL → answer. A URL with no answer gets a 404.
  final Map<String, _Res> responses;

  /// When set, every request fails with this transport error instead.
  final DioExceptionType? errorType;

  final Map<String, int> _hitCounts = {};

  int hitsFor(String url) => _hitCounts[url] ?? 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    _hitCounts[url] = (_hitCounts[url] ?? 0) + 1;
    final type = errorType;
    if (type != null) {
      throw DioException(requestOptions: options, type: type);
    }
    final r =
        responses[url] ?? const _Res('', 404, 'text/plain; charset=utf-8');
    return ResponseBody.fromString(
      r.body,
      r.status,
      headers: {
        Headers.contentTypeHeader: [r.contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A minimal atom feed with one entry per tag, newest first.
String _feed(List<String> tags) => '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Remote Releases</title>
${tags.map(_entry).join('\n')}
</feed>
''';

String _entry(String tag) => '''
  <entry>
    <id>http://update.test/releases/tag/$tag</id>
    <link rel="alternate" href="http://update.test/releases/tag/$tag"/>
    <title>Remote Pi $tag</title>
    <content type="html">&lt;p&gt;notes&lt;/p&gt;</content>
  </entry>
''';

String _manifest(String version) => jsonEncode({
      'version': version,
      'date': '2026-10-13',
      'notes': '',
      'artifacts': [
        {
          'platform': 'android',
          'arch': 'universal',
          'format': 'apk',
          'url': 'http://example.com/$version.apk',
          'sha256': '',
          'size': 1,
        },
      ],
    });

/// The manifest of [tag], at the URL the checker builds for it.
_Res _manifestFor(String tag) => _Res(
      _manifest(tag.startsWith('v') ? tag.substring(1) : tag),
      200,
      'application/json; charset=utf-8',
    );

String manifestUrl(String tag) =>
    'http://update.test/releases/download/$tag/latest.json';

UpdateCheckerImpl _checker(
  _StubAdapter adapter, {
  bool beta = false,
  Duration feedCache = const Duration(minutes: 5),
}) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = adapter;
  return UpdateCheckerImpl(
    feedUrl: _feedUrl,
    betaChannel: beta,
    feedCache: feedCache,
    dio: dio,
  );
}

void main() {
  group('channel selection from the feed', () {
    test('prod picks the newest non-prerelease, skipping betas', () async {
      // The beta is NEWER and comes first — prod must not take it.
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31-beta.1', 'v1.5.31', 'v1.5.30']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.5.31');
      expect(adapter.hitsFor(manifestUrl('v1.5.31')), 1);
      expect(adapter.hitsFor(manifestUrl('v1.5.31-beta.1')), 0);
    });

    test('beta picks the newest -beta.N', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31-beta.1', 'v1.5.31', 'v1.5.30']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31-beta.1'): _manifestFor('v1.5.31-beta.1'),
      });
      final query = await _checker(adapter, beta: true).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.5.31-beta.1');
    });

    test('beta is never offered to prod as "newer"', () async {
      // Only betas exist yet: prod has no release of its own in the feed.
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31-beta.2', 'v1.5.31-beta.1']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail,
          contains('no prod release'));
    });

    test('prod is never offered to beta', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31', 'v1.5.30']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
      });
      final query = await _checker(adapter, beta: true).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail,
          contains('no beta release'));
    });

    test('legacy descriptive tags are skipped — the first conforming tag wins',
        () async {
      // This repo's old releases are tagged descriptively (a suffix after
      // the version) and carry no latest.json asset: the parser must skip
      // them instead of half-parsing v1.5.30-model-display-arm64 as
      // v1.5.30 and reporting "Could not reach".
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed([
            'v1.5.30-model-display-arm64',
            'v1.5.29-message-meta-arm64',
            'v1.5.31',
          ]),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.5.31');
    });

    test('a feed of only legacy tags says "no release", not a crash', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed([
            'v1.5.30-model-display-arm64',
            'v1.5.29-message-meta-arm64',
          ]),
          200,
          'application/atom+xml; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail,
          contains('no prod release'));
    });

    test('an empty feed (or a captive portal) is unreadable, not silent',
        () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          '<html><body>Sign in to the network</body></html>',
          200,
          'text/html; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail,
          contains('no prod release'));
    });
  });

  group('the manifest', () {
    _StubAdapter adapterFor(String contentType) => _StubAdapter({
          _feedUrl: _Res(
            _feed(['v1.5.31']),
            200,
            'application/atom+xml; charset=utf-8',
          ),
          manifestUrl('v1.5.31'): _Res(
            _manifest('1.5.31'),
            200,
            contentType,
          ),
        });

    test('a manifest that arrives decoded (JSON content-type)', () async {
      // Dio hands a JSON content-type body back as a Map, not a String:
      // the shape the four-release bug threw away.
      final query = await _checker(
        adapterFor('application/json; charset=utf-8'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.5.31');
      expect(query.info.artifacts, hasLength(1));
    });

    test('a manifest that arrives as a String (text content-type)', () async {
      // The CDN serves release assets as text/plain — the shape the CDN
      // actually sends.
      final query = await _checker(
        adapterFor('text/plain; charset=utf-8'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.5.31');
    });

    test('a missing manifest is unreachable, naming the manifest', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail,
          'HTTP 404 (release manifest)');
    });

    test('an HTML manifest is unreadable', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _Res(
          '<html><body>oops</body></html>',
          200,
          'text/html; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail, contains('not JSON'));
    });

    test('a manifest that disagrees with its tag is a publishing bug',
        () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31-beta.1']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        // CI would generate the manifest from the same tag; if it does not
        // agree, the release is broken and must be surfaced, not installed.
        manifestUrl('v1.5.31-beta.1'): _Res(
          _manifest('1.5.31'),
          200,
          'text/plain; charset=utf-8',
        ),
      });
      final query = await _checker(adapter, beta: true).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail, contains('1.5.31'));
      expect(query.detail, contains('1.5.31-beta.1'));
    });

    test('a manifest that is JSON but not an object is unreadable', () async {
      // The CDN serves assets as text/plain, so Dio hands the body back as
      // a String: jsonDecode('[1,2,3]') succeeds and the old `as Map` cast
      // threw a TypeError the UI never caught, stranding it on "Checking…".
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _Res(
          '[1,2,3]',
          200,
          'text/plain; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail, 'not a manifest');
    });

    test('a manifest without a version is unreadable', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _Res(
          '{"hello":"world"}',
          200,
          'application/json; charset=utf-8',
        ),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
    });
  });

  group('feed failures', () {
    test('a non-2xx feed is unreachable, with the code', () async {
      final adapter = _StubAdapter({
        _feedUrl: const _Res('not found', 404, 'text/plain'),
      });
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail, 'HTTP 404 (update feed)');
    });

    test('a transport failure is unreachable, with the reason', () async {
      final adapter = _StubAdapter(
        {},
        errorType: DioExceptionType.connectionError,
      );
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail,
          'connection error (update feed)');
    });

    test('a timeout is unreachable, and names the timeout', () async {
      final adapter = _StubAdapter(
        {},
        errorType: DioExceptionType.connectionTimeout,
      );
      final query = await _checker(adapter).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail,
          contains('timeout (update feed)'));
    });
  });

  group('the feed cache', () {
    test('a second check within the window touches no network', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final checker = _checker(adapter);
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      final hits = adapter.hitsFor(_feedUrl);
      expect(hits, 1);
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      expect(adapter.hitsFor(_feedUrl), 1);
    });

    test('force bypasses the cache', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final checker = _checker(adapter);
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      expect(await checker.fetchLatest(force: true), isA<UpdateQueryOk>());
      expect(adapter.hitsFor(_feedUrl), 2);
    });

    test('an expired window re-queries', () async {
      final adapter = _StubAdapter({
        _feedUrl: _Res(
          _feed(['v1.5.31']),
          200,
          'application/atom+xml; charset=utf-8',
        ),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final checker = _checker(adapter, feedCache: Duration.zero);
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      expect(adapter.hitsFor(_feedUrl), 2);
    });

    test('a failure is never cached — the next check re-queries', () async {
      final adapter = _StubAdapter({
        _feedUrl: const _Res('', 404, 'text/plain'),
        manifestUrl('v1.5.31'): _manifestFor('v1.5.31'),
      });
      final checker = _checker(adapter);
      expect(await checker.fetchLatest(), isA<UpdateQueryUnreachable>());
      // The release landed in the meantime.
      adapter.responses[_feedUrl] = _Res(
        _feed(['v1.5.31']),
        200,
        'application/atom+xml; charset=utf-8',
      );
      expect(await checker.fetchLatest(), isA<UpdateQueryOk>());
      expect(adapter.hitsFor(_feedUrl), 2);
    });
  });
}
