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
import 'retry_upload_service.dart';
import 'sos_dispatch_native_service.dart';

/// Serviço ÚNICO e UNIFICADO de disparo do SOS — reúne, num só lugar, a
/// sequência estritamente sequencial exigida para o botão físico
/// (Volume+ segurado por 3s, tanto com o app frio/bloqueado quanto já
/// rodando) E o botão de SOS manual da aba Segurança:
///
///   P1 (PRIORIDADE MÁXIMA) — captura localização + timestamp e despacha
///       IMEDIATAMENTE, em PARALELO, por DOIS canais oficiais e
///       independentes:
///         1. SMS nativo direto do aparelho (`SmsManager`, sem custo,
///            nunca depende de conta/nuvem) — ver
///            [EmergencyAlertService.dispararSosComDuplaLocalizacao].
///         2. App-para-App (Push FCM), via `dispararAlertaHibrido` no
///            backend.
///       O canal 2 só dispara quando há sessão do Firebase Auth
///       disponível — a política de segurança "Opção A" (login
///       obrigatório a cada cold start, ver `FirebaseAuthService`)
///       desloga a sessão antes mesmo do botão físico poder ser
///       processado quando o app está completamente frio. Nesse caso
///       específico, o canal 1 (SMS) é o ÚNICO que dispara — decisão
///       explícita do produto: a entrega de P1 NUNCA pode depender de
///       autenticação na nuvem.
///   P2 — abre a câmera (UI, ver `CapturaDissuasaoService`) e, assim que
///       a foto for tirada, [dispararFotoCapturada] despacha os MESMOS
///       dois canais em paralelo: SMS com o link da foto + localização
///       ([EmergencyAlertService.enviarSmsComLinkDaFoto]) e Push com o
///       link da foto já enviada ao Firebase Storage. Sem sessão (ou se
///       o upload ao Storage falhar por qualquer motivo), o canal 2 fica
///       indisponível e o SMS de fallback
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
/// o bug real observado de SMS/Push duplicados conforme o caminho de
/// disparo.
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

    // CORREÇÃO DE REGRESSÃO (bug real, 2026-08-07): a versão anterior
    // fazia `await FirebaseAuthService().aguardarUidPronto()` AQUI, ANTES
    // de entrar no Foreground Service abaixo — ou seja, ANTES do SMS
    // (canal 1, que nunca deveria depender de sessão) sequer começar a
    // ser montado. Como [aguardarUidPronto] pode levar até 5s no pior
    // caso, isso deixava o processo até 5s SEM a proteção do Foreground
    // Service nativo — tempo mais que suficiente para o Android matar o
    // processo (tela bloqueada, Doze) antes de QUALQUER coisa ser
    // enviada, "quebrando" o botão físico por completo. Agora: entra no
    // Foreground Service e dispara o SMS IMEDIATAMENTE, e só resolve o
    // uid (com espera, se necessário) DENTRO de [_dispararLocalizacaoViaNuvem],
    // em paralelo ao SMS via `Future.wait` — nunca bloqueando/atrasando
    // o canal 1.
    //
    // JANELA CRÍTICA: do início do envio até aqui embaixo, um Foreground
    // Service nativo (ver SosDispatchNativeService) mantém o PROCESSO do
    // app vivo — sem isso, o SMS/upload em voo seria perdido caso o
    // Android decidisse matar o processo no meio do envio (memória
    // baixa, Doze agressivo, app forçado a fechar logo após o toque no
    // botão de pânico). Nunca depende da Activity/engine continuar em
    // primeiro plano.
    await SosDispatchNativeService().executarComServicoAtivo(() async {
      // Canal 1 (SEMPRE, independente de sessão, disparado NA HORA — sem
      // nenhum `await` antes dele nesta função): SMS nativo, direto do
      // aparelho — ver EmergencyAlertService.dispararSosComDuplaLocalizacao.
      // Roda numa child Future totalmente independente da nuvem: uma
      // falha/demora na chamada de rede abaixo NUNCA atrasa ou cancela o
      // SMS, que não depende de internet nenhuma (rádio GSM puro).
      final smsFuture = _emergencyAlertService.dispararSosComDuplaLocalizacao();

      // Canal 2 (App-para-App): roda em PARALELO ao SMS
      // acima — a eventual espera pela sessão (ver
      // FirebaseAuthService.aguardarUidPronto) acontece só aqui dentro,
      // nunca atrasando o canal 1.
      final nuvemFuture = _dispararLocalizacaoViaNuvem(origem: origem);

      await Future.wait([smsFuture, nuvemFuture]);
    });
  }

  Future<void> _dispararLocalizacaoViaNuvem({required String origem}) async {
    final String? uid = await FirebaseAuthService().aguardarUidPronto();
    if (uid == null) {
      debugPrint(
          '📵 [SosDisparoService] Sem sessão autenticada — P1 só via SMS (canal oficial único).');
      return;
    }
    debugPrint('☁️ [SosDisparoService] Sessão autenticada — P1 também via Push.');
    final Position? posicao = await _obterPosicaoRapida();
    await FirebaseSyncService().dispararAlertaSosFisico(
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      origem: origem,
    );
  }

  /// Executa o P2 da sequência: [foto] já foi capturada pela UI
  /// ([CameraCapturaScreen]) — envia ao Firebase Storage (se houver
  /// sessão autenticada) e, com o link em mãos, despacha os DOIS canais
  /// oficiais em paralelo: SMS com o link real da foto + localização e
  /// Push. Sem sessão OU se o upload falhar por qualquer motivo (sem
  /// rede, Storage indisponível, etc.), o canal 2 fica indisponível e o
  /// SMS usa a mensagem de fallback (sem link real) — a entrega de P2
  /// nunca pode depender de um único canal funcionando.
  Future<void> dispararFotoCapturada(XFile foto, {required String origem}) async {
    try {
      await PlanoLimiteService().incrementarFotoUsada();
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Erro no contador de fotos: $e');
    }

    String? fotoUrl;

    // Mesma janela crítica do P1 (ver executarP1LocalizacaoImediata):
    // Foreground Service nativo ativo durante todo o upload/SMS, para
    // que uma morte do processo no meio do envio não perca o trabalho.
    //
    // CORREÇÃO DE REGRESSÃO (mesmo bug do P1, 2026-08-07): [aguardarUidPronto]
    // (ver documentação completa em [executarP1LocalizacaoImediata]) DEVE
    // ser chamado DENTRO deste bloco protegido pelo Foreground Service,
    // nunca antes — chamá-lo antes deixava o processo até 5s sem essa
    // proteção, arriscando ser morto pelo Android (tela bloqueada, Doze)
    // antes até do SMS de fallback (que nem depende de sessão) ser
    // enviado.
    await SosDispatchNativeService().executarComServicoAtivo(() async {
      final String? uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid != null) {
        try {
          fotoUrl = await _uploadFotoParaStorage(foto, uid);
          debugPrint('☁️ [SosDisparoService] Foto do SOS ($origem) enviada ao Storage: $fotoUrl');
        } catch (e) {
          // RESILIÊNCIA OFFLINE: a falha de rede (sem Wi-Fi/4G, Storage
          // indisponível, etc.) NUNCA interrompe o fluxo — é capturada
          // aqui, o SMS abaixo segue via GSM normalmente (independente
          // de internet) e o payload do upload é salvo localmente para
          // ser reenviado automaticamente assim que a conectividade for
          // reestabelecida (ver RetryUploadService).
          debugPrint('⚠️ [SosDisparoService] Falha ao enviar foto ao Storage — SMS usará o fallback sem link. '
              'Payload salvo para retry automático: $e');
          try {
            await RetryUploadService().enfileirar(fotoOriginal: foto, origem: origem);
          } catch (e2) {
            debugPrint('⚠️ [SosDisparoService] Falha ao enfileirar retry do upload: $e2');
          }
        }
      } else {
        debugPrint('📵 [SosDisparoService] Sem sessão autenticada — P2 ($origem) só via SMS (canal oficial único).');
      }

      // Canal 1 (SEMPRE): SMS — com o link real da foto quando
      // disponível, ou a mensagem de fallback (sem link) caso
      // contrário. Child Future totalmente independente da nuvem
      // abaixo — nunca espera/depende dela.
      final smsFuture = fotoUrl != null
          ? _emergencyAlertService.enviarSmsComLinkDaFoto(fotoUrl!)
          : _dispararFotoViaSmsFallback();

      // Canal 2 (App-para-App): só quando o upload deu certo.
      final nuvemFuture = fotoUrl != null
          ? FirebaseSyncService().dispararAlertaSosFoto(fotoUrl: fotoUrl!, origem: origem)
          : Future.value(false);

      await Future.wait([smsFuture, nuvemFuture]);
    });
  }

  /// Reenvia uma foto de SOS que ficou pendente na fila de retry local
  /// (ver [RetryUploadService]) — mesma lógica de upload+despacho de
  /// [dispararFotoCapturada], mas a partir de um arquivo já copiado para
  /// um caminho permanente em disco (o arquivo temporário original da
  /// captura pode já ter sido reciclado pelo SO). Retorna `true` só
  /// quando o upload E o despacho (SMS com link + nuvem) forem
  /// concluídos com sucesso — [RetryUploadService] só remove o item da
  /// fila local nesse caso; qualquer outra falha mantém o item na fila
  /// para a próxima tentativa periódica.
  Future<bool> tentarReenviarFotoEnfileirada({
    required String fotoPathLocal,
    required String origem,
  }) async {
    final String? uid = FirebaseAuthService().uidAtual;
    if (uid == null) {
      debugPrint('📵 [SosDisparoService] Retry de upload adiado — sem sessão autenticada no momento.');
      return false;
    }

    String fotoUrl;
    try {
      fotoUrl = await _uploadFotoParaStorage(XFile(fotoPathLocal), uid);
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Retry de upload falhou de novo (mantido na fila): $e');
      return false;
    }

    try {
      await Future.wait([
        _emergencyAlertService.enviarSmsComLinkDaFoto(fotoUrl),
        FirebaseSyncService().dispararAlertaSosFoto(fotoUrl: fotoUrl, origem: origem),
      ]);
      debugPrint('✅ [SosDisparoService] Retry de upload ($origem) concluído com sucesso: $fotoUrl');
      return true;
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Retry de upload — Storage ok mas despacho falhou (mantido na fila): $e');
      return false;
    }
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
