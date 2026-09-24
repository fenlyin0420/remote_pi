import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:dio/dio.dart';

/// Busca o `latest.json` do app via HTTP (Dio — mesmo client já usado pelo
/// mesh, plano 24). Timeout curto; qualquer falha → `null` (nunca lança), pra
/// que o aviso seja totalmente silencioso quando offline/indisponível.
///
/// Espelha o schema do manifest do Cockpit (plano 43/44), com 1 artefato
/// `android`/`apk`. O parsing/validação fica em [UpdateInfo.fromJson].
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    String? manifestUrl,
    Duration timeout = const Duration(seconds: 5),
    Dio? dio,
  })  : manifestUrl = manifestUrl ?? defaultManifestUrl,
        _dio = dio ?? _defaultDio(timeout);

  /// Self-hosted manifest (personal VPS, see `rp-s3/selfhost/`).
  ///
  /// Plain HTTP on a bare IP: a certificate would need a domain, and the app
  /// rejects self-signed ones. Cleartext is allowed for exactly this host by
  /// `res/xml/network_security_config.xml` — everything else still requires
  /// TLS. The APK URLs inside the manifest point at the same host.
  static const String defaultManifestUrl =
      'http://1.15.13.177:3210/downloads/app/latest.json';

  final String manifestUrl;
  final Dio _dio;

  static Dio _defaultDio(Duration timeout) {
    return Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        // Tratamos status não-2xx manualmente — não deixa o Dio lançar.
        validateStatus: (_) => true,
        // Plain: jsonDecode manual, não deixa o parser do Dio tropeçar num
        // corpo vazio/não-JSON num 4xx/5xx.
        responseType: ResponseType.plain,
      ),
    );
  }

  @override
  Future<UpdateInfo?> fetchLatest() async {
    try {
      final response = await _dio.getUri<Object?>(Uri.parse(manifestUrl));
      if (response.statusCode != 200) return null;
      final data = response.data;
      final body = data is String ? data : null;
      if (body == null || body.isEmpty) return null;
      return UpdateInfo.fromJson(jsonDecode(body));
    } catch (_) {
      // sem rede / 404 / JSON inválido / schema errado → silencioso.
      return null;
    }
  }
}
