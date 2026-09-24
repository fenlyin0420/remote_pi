import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:dio/dio.dart';

/// Fetches the app's `latest.json` over HTTP (Dio — the same client the mesh
/// already uses). Short timeout; every failure is reported as a variant of
/// [UpdateQuery] instead of a bare `null`.
///
/// Mirrors the schema of the Cockpit manifest, with one `android`/`apk`
/// artifact. Parsing/validation lives in [UpdateInfo.fromJson].
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    String? manifestUrl,
    Duration timeout = const Duration(seconds: 5),
    Dio? dio,
  })  : manifestUrl = manifestUrl ?? defaultManifestUrl,
        _dio = dio ?? _defaultDio(timeout);

  /// Self-hosted manifest, addressed at **build time**:
  /// `--dart-define=UPDATE_MANIFEST_URL=http://host:port/downloads/app/latest.json`.
  ///
  /// Deliberately not in the source. This repository is public and the manifest
  /// lives on a personal server, so the address is a build input like the
  /// signing key: present in the APK that ships, absent from the code. Cleartext
  /// for that host is likewise injected — see the generated
  /// `res/xml/network_security_config.xml` in `app/android/app/build.gradle.kts`.
  ///
  /// A build without the define has no update channel and says so, rather than
  /// looking like a phone with no network.
  static const String manifestUrlDefine = 'UPDATE_MANIFEST_URL';

  static const String defaultManifestUrl =
      String.fromEnvironment(manifestUrlDefine);

  final String manifestUrl;
  final Dio _dio;

  static Dio _defaultDio(Duration timeout) {
    return Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        // We check the status ourselves — don't let Dio throw on 4xx/5xx, so
        // the reason survives to the settings readout instead of a stack trace.
        validateStatus: (_) => true,
      ),
    );
  }

  @override
  Future<UpdateQuery> fetchLatest() async {
    if (manifestUrl.isEmpty) return const UpdateQueryUnconfigured();

    final Response<Object?> response;
    try {
      response = await _dio.getUri<Object?>(Uri.parse(manifestUrl));
    } on DioException catch (e) {
      return UpdateQueryUnreachable(_describe(e));
    } catch (e) {
      return UpdateQueryUnreachable('$e');
    }

    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) {
      return UpdateQueryUnreachable('HTTP $status');
    }

    // Do not assume the body's shape. `BaseOptions.responseType` does **not**
    // survive Dio 5's `get`/`getUri`: the per-call options default to
    // `ResponseType.json` and win over the base options, so a JSON content type
    // arrives already decoded as a Map while a text/plain one arrives as a
    // String. Requiring a String here is what made this call answer "no update"
    // for every request it ever made.
    final Object? data = response.data;
    final Object? decoded;
    if (data is String) {
      try {
        decoded = jsonDecode(data);
      } on FormatException catch (e) {
        return UpdateQueryUnreadable('not JSON (${e.message})');
      }
    } else {
      decoded = data;
    }

    try {
      return UpdateQueryOk(UpdateInfo.fromJson(decoded));
    } on FormatException catch (e) {
      return UpdateQueryUnreadable(e.message);
    }
  }

  /// Short reason for a failed request, in the words the settings readout uses.
  String _describe(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout => 'connection timed out',
      DioExceptionType.receiveTimeout => 'no response in time',
      DioExceptionType.sendTimeout => 'request timed out',
      DioExceptionType.connectionError => 'no connection',
      DioExceptionType.badCertificate => 'bad certificate',
      DioExceptionType.cancel => 'request cancelled',
      DioExceptionType.badResponse =>
        'HTTP ${e.response?.statusCode ?? '?'}',
      DioExceptionType.unknown => '${e.error ?? e.message ?? 'unknown'}',
    };
  }
}
