import 'dart:async';
import 'dart:io';

import 'package:app/domain/contracts/apk_installer.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/value_objects/semver.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:dio/dio.dart';

/// Aviso de atualização in-app, **Android-only** (plano 44). No [check]
/// (disparado no mount da Home, = startup) consulta o manifest; se houver
/// versão **maior** que a atual e que **não foi dispensada**, emite
/// [UpdateBannerVisible].
///
/// [downloadAndInstall] baixa o APK para o cache do app e entrega ao
/// instalador do sistema (via [ApkInstaller]) — sem sair para o navegador.
/// O Android não permite instalação silenciosa para apps comuns: a primeira
/// vez exige habilitar "instalar apps desconhecidos" para este app, e toda
/// instalação termina numa confirmação do próprio sistema.
///
/// Tudo best-effort: falhas de rede/manifest são silenciosas, e uma falha de
/// download/instalação volta para [UpdateBannerVisible] reportando via
/// [errors] (a UI mostra um snackbar).
class UpdateBannerViewModel extends ViewModel<UpdateBannerState> {
  UpdateBannerViewModel(
    this._checker,
    this._dismissed,
    this._installer, {
    required this.currentVersion,
    required this.enabled,
    this.platform = 'android',
    this.format = 'apk',
    this.arch = 'universal',
    Dio? dio,
  })  : _dio = dio ?? _defaultDio(),
        super(const UpdateBannerHidden());

  /// File name inside the native update dir. The installer matches on the MIME
  /// type we send, not this, but a real `.apk` name keeps the system's "install
  /// this app?" screen readable.
  static const String _kApkFileName = 'RemotePi-update.apk';

  final UpdateChecker _checker;
  final DismissedUpdateStore _dismissed;
  final ApkInstaller _installer;
  final Dio _dio;

  /// Versão do app rodando (de `package_info`, injetada no boot).
  final String currentVersion;

  /// `true` só no Android — em iOS o app atualiza pela App Store, então o
  /// aviso nunca aparece.
  final bool enabled;

  /// Coordenadas do artefato a baixar (Android = apk universal).
  final String platform;
  final String format;
  final String arch;

  final _errorController = StreamController<String>.broadcast();

  /// Uma mensagem por falha de download/instalação, pra UI mostrar snackbar.
  Stream<String> get errors => _errorController.stream;

  bool _checked = false;
  bool _busy = false;
  bool _disposed = false;

  /// Conclusão da última consulta (ver [UpdateCheckStatus]). Independente do
  /// estado do card, porque `Hidden` cobre "em dia", "falhou" e "nunca
  /// consultou" — e é essa ambiguidade que a UI de Settings precisa desfazer.
  UpdateCheckStatus _status = UpdateCheckStatus.never;

  /// Versão anunciada pelo manifest na última consulta (`null` quando não houve
  /// ou não é mais nova). Existe só pra UI nomear a versão ao falar do aviso.
  String? _latestVersion;

  /// Motivo curto da última falha (`HTTP 404`, `not JSON (...)`, `no
  /// connection`) — é o que transforma "não deu" em algo acionável.
  String _failureDetail = '';

  UpdateCheckStatus get status => _status;

  String? get latestVersion => _latestVersion;

  String get failureDetail => _failureDetail;

  /// Muda o status e avisa a UI. Não passa por [emit]: o estado do card pode
  /// continuar `Hidden` enquanto o status muda (em dia → offline).
  void _report(
    UpdateCheckStatus status, {
    String? latest,
    String detail = '',
  }) {
    _latestVersion = latest;
    _failureDetail = detail;
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }

  static Dio _defaultDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(minutes: 5),
        // Downloading an APK is a plain GET; fail loudly on a non-2xx instead
        // of writing an error page to disk as if it were the app.
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      ),
    );
  }

  /// Consulta o manifest e decide se o card deve aparecer. Silencioso em
  /// falha. Idempotente por instância: a mesma instância só consulta uma vez,
  /// a menos que [force] seja passado.
  ///
  /// [force] existe para o caso que mais dói: o app estava aberto quando uma
  /// release saiu, então a consulta do boot já passou (e não achou nada). Um
  /// app que fica aberto por dias nunca saberia que há versão nova — por isso
  /// a Home re-consulta quando o app volta ao primeiro plano.
  ///
  /// Num re-check, uma falha de rede **não** derruba um card que já está na
  /// tela: ficar sem manifest é motivo para manter o que o usuário já viu, não
  /// para tirar a oferta dele.
  Future<void> check({bool force = false}) async {
    if (!enabled) return; // iOS / não-Android → nunca mostra.
    if (_checked && !force) return;
    _checked = true;

    _report(UpdateCheckStatus.checking);

    final query = await _checker.fetchLatest();
    if (_disposed) return;

    // Each outcome says which one it is: "no update" is now only ever said by a
    // manifest that was actually read and understood.
    switch (query) {
      case UpdateQueryUnreachable(:final detail):
        _report(UpdateCheckStatus.unreachable, detail: detail);
        return; // sem rede/manifest → nada.
      case UpdateQueryUnreadable(:final detail):
        _report(UpdateCheckStatus.unreadable, detail: detail);
        return; // resposta ilegível → nada.
      case UpdateQueryOk(:final info):
        if (!isNewerVersion(info.version, currentVersion)) {
          _report(UpdateCheckStatus.upToDate);
          return; // igual/menor → nada.
        }

        // Um store ilegível **não** é motivo pra esconder a atualização: o
        // único desfecho que não se aceita aqui é o silencioso. Na dúvida,
        // mostra.
        var dismissed = false;
        try {
          dismissed = await _dismissed.dismissedVersion() == info.version;
        } catch (_) {
          dismissed = false;
        }
        if (_disposed) return;
        if (dismissed) {
          _report(UpdateCheckStatus.dismissed, latest: info.version);
          return; // dispensada → nada.
        }

        _report(UpdateCheckStatus.available, latest: info.version);
        emit(UpdateBannerVisible(info));
    }
  }

  /// Fecha o card e persiste a versão como dispensada — não reaparece pra ela
  /// (volta numa versão maior).
  Future<void> dismiss() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    final version = current.info.version;
    emit(const UpdateBannerHidden());
    _report(UpdateCheckStatus.dismissed, latest: version);
    await _dismissed.dismiss(version);
  }

  /// Esquece a dispensa e consulta de novo, reoferecendo a atualização. Existe
  /// porque dispensar é irreversível do ponto de vista do usuário: o card fecha
  /// num toque e, sem isto, só volta na próxima release.
  Future<void> clearDismissal() async {
    try {
      await _dismissed.clear();
    } catch (_) {
      // Best-effort: se o storage não apagar, o re-check reporta `dismissed`
      // outra vez e a UI mantém o botão — nada pior que o estado atual.
    }
    if (_disposed) return;
    await check(force: true);
  }

  /// Baixa o APK e abre o instalador do sistema.
  ///
  /// Fluxo: resolve o artefato do manifest → baixa para o cache do app →
  /// confere a permissão de instalação → entrega ao instalador. Sem permissão,
  /// abre a tela do sistema para concedê-la e mantém o card visível (o usuário
  /// toca de novo depois de conceder). Qualquer outra falha volta para
  /// [UpdateBannerVisible] e publica a mensagem em [errors].
  Future<void> downloadAndInstall() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    if (_busy) return; // um download por vez
    _busy = true;

    final info = current.info;
    // Progresso só é re-emitido quando muda a fase (ver ==), então atualizar
    // `progress` a cada chunk não custa rebuild.
    var working = UpdateBannerWorking(
      info: info,
      phase: UpdatePhase.downloading,
      progress: null,
    );
    emit(working);

    try {
      final artifact = info.artifactFor(
        platform: platform,
        format: format,
        arch: arch,
      );
      if (artifact == null) {
        _fail('This build has no APK for $platform/$arch');
        return;
      }

      // The installer confines the APK to its own cache dir, so ask the
      // platform where to write it (no path_provider dependency).
      final dirPath = await _installer.updateDownloadsDir();
      if (_disposed) return;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final target = File('${dir.path}/$_kApkFileName');
      // Start from a clean file: a partial download from a previous attempt
      // would otherwise be handed to the installer as a corrupt APK.
      if (target.existsSync()) target.deleteSync();

      await _dio.download(
        artifact.url,
        target.path,
        onReceiveProgress: (received, total) {
          if (_disposed) return;
          if (total <= 0) return;
          final next = UpdateBannerWorking(
            info: info,
            phase: UpdatePhase.downloading,
            progress: received / total,
          );
          // `==` ignores progress, so emit unconditionally only when the
          // phase changed; otherwise the state stays as-is (same value).
          if (next != working) {
            working = next;
            emit(next);
          }
        },
      );
      if (_disposed) return;

      // A zero-byte / truncated file means the download was cut short — never
      // hand that to the installer.
      if (!target.existsSync() || target.lengthSync() == 0) {
        _fail('Download failed — the APK is empty');
        return;
      }
      if (artifact.size > 0 && target.lengthSync() != artifact.size) {
        _fail('Download incomplete — tap to retry');
        return;
      }

      emit(UpdateBannerWorking(info: info, phase: UpdatePhase.installing));
      final allowed = await _installer.canInstall();
      if (_disposed) return;
      if (!allowed) {
        // First run on this device (or the user revoked it): send them to the
        // toggle, keep the card up so one more tap installs.
        await _installer.openInstallSettings();
        if (_disposed) return;
        _fail('Allow "install unknown apps" for Remote Pi, then tap again');
        return;
      }

      await _installer.install(target.path);
      if (_disposed) return;
      // The system installer now owns the screen; the app is replaced on
      // confirm. Leave the card in place — if the user backs out this state is
      // harmless, and a successful install restarts the process anyway.
    } on ApkInstallException catch (e) {
      _fail(e.message);
    } on DioException catch (e) {
      _fail(_describeDio(e));
    } catch (e) {
      _fail('Update failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Volta ao card de oferta e publica o motivo.
  void _fail(String message) {
    if (_disposed) return;
    final current = state;
    final info = switch (current) {
      UpdateBannerVisible() => current.info,
      UpdateBannerWorking() => current.info,
      UpdateBannerHidden() => null,
    };
    if (info != null) emit(UpdateBannerVisible(info));
    if (!_errorController.isClosed) _errorController.add(message);
  }

  /// Human-readable reason for a failed download.
  String _describeDio(DioException e) {
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout => 'Download timed out — tap to retry',
      DioExceptionType.connectionError => 'No connection to the update server',
      DioExceptionType.badResponse =>
        'Update server error (HTTP ${e.response?.statusCode})',
      _ => 'Download failed — tap to retry',
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _errorController.close();
    super.dispose();
  }
}
