import 'dart:async';
import 'dart:io';

import 'package:app/domain/contracts/apk_installer.dart';
import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
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

  /// File name for the update APK: `RemotePi-<version>.apk`. The version in
  /// the name is load-bearing — it is what makes a retry resume: the file
  /// belongs to one specific manifest version, and it becomes the name the
  /// copy gets in the device's public Downloads folder.
  static String apkFileName(String version) => 'RemotePi-$version.apk';

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
      case UpdateQueryUnconfigured():
        _report(UpdateCheckStatus.unconfigured);
        return; // build sem canal de atualização → nada.
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
  /// Fluxo: resolve o artefato do manifest → baixa para o cache do app (com
  /// retomada: um download interrompido continua de onde parou) → publica uma
  /// cópia na pasta Downloads do aparelho → confere a permissão de instalação
  /// → entrega ao instalador. Sem permissão, abre a tela do sistema para
  /// concedê-la e mantém o card visível (o usuário toca de novo depois de
  /// conceder). Qualquer outra falha volta para [UpdateBannerVisible] e
  /// publica a mensagem em [errors].
  Future<void> downloadAndInstall() async {
    final current = state;
    if (current is! UpdateBannerVisible) return;
    if (_busy) return; // um download por vez
    _busy = true;

    final info = current.info;
    var working = UpdateBannerWorking(
      info: info,
      phase: UpdatePhase.downloading,
      progress: null,
    );
    emit(working);
    // O progresso é re-emitido só quando muda o inteiro de percentagem — a
    // barra se move a cada 1% sem reconstruir a lista a cada chunk.
    var lastPercent = -1;

    void reportProgress(double fraction) {
      if (_disposed) return;
      final percent = (fraction * 100).floor();
      if (percent == lastPercent) return;
      lastPercent = percent;
      final next = UpdateBannerWorking(
        info: info,
        phase: UpdatePhase.downloading,
        progress: fraction.clamp(0.0, 1.0),
      );
      if (next != working) {
        working = next;
        emit(next);
      }
    }

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
      final fileName = apkFileName(info.version);

      // The installer confines the APK to its own cache dir, so ask the
      // platform where to write it (no path_provider dependency).
      final dirPath = await _installer.updateDownloadsDir();
      if (_disposed) return;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final target = File('${dir.path}/$fileName');

      var existing = 0;
      if (target.existsSync() && target.lengthSync() > 0) {
        // The file belongs to this exact version (the name carries it), so a
        // leftover is by definition a partial download to continue — not a
        // corrupt file to throw away.
        existing = target.lengthSync();
      }

      if (artifact.size > 0 && existing >= artifact.size) {
        // A previous attempt already finished this version's file; just go
        // straight to the permission gate.
      } else if (existing > 0) {
        working = UpdateBannerWorking(
          info: info,
          phase: UpdatePhase.downloading,
          progress: existing / (artifact.size > 0 ? artifact.size : existing),
          resumed: true,
        );
        emit(working);
        // Progress stays on the resumed line for the whole 206 download.
        final response = await _dio.download(
          artifact.url,
          target.path,
          onReceiveProgress: (received, total) {
            final int full;
            if (artifact.size > 0) {
              full = artifact.size;
            } else if (total > 0) {
              full = existing + total;
            } else {
              return;
            }
            reportProgress((existing + received) / full);
          },
          deleteOnError: false,
          fileAccessMode: FileAccessMode.append,
          options: Options(headers: {'Range': 'bytes=$existing-'}),
        );
        if (_disposed) return;

        if (response.statusCode == 200) {
          // The server ignored the Range header and sent the whole file, which
          // dio appended on top of the partial file. Wipe and start fresh —
          // the size check below would catch it anyway, but this keeps the
          // user from waiting through a doomed double download.
          target.deleteSync();
          await _freshDownload(
            artifact,
            target,
            onProgress: reportProgress,
          );
          if (_disposed) return;
        }
      } else {
        await _freshDownload(
          artifact,
          target,
          onProgress: reportProgress,
        );
        if (_disposed) return;
      }

      // A zero-byte / truncated file means the download was cut short — never
      // hand that to the installer.
      if (!target.existsSync() || target.lengthSync() == 0) {
        _fail('Download failed — the APK is empty');
        return;
      }
      if (artifact.size > 0 && target.lengthSync() != artifact.size) {
        // The leftover is corrupt or mismatched, so a retry would resume from
        // garbage — throw it away. With no known size the partial file stays:
        // it is the resume anchor for the next attempt.
        target.deleteSync();
        _fail('Download incomplete — tap to retry');
        return;
      }

      // Publish a copy to the device's public Downloads (best-effort — a
      // failure here never blocks the install, which runs from the cache
      // copy). Done before the system installer takes over the screen, so
      // the file is in Downloads even if the user backs out of the install.
      try {
        await _installer.publishToDownloads(target.path, fileName);
      } catch (_) {
        // The contract says best-effort; MethodChannelApkInstaller already
        // swallows, this is a guard for fakes/other implementations.
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

  /// Baixa do zero: arquivo limpo, modo write, delete-on-error ligado. A
  /// retomada (Range + append) tem caminho próprio no [downloadAndInstall].
  Future<void> _freshDownload(
    UpdateArtifact artifact,
    File target, {
    required void Function(double) onProgress,
  }) async {
    if (target.existsSync()) target.deleteSync();
    await _dio.download(
      artifact.url,
      target.path,
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        onProgress(received / total);
      },
    );
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
