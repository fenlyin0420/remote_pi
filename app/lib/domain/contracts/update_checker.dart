import 'package:app/domain/entities/update_info.dart';

/// Result of one query to the release manifest.
///
/// Four outcomes, not two. "There is no newer version" and "I could not tell"
/// are different answers, and collapsing both into `null` is precisely how a
/// query that had **never once worked** shipped through four releases without
/// anyone — including whoever wrote it — noticing. The caller needs to be able
/// to say which of them it got.
sealed class UpdateQuery {
  const UpdateQuery();
}

/// The manifest was read and understood. Version comparison is the caller's.
final class UpdateQueryOk extends UpdateQuery {
  const UpdateQueryOk(this.info);

  final UpdateInfo info;
}

/// Nothing answered: offline, DNS, connection refused, timed out, non-2xx.
final class UpdateQueryUnreachable extends UpdateQuery {
  const UpdateQueryUnreachable([this.detail = '']);

  /// Short reason for the settings readout (`HTTP 404`, `connection timeout`).
  final String detail;
}

/// Something answered, but it was not a release manifest this app can read: a
/// captive portal injecting HTML, a release published wrong, a schema change.
final class UpdateQueryUnreadable extends UpdateQuery {
  const UpdateQueryUnreadable(this.detail);

  /// Short reason for the settings readout (`not JSON`, `no "version" field`).
  final String detail;
}

/// This build has no update channel at all — the manifest URL is a build-time
/// define and this APK was built without it. Worth its own answer: a self-built
/// binary is not a phone that lost its network, and saying "could not reach the
/// server" about it sends the reader hunting for a connectivity problem.
final class UpdateQueryUnconfigured extends UpdateQuery {
  const UpdateQueryUnconfigured();
}

/// Fetches the release manifest (`latest.json`). Domain contract; the HTTP
/// implementation lives in `data/update/`.
///
/// **Best-effort: never throws.** Every failure becomes one of the failure
/// variants carrying its reason, so a silent "no update" is only ever a real
/// "no update".
abstract class UpdateChecker {
  Future<UpdateQuery> fetchLatest();
}
