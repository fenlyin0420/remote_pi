import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:app/ui/update/widgets/update_banner.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Settings → "About" (Android only): which version is installed, what the last
/// check concluded, and a way to ask again.
///
/// The Home card alone is invisible by design — it renders nothing when there is
/// nothing to announce, so "up to date", "offline" and "never checked" all look
/// exactly the same. A user who has never seen a card cannot tell a working
/// notice from a broken one, and neither can anyone they ask. This section is
/// the part that says the answer out loud; the card it embeds is the part that
/// installs.
///
/// iOS updates through the App Store, so nothing here is shown there.
class UpdateSection extends StatelessWidget {
  const UpdateSection({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<UpdateBannerViewModel>();
    if (!vm.enabled) return const SizedBox.shrink();

    final colors = context.colors;
    final working = vm.state is UpdateBannerWorking;
    final checking = vm.status == UpdateCheckStatus.checking;
    // One button, whose job follows the state: ask, ask again, or undo a
    // dismissal that was not meant to be permanent.
    final (label, action) = switch (vm.status) {
      UpdateCheckStatus.dismissed => ('Show update again', vm.clearDismissal),
      UpdateCheckStatus.checking => ('Checking…', null),
      _ => ('Check for updates', () => vm.check(force: true)),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('About'),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Version',
                  style: context.typo.sansBody.copyWith(color: colors.text),
                ),
              ),
              Text(
                'v${vm.currentVersion}',
                key: const Key('update-version'),
                style: context.typo.monoSmall.copyWith(color: colors.muted),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Text(
            _describe(vm),
            key: const Key('update-status'),
            style: context.typo.sansBody.copyWith(
              color: vm.status == UpdateCheckStatus.failed
                  ? colors.error
                  : colors.muted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: OutlinedButton.icon(
            key: const Key('update-check'),
            onPressed: (checking || working) ? null : action,
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.border),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              minimumSize: const Size.fromHeight(0),
            ),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: Text(
              label,
              style: const TextStyle(fontFamily: kMonoFamily, fontSize: 13),
            ),
          ),
        ),
        // The same card the Home screen shows — one implementation of
        // "there is a new version", including the download and the handoff to
        // the system installer.
        const UpdateBanner(),
        const SizedBox(height: 8),
      ],
    );
  }

  /// What the last check concluded, in the user's terms. Every branch says
  /// something: silence is what made this section necessary.
  String _describe(UpdateBannerViewModel vm) {
    final latest = vm.latestVersion;
    return switch (vm.status) {
      UpdateCheckStatus.never => 'Not checked yet.',
      UpdateCheckStatus.checking => 'Checking for the latest release…',
      UpdateCheckStatus.upToDate =>
        'Up to date. Newer releases are announced by a card at the top of the '
            'room list.',
      UpdateCheckStatus.available =>
        'v${latest ?? '?'} is available — the card below installs it.',
      UpdateCheckStatus.dismissed =>
        'v${latest ?? '?'} is available; you closed that notice. It stays '
            'closed until the next release unless you ask for it again.',
      UpdateCheckStatus.failed =>
        'Could not reach the update server. The card stays hidden while the '
            'check fails, so an offline phone looks the same as an up-to-date '
            'one.',
    };
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Text(
        label.toUpperCase(),
        style: context.typo.monoSmall.copyWith(
          color: colors.muted2,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
