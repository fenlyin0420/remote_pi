import 'package:app/domain/entities/update_info.dart';

/// Estado do aviso de atualização in-app (plano 44). O card tem três formas:
/// escondido (nada a mostrar), oferecendo o update, ou trabalhando (baixando /
/// instalando) com progresso.
sealed class UpdateBannerState {
  const UpdateBannerState();
}

/// Nada a mostrar. `const` → canonicalizado, então `emit` dedupe por
/// identidade sem precisar de `==` manual.
final class UpdateBannerHidden extends UpdateBannerState {
  const UpdateBannerHidden();
}

/// Há uma versão maior, não dispensada, pra anunciar.
final class UpdateBannerVisible extends UpdateBannerState {
  const UpdateBannerVisible(this.info);

  final UpdateInfo info;

  // Igualdade por versão — re-emitir o mesmo manifest não dispara rebuild.
  @override
  bool operator ==(Object other) =>
      other is UpdateBannerVisible && other.info.version == info.version;

  @override
  int get hashCode => info.version.hashCode;
}

/// Conclusão da última consulta ao manifest.
///
/// O estado do card não consegue responder isso — [UpdateBannerHidden] cobre
/// "em dia", "falhou" e "nunca consultou" — e é exatamente essa ambiguidade
/// que torna uma feature silenciosa indistinguível de uma quebrada: um usuário
/// que nunca viu o aviso não tem como distinguir "nada a anunciar" de "quebrado".
enum UpdateCheckStatus {
  /// Nenhuma consulta ainda nesta instância.
  never,

  /// Consulta em andamento.
  checking,

  /// Manifest respondido; nada mais novo que a versão instalada.
  upToDate,

  /// Há versão mais nova e o card está (ou vai estar) na tela.
  available,

  /// Há versão mais nova, mas o usuário dispensou aquele aviso.
  dismissed,

  /// Manifest inalcançável ou inválido — offline, servidor fora, schema errado.
  failed,
}

/// Fase do trabalho mostrado em [UpdateBannerWorking].
enum UpdatePhase {
  /// Baixando o APK. [UpdateBannerWorking.progress] é 0..1 (null = sem
  /// Content-Length, então a UI mostra um spinner indeterminado).
  downloading,

  /// Arquivo em disco; o instalador do sistema foi aberto (ou está sendo).
  installing,
}

/// Download/instalação em andamento — o card vira uma barra de progresso.
final class UpdateBannerWorking extends UpdateBannerState {
  const UpdateBannerWorking({
    required this.info,
    required this.phase,
    this.progress,
  });

  final UpdateInfo info;
  final UpdatePhase phase;

  /// 0..1 durante [UpdatePhase.downloading]; null quando o servidor não mandou
  /// Content-Length. Ignorado em [UpdatePhase.installing].
  final double? progress;

  // Ignora oscilações de progresso: só re-emite quando muda a fase (o
  // rebuild a cada % seria ruído à toa na lista da Home).
  @override
  bool operator ==(Object other) =>
      other is UpdateBannerWorking &&
      other.info.version == info.version &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(info.version, phase);
}
