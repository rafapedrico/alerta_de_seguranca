import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show XFile;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emergency_alert_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'plano_limite_service.dart';

/// Serviço ÚNICO e UNIFICADO de disparo do SOS — reúne, num só lugar, a
/// sequência estritamente sequencial exigida para o botão físico
/// (Volume+ segurado por 3s, tanto com o app frio/bloqueado quanto já
/// rodando) E o botão de SOS manual da aba Segurança:
///
///   P1 (PRIORIDADE MÁXIMA) — captura localização + timestamp e despacha
///       IMEDIATAMENTE, em PARALELO, por TRÊS canais oficiais e
///       independentes:
///         1. SMS nativo direto do aparelho (`SmsManager`, sem custo,
///            nunca depende de conta/nuvem) — ver
///            [EmergencyAlertService.dispararSosComDuplaLocalizacao].
///         2. App-para-App (Push FCM), via `dispararAlertaHibrido` no
///            backend.
///         3. WhatsApp (Twilio), também via `dispararAlertaHibrido`.
///       Os canais 2 e 3 só disparam quando há sessão do Firebase Auth
///       disponível — a política de segurança "Opção A" (login
///       obrigatório a cada cold start, ver `FirebaseAuthService`)
///       desloga a sessão antes mesmo do botão físico poder ser
///       processado quando o app está completamente frio. Nesse caso
///       específico, o canal 1 (SMS) é o ÚNICO que dispara — decisão
///       explícita do produto: a entrega de P1 NUNCA pode depender de
///       autenticação na nuvem.
///   P2 — abre a câmera (UI, ver `CapturaDissuasaoService`) e, assim que
///       a foto for tirada, [dispararFotoCapturada] despacha os MESMOS
///       três canais em paralelo: SMS com o link da foto + localização
///       ([EmergencyAlertService.enviarSmsComLinkDaFoto]), Push e
///       WhatsApp com o link da foto já enviada ao Firebase Storage.
///       Sem sessão (ou se o upload ao Storage falhar por qualquer
///       motivo), os canais 2/3 ficam indisponíveis e o SMS de fallback
///       ([EmergencyAlertService.enviarSmsResgateFoto], sem link real)
///       é usado no lugar.
///   P3/P4 — tela vermelha travada + bloqueio nativo de tela ao deslizar
///       para cima — implementados em `CameraCapturaScreen`, fora deste
///       serviço (são puramente locais, sem dependência de rede/nuvem).
///
/// DEDUPLICAÇÃO ENTRE OS DOIS ENGINES NATIVOS DO BOTÃO FÍSICO: um único
/// aperto físico de Volume+ pode disparar SIMULTANEAMENTE dois
/// `FlutterEngine`/`main()` diferentes no lado nativo Android (ver
/// `VolumeSosService.kt` — o Foreground Service sempre chama
/// `VolumeSosEventBridge.notificarSosDisparado()` E
/// `forcarAberturaLockscreenCameraActivity()` juntos, e esta última
/// SEMPRE cria uma `LockscreenCameraActivity`/engine nova,
/// independentemente de o engine principal já estar rodando). Como são
/// dois isolates/engines Dart totalmente separados, uma flag em memória
/// não os vê um ao outro — por isso [_reivindicarDisparoUnico] usa
/// `SharedPreferences` (arquivo em disco compartilhado por todo o
/// processo do app) como trava: só o primeiro engine a "reivindicar" a
/// janela de alguns segundos realmente despacha o alerta; o outro
/// detecta a reivindicação já feita e não despacha de novo — eliminando
/// o bug real observado de custo/débito "oscilando" conforme o caminho
/// de disparo.
class SosDisparoService {
  SosDisparoService._internal();
  static final SosDisparoService _instance = SosDisparoService._internal();
  factory SosDisparoService() => _instance;

  static const String _chaveUltimoDisparoEpochMs = 'sos_unificado_ultimo_disparo_epoch_ms';

  /// Janela de deduplicação: generosa o suficiente para cobrir a corrida
  /// entre os dois engines nativos do gatilho físico (tipicamente
  /// resolvida em bem menos de 1s), sem risco de bloquear um SEGUNDO
  /// disparo genuíno (ex: usuário aciona de novo, deliberadamente,
  /// poucos segundos depois) — mais curta que o cooldown de 10s já
  /// aplicado no lado nativo do botão de volume.
  static const int _janelaDedupMs = 4000;

  final EmergencyAlertService _emergencyAlertService = EmergencyAlertService();

  /// Executa a sequência unificada completa a partir de P1: captura e
  /// despacha a localização (deduplicado entre engines) e, em seguida —
  /// só depois de P1 estar de fato concluído/persistido — devolve o
  /// controle para o chamador abrir a câmera (P2), respeitando a ordem
  /// estrita P1 -> P2 exigida pelo produto.
  ///
  /// [origem] identifica o gatilho para fins de log/telemetria apenas —
  /// não afeta a lógica de disparo. Use `'sos_fisico'` para os dois
  /// pontos de entrada do botão físico (cold-start via lockscreen e
  /// EventChannel do `VolumeSosService`) e `'sos_manual'` para o botão
  /// da aba Segurança.
  Future<void> executarP1LocalizacaoImediata({required String origem}) async {
    final bool podeDisparar = await PlanoLimiteService().podeDispararAlerta();
    if (!podeDisparar) {
      debugPrint(
          '🚫 [SosDisparoService] Limite mensal de alertas do Plano Gratuito atingido — SOS ($origem) cancelado.');
      return;
    }

    final bool reivindicado = await _reivindicarDisparoUnico();
    if (!reivindicado) {
      debugPrint(
          '🔁 [SosDisparoService] Disparo duplicado detectado (outro engine já iniciou a sequência há poucos segundos) — P1 ($origem) não reenviado.');
      return;
    }

    await PlanoLimiteService().incrementarAlertaUsado();

    final String? uid = FirebaseAuthService().uidAtual;

    // Canal 1 (SEMPRE, independente de sessão): SMS nativo, direto do
    // aparelho — ver EmergencyAlertService.dispararSosComDuplaLocalizacao.
    final smsFuture = _emergencyAlertService.dispararSosComDuplaLocalizacao();

    // Canais 2+3 (App-para-App + WhatsApp): só quando há sessão
    // autenticada — ver documentação da classe.
    Future<void> nuvemFuture = Future.value();
    if (uid != null) {
      debugPrint('☁️ [SosDisparoService] Sessão autenticada — P1 ($origem) também via Push+WhatsApp.');
      nuvemFuture = _dispararLocalizacaoViaNuvem(origem: origem);
    } else {
      debugPrint(
          '📵 [SosDisparoService] Sem sessão autenticada — P1 ($origem) só via SMS (canal oficial único).');
    }

    await Future.wait([smsFuture, nuvemFuture]);
  }

  Future<void> _dispararLocalizacaoViaNuvem({required String origem}) async {
    final Position? posicao = await _obterPosicaoRapida();
    await FirebaseSyncService().dispararAlertaSosFisico(
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      origem: origem,
    );
  }

  /// Executa o P2 da sequência: [foto] já foi capturada pela UI
  /// ([CameraCapturaScreen]) — envia ao Firebase Storage (se houver
  /// sessão autenticada) e, com o link em mãos, despacha os TRÊS canais
  /// oficiais em paralelo: SMS com o link real da foto + localização,
  /// Push e WhatsApp. Sem sessão OU se o upload falhar por qualquer
  /// motivo (sem rede, Storage indisponível, etc.), os canais 2/3 ficam
  /// indisponíveis e o SMS usa a mensagem de fallback (sem link real) —
  /// a entrega de P2 nunca pode depender de um único canal funcionando.
  Future<void> dispararFotoCapturada(XFile foto, {required String origem}) async {
    try {
      await PlanoLimiteService().incrementarFotoUsada();
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Erro no contador de fotos: $e');
    }

    final String? uid = FirebaseAuthService().uidAtual;
    String? fotoUrl;

    if (uid != null) {
      try {
        fotoUrl = await _uploadFotoParaStorage(foto, uid);
        debugPrint('☁️ [SosDisparoService] Foto do SOS ($origem) enviada ao Storage: $fotoUrl');
      } catch (e) {
        debugPrint('⚠️ [SosDisparoService] Falha ao enviar foto ao Storage — SMS usará o fallback sem link: $e');
      }
    } else {
      debugPrint('📵 [SosDisparoService] Sem sessão autenticada — P2 ($origem) só via SMS (canal oficial único).');
    }

    // Canal 1 (SEMPRE): SMS — com o link real da foto quando disponível,
    // ou a mensagem de fallback (sem link) caso contrário.
    final smsFuture = fotoUrl != null
        ? _emergencyAlertService.enviarSmsComLinkDaFoto(fotoUrl)
        : _dispararFotoViaSmsFallback();

    // Canais 2+3 (App-para-App + WhatsApp): só quando o upload deu certo.
    final nuvemFuture = fotoUrl != null
        ? FirebaseSyncService().dispararAlertaSosFoto(fotoUrl: fotoUrl, origem: origem)
        : Future.value(false);

    await Future.wait([smsFuture, nuvemFuture]);
  }

  Future<String> _uploadFotoParaStorage(XFile foto, String uid) async {
    final nomeArquivo = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance.ref('sos_fotos/$uid/$nomeArquivo');
    await ref.putFile(
      File(foto.path),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return ref.getDownloadURL();
  }

  Future<void> _dispararFotoViaSmsFallback() async {
    try {
      await _emergencyAlertService.enviarSmsResgateFoto(
        login: 'familia_resgate',
        senha: 'SOS-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      );
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Falha no fallback de SMS da foto: $e');
    }
  }

  /// Localização "rápida": tenta a última posição em cache (instantânea,
  /// sem acionar o GPS); se não houver nenhuma em cache, faz uma única
  /// tentativa de leitura em tempo real com timeout curto — nunca deixa
  /// P1 esperando o GPS por muito tempo, priorizando velocidade sobre
  /// precisão milimétrica (a mensagem já avisa que é a última localização
  /// conhecida quando aplicável).
  Future<Position?> _obterPosicaoRapida() async {
    try {
      final cache = await Geolocator.getLastKnownPosition();
      if (cache != null) return cache;
    } catch (_) {}

    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Falha ao obter localização para P1: $e');
      return null;
    }
  }

  /// Reivindica, via `SharedPreferences`, o direito exclusivo de disparar
  /// P1 nesta janela de tempo — ver documentação da classe. Retorna
  /// `true` se este engine é o primeiro a chegar (deve prosseguir com o
  /// disparo) ou `false` se outro engine já reivindicou há menos de
  /// [_janelaDedupMs].
  Future<bool> _reivindicarDisparoUnico() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final agora = DateTime.now().millisecondsSinceEpoch;
      final ultimo = prefs.getInt(_chaveUltimoDisparoEpochMs) ?? 0;
      if (agora - ultimo < _janelaDedupMs) {
        return false;
      }
      await prefs.setInt(_chaveUltimoDisparoEpochMs, agora);
      return true;
    } catch (e) {
      // Falha ao acessar SharedPreferences (raríssimo) — na dúvida,
      // prefere disparar (nunca bloquear um SOS real por causa de uma
      // trava de deduplicação que não pôde ser verificada).
      debugPrint('⚠️ [SosDisparoService] Falha ao verificar deduplicação, disparando mesmo assim: $e');
      return true;
    }
  }
}
