import 'dart:async';

import 'package:app/data/pairing/identity_transfer_service.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/states/identity_backup_state.dart';
import 'package:app/ui/settings/viewmodels/identity_backup_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Settings → "Backup & restore".
///
/// Lets the user carry this device's identity (Owner keypair + pairings) to a
/// new phone as a file, so a replacement does not need to rescan the QR.
///
/// The section is deliberately blunt about what the file is: it contains a
/// private key, and anyone holding it can act as this device. That honesty is
/// the safety mechanism — there is no way to make a credential backup sound
/// harmless.
class IdentityBackupSection extends StatefulWidget {
  const IdentityBackupSection({super.key});

  @override
  State<IdentityBackupSection> createState() => _IdentityBackupSectionState();
}

class _IdentityBackupSectionState extends State<IdentityBackupSection> {
  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _errorSub = context.read<IdentityBackupViewModel>().errors.listen(
        _showError,
      );
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<IdentityBackupViewModel>();
    // Platforms without the native channel (iOS until implemented, desktop)
    // hide the section entirely rather than offering a button that fails.
    if (!vm.supported) return const SizedBox.shrink();

    final colors = context.colors;
    final state = vm.state;
    final busy = state is IdentityBackupBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Backup & restore'),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
          child: Text(
            'Move this device\'s identity to another phone without scanning '
            'the QR code again. The backup file contains your private key — '
            'keep it somewhere safe and delete it once you no longer need it.',
            style: context.typo.sansBody.copyWith(
              color: colors.muted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
        if (busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: colors.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.label,
                    style: context.typo.sansBody.copyWith(
                      color: colors.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('identity-export'),
                    onPressed: () => _onExport(vm),
                    style: _outlineStyle(colors),
                    icon: const Icon(LucideIcons.download, size: 16),
                    label: const Text(
                      'Export',
                      style: TextStyle(fontFamily: kMonoFamily, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('identity-import'),
                    onPressed: () => _onImport(vm),
                    style: _outlineStyle(colors),
                    icon: const Icon(LucideIcons.upload, size: 16),
                    label: const Text(
                      'Import',
                      style: TextStyle(fontFamily: kMonoFamily, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Outcome line. Export/restore results persist until the user does
        // something else, so a completed action is not silently ambiguous.
        if (state is IdentityBackupExported)
          _Outcome(
            key: const Key('identity-exported'),
            icon: LucideIcons.circleCheck,
            color: colors.accent,
            text: 'Backup saved as ${state.fileName}.',
          ),
        if (state is IdentityBackupRestored)
          _Outcome(
            key: const Key('identity-restored'),
            icon: LucideIcons.circleCheck,
            color: colors.accent,
            text: state.keypairChanged
                ? 'Restored this device\'s identity and '
                      '${_peers(state.peerCount)}.'
                : 'Re-imported this device\'s own backup '
                      '(${_peers(state.peerCount)}). Identity unchanged.',
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  static ButtonStyle _outlineStyle(dynamic colors) => OutlinedButton.styleFrom(
    foregroundColor: colors.accent,
    side: BorderSide(color: colors.border),
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
    ),
    minimumSize: const Size.fromHeight(0),
  );

  static String _peers(int n) => n == 1 ? '1 paired Pi' : '$n paired Pis';

  Future<void> _onExport(IdentityBackupViewModel vm) async {
    final name = await vm.export();
    if (!mounted || name == null) return;
    // The outcome line in the section already confirms it; a SnackBar on top
    // would be redundant.
  }

  Future<void> _onImport(IdentityBackupViewModel vm) async {
    final bundle = await vm.prepareImport();
    if (!mounted || bundle == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        final c = dCtx.colors;
        return AlertDialog(
          backgroundColor: c.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: c.border),
          ),
          title: Text(
            'Replace this device\'s identity?',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 14,
              color: c.text,
            ),
          ),
          content: Text(
            '${IdentityTransferService.describe(bundle)}\n\n'
            'Your current identity and its pairings will be replaced. The Pi '
            'may need a moment to notice, and you will not be able to go back '
            'unless you exported the current identity first.',
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 12,
              height: 1.4,
              color: c.muted,
            ),
          ),
          actions: [
            TextButton(
              key: const Key('identity-import-cancel'),
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: Text(
                'Cancel',
                style: TextStyle(fontFamily: kMonoFamily, color: c.muted),
              ),
            ),
            FilledButton(
              key: const Key('identity-import-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
              ),
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: const Text(
                'Restore',
                style: TextStyle(fontFamily: kMonoFamily),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      vm.cancelImport();
      return;
    }
    await vm.confirmImport();
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: context.typo.sansBody.copyWith(
                color: colors.muted,
                fontSize: 12,
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
