import 'dart:async';

import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Aviso de atualização in-app (plano 44). Renderiza nada quando não há versão
/// nova a anunciar (iOS, sem update, dispensada, manifest indisponível) — o
/// gate Android-only vive no [UpdateBannerViewModel.enabled].
///
/// Dispara o check silencioso no primeiro mount (= startup da Home). Tocar no
/// corpo baixa o APK e abre o instalador do sistema; o X dispensa (persistido
/// por versão).
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  StreamSubscription<String>? _errorSub;

  @override
  void initState() {
    super.initState();
    // `context.read` é seguro no initState (não assina). Best-effort: o check
    // se auto-silencia em qualquer falha e é no-op fora do Android.
    final vm = context.read<UpdateBannerViewModel>();
    vm.check();
    // Falhas de download/instalação chegam aqui (o card volta sozinho para o
    // estado de oferta, então o usuário pode tentar de novo).
    _errorSub = vm.errors.listen(_showError);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UpdateBannerViewModel>().state;
    return switch (state) {
      UpdateBannerHidden() => const SizedBox.shrink(),
      UpdateBannerVisible(:final info) => _UpdateCard(info: info),
      UpdateBannerWorking(:final info, :final phase, :final progress) =>
        _WorkingCard(info: info, phase: phase, progress: progress),
    };
  }
}

/// Card discreto no topo da Home (abaixo do título, acima da lista). Tocar no
/// corpo baixa e instala; o X dispensa.
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.read<UpdateBannerViewModel>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: const Key('update-banner-download'),
          borderRadius: BorderRadius.circular(12),
          onTap: vm.downloadAndInstall,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.arrowDownToLine,
                  size: 18,
                  color: colors.accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Update available',
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.sansBody.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${info.version} · tap to install',
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.monoSmall.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('update-banner-dismiss'),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  icon: Icon(LucideIcons.x, size: 16, color: colors.muted2),
                  onPressed: vm.dismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Mesmo card, em modo trabalho: barra de progresso no download e spinner
/// indeterminado na instalação (quem conduz aí é o sistema). Sem botão de
/// dispensar — a operação está em curso e o X só confundiria.
class _WorkingCard extends StatelessWidget {
  const _WorkingCard({
    required this.info,
    required this.phase,
    required this.progress,
  });

  final UpdateInfo info;
  final UpdatePhase phase;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final installing = phase == UpdatePhase.installing;
    final pct = progress == null ? null : (progress! * 100).clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          key: const Key('update-banner-working'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.accent.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      installing
                          ? 'Opening installer…'
                          : 'Downloading v${info.version}…',
                      overflow: TextOverflow.ellipsis,
                      style: context.typo.sansBody.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  if (pct != null && !installing)
                    Text(
                      '${pct.round()}%',
                      style: context.typo.monoSmall.copyWith(
                        color: colors.muted,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // Instalação é conduzida pelo sistema e não tem progresso nosso;
              // a barra fica só no download.
              if (!installing)
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    // Sem Content-Length o valor fica null → indeterminada.
                    value: progress,
                    minHeight: 3,
                    backgroundColor: colors.border,
                    color: colors.accent,
                  ),
                ),
              if (installing) ...[
                const SizedBox(height: 2),
                Text(
                  'Confirm in the system prompt to finish.',
                  style: context.typo.monoSmall.copyWith(color: colors.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
