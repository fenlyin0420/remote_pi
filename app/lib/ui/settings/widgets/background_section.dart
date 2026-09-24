import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/viewmodels/background_delivery_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Settings → "Background connection".
///
/// One switch for "notify me while the app is in the background". The whole
/// feature is one decision for the user, so it is one control — the two things
/// Android can block underneath it (the notification permission and the OEM
/// battery manager) only surface as fixable rows once the switch is on.
///
/// It is also explicit about the two limits the user will otherwise discover the
/// hard way: the persistent notice (Android requires one for a foreground
/// service) and that swiping the app out of Recents ends the connection.
class BackgroundSection extends StatelessWidget {
  const BackgroundSection({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<BackgroundDeliveryViewModel>();
    final state = vm.state;
    // Desktop / iOS have no keeper. Hide rather than offer a dead switch.
    if (!state.supported) return const SizedBox.shrink();

    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Background'),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          child: Text(
            'Keep the connection to your Pi open while the app is in the '
            'background, so the agent\'s replies arrive as notifications.',
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Stay connected',
                  style: context.typo.sansBody.copyWith(color: colors.text),
                ),
              ),
              Switch(
                key: const Key('background-enabled'),
                value: state.enabled,
                onChanged: state.busy ? null : vm.setEnabled,
                activeThumbColor: colors.accent,
              ),
            ],
          ),
        ),
        if (state.enabled) ...[
          // Android forces a notice while a foreground service runs, but the
          // keeper only runs while the app is *out of sight* — so say both
          // halves, or a notice that never appears while the app is open looks
          // like a switch that does nothing.
          _Note(
            key: const Key('background-notice-note'),
            icon: LucideIcons.info,
            text:
                'Android requires a small "Remote Pi" notice while this keeps '
                'the connection alive in the background — it appears when you '
                'leave the app, not while it is open. Swiping the app away from '
                'Recents stops the connection; pressing Home is fine.',
          ),
          _StatusRow(
            key: const Key('background-notifications-row'),
            icon: state.notificationsEnabled
                ? LucideIcons.bell
                : LucideIcons.bellOff,
            ok: state.notificationsEnabled,
            label: 'Notifications',
            state: state.notificationsEnabled ? 'Allowed' : 'Blocked',
            action: state.notificationsEnabled ? null : 'Fix',
            actionKey: const Key('background-notifications-fix'),
            onAction: vm.openNotificationSettings,
          ),
          // Whether the keeper survived. Worth showing: on Chinese OEM builds
          // the answer can go back to "Stopped" without the app being told why,
          // and "notifications stopped and I don't know why" is the worst state
          // to debug blind.
          //
          // "Waiting for background" is not a fault to fix — it is the keeper
          // doing the right thing while the app is in front.
          _StatusRow(
            key: const Key('background-service-row'),
            icon: LucideIcons.activity,
            ok: state.running || state.waitingForBackground,
            label: 'Service',
            state: state.running
                ? 'Running'
                : state.waitingForBackground
                ? 'Starts when you leave the app'
                : 'Stopped',
            action: state.running || state.waitingForBackground
                ? null
                : 'Restart',
            actionKey: const Key('background-service-restart'),
            onAction: vm.restartKeeper,
          ),
          _StatusRow(
            key: const Key('background-battery-row'),
            icon: LucideIcons.batteryCharging,
            ok: state.batteryExempt,
            label: 'Battery',
            state: state.batteryExempt ? 'Unrestricted' : 'Optimized',
            // Doze spares foreground services; aggressive OEM battery managers
            // do not, and this list is the only thing they listen to.
            action: state.batteryExempt ? null : 'Allow',
            actionKey: const Key('background-battery-allow'),
            onAction: vm.requestBatteryExemption,
          ),
          // Sound + vibration are configured on the system's notification
          // channel, where the app can be right and the phone still silent (a
          // channel's settings are frozen at creation; the user may also have
          // muted it, or be in Do Not Disturb). A one-tap sample turns "it
          // didn't buzz" into a two-second check.
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: OutlinedButton.icon(
              key: const Key('background-test-notification'),
              onPressed: vm.sendTestNotification,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.accent,
                side: BorderSide(color: colors.border),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                minimumSize: const Size.fromHeight(0),
              ),
              icon: const Icon(LucideIcons.bellRing, size: 16),
              label: const Text(
                'Send a test notification',
                style: TextStyle(fontFamily: kMonoFamily, fontSize: 13),
              ),
            ),
          ),
          // The OS's own answer about the channel and the phone's alert state.
          // Cryptic on purpose: this is the line that replaces a round trip of
          // "it doesn't buzz" / "what do your system settings say?"
          //
          // An empty channel id means the platform never answered (the call is
          // missing or failed), which is NOT the same as "nothing is wrong" —
          // saying so plainly is the difference between a readout and a decoy.
          if (state.diagnostics != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
              child: Text(
                state.diagnostics!.channelId.isEmpty
                    ? 'Notification state: unavailable — the platform did not '
                          'answer (build without the readback?).'
                    : 'Notification state: ${state.diagnostics!.summary}',
                key: const Key('background-diagnostics'),
                style: context.typo.monoSmall.copyWith(
                  color: colors.muted2,
                  height: 1.5,
                ),
              ),
            ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A one-line switch row: label on the left, current state (and optional fix
/// action) on the right. Colored by whether the state is the healthy one, so
/// "Blocked"/"Optimized" reads as something to act on rather than as chrome.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    super.key,
    required this.icon,
    required this.ok,
    required this.label,
    required this.state,
    required this.action,
    required this.actionKey,
    required this.onAction,
  });

  final IconData icon;
  final bool ok;
  final String label;
  final String state;
  final String? action;
  final Key actionKey;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final valueColor = ok ? colors.muted : colors.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Row(
        children: [
          Icon(icon, size: 15, color: valueColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: context.typo.sansBody.copyWith(
                color: colors.text,
                fontSize: 13,
              ),
            ),
          ),
          Text(
            state,
            style: context.typo.sansBody.copyWith(
              color: valueColor,
              fontSize: 12,
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 10),
            TextButton(
              key: actionKey,
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                action!,
                style: const TextStyle(fontFamily: kMonoFamily, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: colors.muted2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: context.typo.sansBody.copyWith(
                color: colors.muted2,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
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
