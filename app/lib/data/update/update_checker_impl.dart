import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:dio/dio.dart';

/// Release feed + asset fetcher for the GitHub-Release update channel.
///
/// Detection and download are deliberately separate HTTP calls on separate
/// hosts:
///
/// 1. **Detection — the atom feed** (`…/releases.atom`). GitHub serves it as
///    a plain *web* endpoint, not an API: the per-IP API rate limit
///    (`api.github.com`, 60 requests/hour unauthenticated) does not apply to
///    it. This matters: the app ships without a token, and every phone on the
///    same NAT address shares one IP against that limit, so a REST API here
///    would saturate under ordinary use. The feed lists the 10 most recent
///    releases, newest first, **without marking prereleases** — a beta is a
///    tag that carries `-beta.<n>`, and the tag doubles as the version
///    (the publish side enforces that shape, so the app only has to read it).
///
/// 2. **Download — the release asset `latest.json`.** The manifest rides as
///    an asset of its own release (CI generates it with absolute download
///    URLs, sha256, size), and `github.com/…/releases/download/…` redirects
///    to GitHub's asset CDN: TLS-terminated, no API limit, and it honors
///    `Range` — the resume-capable download in
///     [UpdateBannerViewModel.downloadAndInstall] works on it unchanged.
///
/// The in-memory feed cache (default 5 minutes) is what keeps the Home
/// re-check on app resume cheap: within the window, `fetchLatest` answers
/// from memory and touches no network. Failures are never cached.
///
/// **Best-effort: never throws.** Every failure becomes one of the
/// `UpdateQuery` variants carrying its reason, so a silent "no update" is
/// only ever a real "no update".
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    String? feedUrl,
    bool betaChannel = false,
    Duration timeout = const Duration(seconds: 10),
    Duration feedCache = const Duration(minutes: 5),
    Dio? dio,
  })  : feedUrl = feedUrl ?? defaultReleaseFeedUrl,
        _betaChannel = betaChannel,
        _feedCache = feedCache,
        _dio = dio ?? _defaultDio(timeout);

  /// The release feed of this repository. It is the app's update channel, so
  /// it is a constant of the build, not a build-time define.
  static const String defaultReleaseFeedUrl =
      'https://github.com/fenlyin0420/pi-remote/releases.atom';

  static Dio _defaultDio(Duration timeout) => Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        // The *status* is inspected by hand (a non-2xx is a reported
        // failure, not an exception); the body is read verbatim.
        validateStatus: (_) => true,
      ));

  /// The feed this build reads.
  final String feedUrl;

  /// Which channel this build follows: the beta flavor reads the newest
  /// `-beta.N` release, the prod flavor the newest non-prerelease one. The
  /// app is its own channel — the feed serves both from one list, and a beta
  /// phone never upgrades onto a prod release (different applicationId).
  final bool _betaChannel;

  final Duration _feedCache;
  final Dio _dio;

  UpdateQuery? _cached;
  DateTime? _cachedAt;

  @override
  Future<UpdateQuery> fetchLatest({bool force = false}) async {
    if (!force) {
      final at = _cachedAt;
      if (_cached != null &&
          at != null &&
          DateTime.now().difference(at) < _feedCache) {
        return _cached!;
      }
    }

    // 1. Find the newest release of THIS channel in the feed.
    final feed = await _get(feedUrl, 'update feed');
    if (!feed.ok) return feed.failure!;
    if (feed.value is! String) {
      return const UpdateQueryUnreadable('update feed is not text');
    }
    final release = _newestReleaseForChannel(feed.value as String);
    if (release == null) {
      return UpdateQueryUnreadable(
        'no ${_betaChannel ? 'beta' : 'prod'} release in the feed',
      );
    }
    final (tag, version) = release;

    // 2. Read that release's manifest (asset on the CDN) and check that it
    //    agrees with the tag: the tag IS the version, so a manifest that
    //    disagrees is a publishing bug worth surfacing, not installing.
    final manifestUrl =
        '${feedUrl.replaceFirst('/releases.atom', '/releases')}/download/$tag/latest.json';
    final manifest = await _fetchJson(manifestUrl);
    if (manifest is! UpdateQueryOk) return manifest;

    final info = manifest.info;
    if (info.version != version) {
      return UpdateQueryUnreadable(
        'manifest version ${info.version} != tag version $version',
      );
    }

    _cached = UpdateQueryOk(info);
    _cachedAt = DateTime.now();
    return _cached!;
  }

  Future<UpdateQuery> _fetchJson(String url) async {
    final response = await _get(url, 'release manifest');
    if (!response.ok) return response.failure!;

    final dynamic body = response.value;
    final Map<String, dynamic> data;
    if (body is String) {
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        return const UpdateQueryUnreadable('not JSON');
      }
      if (decoded is! Map<String, dynamic>) {
        // Valid JSON that is not an object ('[1,2]', '42', …) would
        // otherwise throw a TypeError, escaping this method's
        // "never throws" contract and stranding the UI on "Checking…".
        return const UpdateQueryUnreadable('not a manifest');
      }
      data = decoded;
    } else if (body is Map<String, dynamic>) {
      data = body;
    } else {
      return const UpdateQueryUnreadable('not a manifest');
    }
    try {
      return UpdateQueryOk(UpdateInfo.fromJson(data));
    } on FormatException catch (e) {
      return UpdateQueryUnreadable('invalid manifest: $e');
    }
  }

  /// The newest feed entry matching this build's channel, as
  /// `(tag, version)`, or `null` when the feed has none.
  ///
  /// Entries are newest-first; prereleases ride in the same list without
  /// marking, so the channel filter is on the tag alone: a beta is a tag
  /// that contains `-beta`, everything else is prod.
  (
    String,
    String,
  )? _newestReleaseForChannel(String feed) {
    for (final entry in _entries(feed)) {
      // The tag shape the publish side enforces: `v<major.minor.patch>` or
      // `v…-beta.<n>`. The lookahead rejects a longer tag sharing that
      // prefix — the feed's 10 recent entries include this repository's
      // old, descriptively-tagged releases (`v1.5.30-model-display-arm64`),
      // which predate the release-assets scheme and must be skipped, not
      // half-parsed into `v1.5.30`.
      final match = RegExp(
        r'releases/tag/(v\d+\.\d+\.\d+(?:-beta\.\d+)?)(?![A-Za-z0-9._-])',
      ).firstMatch(entry);
      if (match == null) continue;
      final tag = match.group(1)!;
      final isBeta = tag.contains('-beta');
      if (isBeta == _betaChannel) {
        return (tag, tag.startsWith('v') ? tag.substring(1) : tag);
      }
    }
    return null;
  }

  static List<String> _entries(String feed) =>
      RegExp(r'<entry>([\s\S]*?)</entry>').allMatches(feed).map(
        (m) => m.group(1)!,
      ).toList();

  /// One GET, mapped onto the checker's outcome vocabulary. Dio throws on
  /// connect/send/receive timeout (the configured [BaseOptions] timeouts) —
  /// those become an `Unreachable` failure too, so the method cannot throw.
  Future<_Get> _get(String url, String what) async {
    try {
      final response = await _dio.getUri<Object?>(Uri.parse(url));
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        return _Get.fail(UpdateQueryUnreachable('HTTP $status ($what)'));
      }
      return _Get.ok(response.data);
    } on DioException catch (e) {
      return _Get.fail(UpdateQueryUnreachable(_describeTimeout(e, what)));
    } catch (_) {
      return _Get.fail(UpdateQueryUnreachable('$what failed'));
    }
  }

  static String _describeTimeout(DioException e, String what) {
    final type = e.type;
    if (type == DioExceptionType.connectionTimeout) {
      return 'connection timeout ($what)';
    }
    if (type == DioExceptionType.sendTimeout) {
      return 'send timeout ($what)';
    }
    if (type == DioExceptionType.receiveTimeout) {
      return 'receive timeout ($what)';
    }
    if (type == DioExceptionType.connectionError) {
      return 'connection error ($what)';
    }
    return '${e.type} ($what)';
  }
}

/// The outcome of one GET inside the checker: either a raw [value] (the
/// HTTP body, verbatim) or a ready-made [failure] variant.
final class _Get {
  const _Get.ok(this.value) : failure = null;
  const _Get.fail(this.failure) : value = null;

  final Object? value;
  final UpdateQuery? failure;

  bool get ok => failure == null;
}
