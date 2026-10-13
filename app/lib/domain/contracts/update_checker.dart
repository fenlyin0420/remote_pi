import 'package:app/domain/entities/update_info.dart';

/// Result of one query to the release feed + manifest.
///
/// Three outcomes, not two. "There is no newer version" and "I could not tell"
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

/// Fetches the newest release of this build's channel. Domain contract;
/// the GitHub-feed implementation lives in `data/update/`.
///
/// **Best-effort: never throws.** Every failure becomes one of the failure
/// variants carrying its reason, so a silent "no update" is only ever a real
/// "no update".
abstract class UpdateChecker {
  /// [force] bypasses the checker's feed cache: the explicit "check for
  /// updates" action asks for a fresh answer, while the automatic re-check
  /// (app resume) may answer from the recent one.
  Future<UpdateQuery> fetchLatest({bool force = false});
}
