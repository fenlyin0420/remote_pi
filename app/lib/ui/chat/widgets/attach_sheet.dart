import 'package:app/routing/adaptive.dart';
import 'package:app/ui/chat/quick_actions/widgets/dismiss_on_session_change.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Which source the user picked from the attach sheet (#2).
///
/// `file` picks any file (never filtered by name); text-ness is decided from
/// the content, so logs, code, CSVs and extensionless configs all qualify.
enum AttachSource { camera, gallery, file }

/// Bottom sheet offering Camera / Photo Library / File (decision #2,
/// interpreted as an action sheet to match the quick-actions sheet idiom).
/// Returns the chosen [AttachSource], or null if dismissed. Pure UI — the
/// caller drives the picker ViewModel with the result.
///
/// [imageBlocked] greys out the two image sources when the active model does
/// not accept images. It never affects File: any model can read a text file.
Future<AttachSource?> showAttachSheet(
  BuildContext context, {
  bool imageBlocked = false,
}) {
  // Auto-close if the tablet's selected session changes out from under the
  // sheet (same fix as the Quick Actions sheet — the modal lives on the
  // detail-pane navigator and would otherwise orphan over a different chat).
  final selection = context.read<SessionSelection>();
  return showModalBottomSheet<AttachSource>(
    context: context,
    backgroundColor: context.colors.bg,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => DismissOnSessionChange(
      selection: selection,
      child: _AttachSheetBody(imageBlocked: imageBlocked),
    ),
  );
}

class _AttachSheetBody extends StatelessWidget {
  const _AttachSheetBody({this.imageBlocked = false});

  final bool imageBlocked;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: context.colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _AttachOption(
              key: const Key('attach-camera'),
              icon: LucideIcons.camera,
              label: 'Camera',
              disabled: imageBlocked,
              onTap: () => Navigator.of(context).pop(AttachSource.camera),
            ),
            _AttachOption(
              key: const Key('attach-gallery'),
              icon: LucideIcons.image,
              label: 'Photo Library',
              disabled: imageBlocked,
              onTap: () => Navigator.of(context).pop(AttachSource.gallery),
            ),
            _AttachOption(
              key: const Key('attach-file'),
              icon: LucideIcons.fileText,
              label: 'File',
              onTap: () => Navigator.of(context).pop(AttachSource.file),
            ),
            if (imageBlocked)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'The current model does not accept images.',
                  style: TextStyle(
                    fontFamily: kMonoFamily,
                    fontSize: 11,
                    color: context.colors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachOption extends StatelessWidget {
  const _AttachOption({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      enabled: !disabled,
      onTap: disabled ? null : onTap,
      leading: Icon(
        icon,
        color: disabled ? colors.muted : colors.accent,
        size: 20,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 14,
          color: disabled ? colors.muted : colors.text,
        ),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }
}
