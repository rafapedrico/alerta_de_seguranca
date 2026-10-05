import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resultado de `registrarIndicacao` (contrato em `functions/indicacaoService.js`
/// do servidor): os motivos devolvidos pela callable, mais [erro] quando a
/// chamada nem chegou a responder (sem rede, timeout).
enum MotivoIndicacao { ok, codigoInvalido, autoindicacao, jaVinculado, jaPremium, erro }

/// Programa de Indicação, lado do app. A recompensa é só do afiliado (que
/// divulga fora do app): o app nunca mostra valor nem promessa de recompensa,
/// só vincula o usuário ao código.
///
/// Duas origens, como no contrato do servidor:
/// - `play_referrer`: o link do site (`/i/{CODIGO}`) abre a Play Store com
///   `referrer=ref=CODIGO`. Lido UMA vez por instalação na primeira abertura
///   ([iniciar]), guardado localmente e enviado assim que houver sessão —
///   uma tentativa só, sem nunca travar login ou cadastro.
/// - `digitado`: o campo "Tem um código de indicação?" do cadastro e de
///   Configurações ([registrar]).
class IndicacaoService {
  IndicacaoService._internal();
  static final IndicacaoService _instance = IndicacaoService._internal();
  factory IndicacaoService() => _instance;

  static const String _chaveReferrerLido = 'indicacao_referrer_lido';
  static const String _chaveCodigoReferrer = 'indicacao_codigo_referrer';
  static const String _chaveReferrerEnviado = 'indicacao_referrer_enviado';

  static const String origemReferrer = 'play_referrer';
  static const String origemDigitado = 'digitado';

  /// Mesmo alfabeto do servidor (sem O/0, I/1, L), 6 caracteres.
  static final RegExp _formatoCodigo = RegExp(r'^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$');

  bool _iniciado = false;
  Future<String?>? _leituraReferrer;
  Future<MotivoIndicacao?>? _envioReferrer;

  /// Normaliza como o servidor (aceita minúsculas, espaços e hífen).
  static String normalizarCodigo(String codigo) =>
      codigo.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

  /// `true` quando o código tem o formato do servidor (6 caracteres do
  /// alfabeto) — só para evitar chamadas inúteis; quem decide é o servidor.
  static bool formatoValido(String codigo) => _formatoCodigo.hasMatch(normalizarCodigo(codigo));

  /// Extrai o código do referrer da Play Store (`ref=CODIGO`, possivelmente
  /// junto de parâmetros `utm_*`). `null` sem `ref` ou fora do formato.
  static String? codigoDoReferrer(String? referrer) {
    if (referrer == null || referrer.trim().isEmpty) return null;
    String? valor;
    try {
      valor = Uri.splitQueryString(referrer)['ref'];
    } catch (_) {
      valor = null;
    }
    if (valor == null) return null;
    final codigo = normalizarCodigo(valor);
    return _formatoCodigo.hasMatch(codigo) ? codigo : null;
  }

  /// Chamado depois do `Firebase.initializeApp()`. Idempotente.
  void iniciar() {
    if (_iniciado || Firebase.apps.isEmpty) return;
    _iniciado = true;
    unawaited(codigoDoReferrerGuardado());
    FirebaseAuth.instance.authStateChanges().listen((usuario) {
      if (usuario != null) unawaited(enviarReferrerSePendente());
    });
  }

  /// Código vindo do Install Referrer (lido na primeira abertura e
  /// guardado). `null` se não veio por um link de indicação.
  Future<String?> codigoDoReferrerGuardado() => _leituraReferrer ??= _lerReferrerUmaVez();

  Future<String?> _lerReferrerUmaVez() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveReferrerLido) ?? false) {
        return prefs.getString(_chaveCodigoReferrer);
      }
      String? codigo;
      if (Platform.isAndroid) {
        try {
          final detalhes = await PlayInstallReferrer.installReferrer
              .timeout(const Duration(seconds: 10));
          codigo = codigoDoReferrer(detalhes.installReferrer);
        } catch (e) {
          // Instalação fora da Play Store (APK), serviço indisponível…
          debugPrint('🔗 [Indicacao] Install Referrer indisponível: $e');
        }
      }
      // Lido de vez nesta instalação, com ou sem código.
      await prefs.setBool(_chaveReferrerLido, true);
      if (codigo != null) await prefs.setString(_chaveCodigoReferrer, codigo);
      return codigo;
    } catch (e) {
      debugPrint('⚠️ [Indicacao] Falha ao ler o Install Referrer: $e');
      return null;
    }
  }

  /// Envia o código do Install Referrer (uma tentativa por instalação).
  /// `null` quando não havia nada a enviar (sem código, sem sessão ou já
  /// tentado antes). Quem chamar de novo recebe o MESMO resultado.
  Future<MotivoIndicacao?> enviarReferrerSePendente() {
    if (FirebaseAuth.instance.currentUser == null) return Future.value(null);
    return _envioReferrer ??= _enviarReferrer();
  }

  Future<MotivoIndicacao?> _enviarReferrer() async {
    try {
      final codigo = await codigoDoReferrerGuardado();
      if (codigo == null) return null;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveReferrerEnviado) ?? false) return null;
      // Marcado ANTES da chamada: uma tentativa só, mesmo se o app fechar.
      await prefs.setBool(_chaveReferrerEnviado, true);
      final motivo = await registrar(codigo, origem: origemReferrer);
      debugPrint('🔗 [Indicacao] Código do Install Referrer enviado: $motivo');
      return motivo;
    } catch (e) {
      debugPrint('⚠️ [Indicacao] Falha ao enviar o código do Install Referrer: $e');
      return MotivoIndicacao.erro;
    }
  }

  /// O usuário trocou ou apagou, no cadastro, o código que veio do link:
  /// o envio automático do Install Referrer não acontece mais.
  Future<void> descartarReferrer() async {
    _envioReferrer = Future.value(null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chaveReferrerEnviado, true);
    } catch (_) {}
  }

  /// Chama `registrarIndicacao({codigo, origem})`. Nunca lança: recusas
  /// voltam como motivo; falha de rede/timeout como [MotivoIndicacao.erro].
  Future<MotivoIndicacao> registrar(String codigo, {required String origem}) async {
    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('registrarIndicacao')
          .call<Map<String, dynamic>>({'codigo': normalizarCodigo(codigo), 'origem': origem})
          .timeout(const Duration(seconds: 15));
      return motivoDoServidor(resultado.data['motivo'] as String?);
    } catch (e) {
      debugPrint('⚠️ [Indicacao] registrarIndicacao falhou: $e');
      return MotivoIndicacao.erro;
    }
  }

  static MotivoIndicacao motivoDoServidor(String? motivo) => switch (motivo) {
        'ok' => MotivoIndicacao.ok,
        'codigo_invalido' => MotivoIndicacao.codigoInvalido,
        'autoindicacao' => MotivoIndicacao.autoindicacao,
        'ja_vinculado' => MotivoIndicacao.jaVinculado,
        'ja_premium' => MotivoIndicacao.jaPremium,
        _ => MotivoIndicacao.erro,
      };

  /// O campo de Configurações só aparece para quem ainda não é Premium nem
  /// tem vínculo (`usuarios/{uid}.isPremium`/`indicadoPor`). Na dúvida (sem
  /// rede), não mostra.
  Future<bool> podeInformarCodigo() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 10));
      final dados = snap.data() ?? const <String, dynamic>{};
      final indicado = (dados['indicadoPor'] as String?)?.isNotEmpty ?? false;
      return dados['isPremium'] != true && !indicado;
    } catch (e) {
      debugPrint('⚠️ [Indicacao] Falha ao conferir o vínculo: $e');
      return false;
    }
  }
}
