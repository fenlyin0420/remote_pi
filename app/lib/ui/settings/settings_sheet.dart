import 'package:app/config/dependencies.dart';
import 'package:app/routing/adaptive.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/settings_page.dart';
import 'package:app/ui/settings/viewmodels/background_delivery_viewmodel.dart';
import 'package:app/ui/settings/viewmodels/identity_backup_viewmodel.dart';
import 'package:app/ui/settings/viewmodels/settings_viewmodel.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

/// Plan/tablet — open Settings adaptively:
///   • tablet (wide) → modal bottom sheet over the master-detail layout,
///     so the user keeps the chat in context instead of losing the whole
///     screen to a pushed route.
///   • phone        → the existing full-screen `/settings` push.
void openSettings(BuildContext context) {
  if (isWideLayout(context)) {
    showSettingsSheet(context);
  } else {
    context.push('/settings');
  }
}

/// Presents [SettingsPage] (embedded variant) in a tall modal bottom sheet.
/// The page reaches the same view models as the route through fresh
/// [ViewmodelProvider]s (injector-backed), so behaviour is identical to the
/// pushed screen — including the sections that read the OS (background
/// delivery) and the ones that can be dismissed halfway (update check). Every
/// section's VM has to be listed here too: a section whose provider is missing
/// throws on build, and the sheet is the only path a tablet user has to
/// Settings.
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.colors.bg,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    isScrollControlled: true,
    // Clip the embedded Scaffold/AppBar to the rounded top corners.
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return FractionallySizedBox(
        heightFactor: 0.92,
        child: MultiProvider(
          providers: [
            ViewmodelProvider<SettingsViewModel>(),
            ViewmodelProvider<IdentityBackupViewModel>(),
            ViewmodelProvider<BackgroundDeliveryViewModel>(),
            ViewmodelProvider<UpdateBannerViewModel>(),
          ],
          child: const SettingsPage(embedded: true),
        ),
      );
    },
  );
}
