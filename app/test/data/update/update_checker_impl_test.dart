// The update check has exactly one job: read a small JSON document. For four
// releases it did not, and nothing said so — `ResponseType.plain` set on
// `BaseOptions` is ignored by Dio 5's `get`/`getUri` helpers (the per-call
// config defaults to `ResponseType.json` and wins), so an `application/json`
// body arrives **already decoded as a Map** while the code required a String.
// Every check therefore answered "no update", which is indistinguishable from
// a correct answer until someone notices the notice never appears.
//
// These tests drive the real Dio with the real transformer over a stub
// adapter, so they fail on exactly that mistake rather than on a mock's mood.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/update/update_checker_impl.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers with a canned body; no socket involved.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(
    this.body, {
    this.status = 200,
    this.contentType = 'application/json; charset=utf-8',
    this.errorType,
  });

  final String body;
  final int status;
  final String contentType;

  /// When set, the request fails instead of answering.
  final DioExceptionType? errorType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final type = errorType;
    if (type != null) {
      throw DioException(requestOptions: options, type: type);
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

UpdateCheckerImpl _checker(_StubAdapter adapter) {
  // Same BaseOptions the real checker builds: the point of this file is that
  // the response shape must not depend on them. The URL is passed explicitly
  // because production takes it from a build-time define.
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = adapter;
  return UpdateCheckerImpl(manifestUrl: 'http://update.test/latest.json', dio: dio);
}

const String _manifest =
    '{"version":"1.9.9","date":"2026-09-24","notes":"","artifacts":['
    '{"platform":"android","arch":"universal","format":"apk",'
    '"url":"http://example.com/RemotePi.apk","sha256":"","size":1}]}';

void main() {
  group('UpdateCheckerImpl.fetchLatest — body shapes', () {
    test('a decoded JSON body is read (the four-release bug)', () async {
      // Dio hands this one back as a Map, not a String: exactly the shape the
      // old `data is String ? … : null` check threw away.
      final query = await _checker(_StubAdapter(_manifest)).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.9.9');
      expect(query.info.artifacts, hasLength(1));
    });

    test('a body that arrives as a String is read as well', () async {
      final query = await _checker(
        _StubAdapter(_manifest, contentType: 'text/plain; charset=utf-8'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryOk>());
      expect((query as UpdateQueryOk).info.version, '1.9.9');
    });

    test('an empty body is unreadable, not "no update"', () async {
      final query = await _checker(
        _StubAdapter('', contentType: 'text/plain'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
    });
  });

  group('UpdateCheckerImpl.fetchLatest — reasons', () {
    test('HTML from a captive portal is unreadable, and says so', () async {
      final query = await _checker(
        _StubAdapter(
          '<html><body>Sign in to the network</body></html>',
          contentType: 'text/html',
        ),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail, contains('not JSON'));
    });

    test('JSON that is not a manifest is unreadable', () async {
      final query = await _checker(
        _StubAdapter('{"hello":"world"}'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreadable>());
      expect((query as UpdateQueryUnreadable).detail, contains('version'));
    });

    test('a non-2xx status is unreachable, with the code', () async {
      final query = await _checker(
        _StubAdapter('not found', status: 404, contentType: 'text/plain'),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail, 'HTTP 404');
    });

    test('a transport failure is unreachable, with the reason', () async {
      final query = await _checker(
        _StubAdapter('', errorType: DioExceptionType.connectionError),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail, 'no connection');
    });

    test('a timeout is unreachable, and names the timeout', () async {
      final query = await _checker(
        _StubAdapter('', errorType: DioExceptionType.connectionTimeout),
      ).fetchLatest();
      expect(query, isA<UpdateQueryUnreachable>());
      expect((query as UpdateQueryUnreachable).detail, contains('timed out'));
    });
  });

  group('UpdateCheckerImpl without a channel', () {
    test('an empty manifest URL answers "unconfigured"', () async {
      // The name is a build-time define (`--dart-define=UPDATE_MANIFEST_URL=…`),
      // so a self-built binary has no channel. That is not the same as a phone
      // with no network, and must not be reported as one.
      expect(UpdateCheckerImpl.manifestUrlDefine, 'UPDATE_MANIFEST_URL');
      expect(await UpdateCheckerImpl(manifestUrl: '').fetchLatest(),
          isA<UpdateQueryUnconfigured>());
    });
  });
}
