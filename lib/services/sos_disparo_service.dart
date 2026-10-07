import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show XFile;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alerta_desarme_service.dart';
import 'database_helper.dart';
import 'emergency_alert_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'historico_alertas_service.dart';
import 'l10n_headless_service.dart';
import 'location_service.dart';
import 'retry_upload_service.dart';
import 'sos_dispatch_native_service.dart';

/// Estado de um SOS em andamento — compartilhado pela sequência visual
/// (`SosEmAndamentoScreen` → `CameraCapturaScreen` → tela vermelha) para
/// que cada aviso diga só a verdade: o que foi de fato confirmado.
class SessaoSos {
  SessaoSos({required this.alertaId, required this.origem});

  /// Id do alerta (documento do Firestore e entrada do histórico).
  final String alertaId;

  /// `sos_manual` (botão do app) ou `sos_fisico` (Volume+).
  final String origem;

  double? latitude;
  double? longitude;
  double? precisao;

  /// Nenhum contato de emergência cadastrado: nada foi enviado.
  bool semContatos = false;

  /// Push ou SMS da localização confirmado (pode chegar depois do aviso
  /// de "sem conexão").
  bool localizacaoConfirmada = false;

  /// Foto enviada de verdade (Storage + contatos).
  bool fotoEnviada = false;

  /// Completa com `true` na primeira confirmação (push OU SMS) e com
  /// `false` quando os dois canais terminaram sem confirmação.
  final Completer<bool> confirmacao = Completer<bool>();
}

/// Sequência do SOS (botão do app e botão físico Volume+):
///
/// 1. [iniciar] — envia NA HORA, sem confirmação, a localização EXATA
///    (cache de até 30 s e precisão até 50 m, senão leitura nova de alta
///    precisão com limite de 5 s) por SMS e push, com a MESMA posição; a
///    entrada do histórico nasce `enviando` e vira `enviado` com a
///    confirmação real (rádio do SMS ou Firestore) ou `pendente`.
/// 2. [enviarFoto] — foto para o Firebase (limite de 15 s) e, com o link
///    verdadeiro, para os contatos; sem upload, vai para a fila de reenvio
///    (sem SMS de foto) e os contatos recebem o link quando ela subir.
///
/// Um único SOS por vez ([emAndamento]) e um único disparo entre os dois
/// engines do botão físico (trava em disco, ver [_reivindicarDisparoUnico]).
class SosDisparoService {
  SosDisparoService._internal();
  static final SosDisparoService _instance = SosDisparoService._internal();
  factory SosDisparoService() => _instance;

  static const String _chaveUltimoDisparoEpochMs = 'sos_unificado_ultimo_disparo_epoch_ms';

  /// Janela de deduplicação entre os dois engines do botão físico.
  static const int _janelaDedupMs = 4000;

  /// Limite do upload da foto antes de ir para a fila de reenvio.
  static const Duration limiteUploadFoto = Duration(seconds: 15);

  final EmergencyAlertService _sms = EmergencyAlertService();

  SessaoSos? _sessaoAtual;

  /// `true` enquanto um SOS estiver em andamento (proteção contra toque
  /// duplo no botão).
  bool get emAndamento => _sessaoAtual != null;

  SessaoSos? get sessaoAtual => _sessaoAtual;

  /// Libera um novo SOS (a tela vermelha foi exibida/fechada).
  void encerrarSessao() => _sessaoAtual = null;

  /// Inicia o SOS — devolve `null` se já houver um em andamento ou outro
  /// engine acabou de disparar o mesmo aperto do botão físico.
  Future<SessaoSos?> iniciar({required String origem, String? contexto}) async {
    if (_sessaoAtual != null) {
      debugPrint('🔁 [SOS] Já há um SOS em andamento — toque ignorado.');
      return null;
    }
    final sessao = SessaoSos(alertaId: AlertaDesarmeService.novoAlertaId(), origem: origem);
    _sessaoAtual = sessao;
    if (!await _reivindicarDisparoUnico()) {
      debugPrint('🔁 [SOS] Outro engine já disparou este SOS — não reenviado.');
      _sessaoAtual = null;
      return null;
    }
    unawaited(SosDispatchNativeService().executarComServicoAtivo(
      () => _enviarLocalizacao(sessao, contexto: contexto),
    ));
    return sessao;
  }

  Future<void> _enviarLocalizacao(SessaoSos sessao, {String? contexto}) async {
    final l10n = await L10nHeadlessService.obter();
    try {
      var textoUsuario = (contexto ?? '').trim();
      if (textoUsuario.isEmpty) {
        try {
          final config = await DatabaseHelper().getUserConfig();
          textoUsuario = ((config?['contexto_timer_ativo'] as String?) ?? '').trim();
        } catch (_) {}
      }

      // Sem contatos: avisar o usuário, nunca dizer que enviou.
      sessao.semContatos = !await _sms.temContatos();

      final posicaoAlerta = await LocationService().obterPosicaoParaAlerta();
      final posicao = posicaoAlerta.posicao;
      sessao
        ..latitude = posicao?.latitude
        ..longitude = posicao?.longitude
        ..precisao = posicao?.accuracy;

      final fisico = sessao.origem == TipoAlertaHistorico.sosFisico;
      final tipo = fisico ? TipoAlertaHistorico.sosFisico : TipoAlertaHistorico.sosManual;
      await HistoricoAlertasService().criarAlerta(
        alertaId: sessao.alertaId,
        tipo: tipo,
        titulo: HistoricoAlertasService.tituloPorTipo(tipo, l10n),
        descricao: HistoricoAlertasService.tituloPorTipo(tipo, l10n),
        contexto: textoUsuario,
        latitude: posicao?.latitude,
        longitude: posicao?.longitude,
        precisao: posicao?.accuracy,
      );

      final localizacao = _sms.textoLocalizacao(posicao, l10n);
      var mensagem = fisico ? l10n.smsSosFisicoCorpo(localizacao) : l10n.smsSosCorpo(localizacao);
      if (textoUsuario.isNotEmpty) mensagem = '$mensagem\n${l10n.smsTextoDoUsuario(textoUsuario)}';

      // Mesma posição nos dois canais; a primeira confirmação libera a tela.
      final smsFuture = _sms.enviarSms(mensagem).then((r) {
        if (r.semContatos) sessao.semContatos = true;
        if (r.confirmado) _confirmar(sessao);
        return r;
      });
      final nuvemFuture = _enviarPush(sessao, textoUsuario).then((r) {
        if (r.confirmado) _confirmar(sessao);
        return r;
      });
      final sms = await smsFuture;
      final nuvem = await nuvemFuture;
      if (!sessao.confirmacao.isCompleted) sessao.confirmacao.complete(false);

      final status = (sms.confirmado || nuvem.confirmado)
          ? StatusAlertaHistorico.enviado
          : (nuvem.naFila || sms.tentados > 0)
              ? StatusAlertaHistorico.pendente
              : StatusAlertaHistorico.falhou;
      await HistoricoAlertasService().marcarStatus(sessao.alertaId, status);

      if (!posicaoAlerta.precisa && posicaoAlerta.atualizacao != null) {
        final precisa = await posicaoAlerta.atualizacao!;
        if (precisa != null) {
          sessao
            ..latitude = precisa.latitude
            ..longitude = precisa.longitude
            ..precisao = precisa.accuracy;
          await HistoricoAlertasService().atualizarLocalizacao(
            sessao.alertaId,
            latitude: precisa.latitude,
            longitude: precisa.longitude,
            precisao: precisa.accuracy,
          );
          await FirebaseSyncService().atualizarPosicaoPrecisaDoAlerta(
            latitude: precisa.latitude,
            longitude: precisa.longitude,
          );
        }
      }
    } catch (e) {
      debugPrint('⚠️ [SOS] Falha no envio da localização: $e');
      if (!sessao.confirmacao.isCompleted) sessao.confirmacao.complete(false);
    }
  }

  void _confirmar(SessaoSos sessao) {
    if (sessao.semContatos) return;
    sessao.localizacaoConfirmada = true;
    if (!sessao.confirmacao.isCompleted) sessao.confirmacao.complete(true);
  }

  Future<ResultadoEnvioNuvem> _enviarPush(SessaoSos sessao, String textoUsuario) async {
    final uid = FirebaseAuthService().uidAtual ?? await FirebaseAuthService().aguardarUidPronto();
    if (uid == null) {
      debugPrint('📵 [SOS] Sem sessão — localização só por SMS.');
      return ResultadoEnvioNuvem.semEnvio;
    }
    return FirebaseSyncService().dispararAlertaSosFisico(
      alertaId: sessao.alertaId,
      latitude: sessao.latitude,
      longitude: sessao.longitude,
      precisao: sessao.precisao,
      origem: sessao.origem,
      contextoPersonalizado: textoUsuario,
    );
  }

  /// Foto do SOS: cópia na pasta privada (histórico), upload com limite de
  /// 15 s e, com o link verdadeiro, push + SMS. Sem upload: fila de reenvio
  /// (com a posição e o alertaId), sem SMS de foto. `true` = enviada.
  Future<bool> enviarFoto(XFile foto, SessaoSos sessao) async {
    await HistoricoAlertasService().anexarFoto(sessao.alertaId, fotoArquivo: foto.path);
    var enviada = false;
    await SosDispatchNativeService().executarComServicoAtivo(() async {
      final uid = FirebaseAuthService().uidAtual ?? await FirebaseAuthService().aguardarUidPronto();
      String? fotoUrl;
      if (uid != null) {
        try {
          fotoUrl = await _uploadFotoParaStorage(XFile(foto.path), uid).timeout(limiteUploadFoto);
        } catch (e) {
          debugPrint('⚠️ [SOS] Upload da foto não concluído em ${limiteUploadFoto.inSeconds}s: $e');
        }
      }
      if (fotoUrl == null) {
        await RetryUploadService().enfileirar(
          fotoOriginal: foto,
          origem: sessao.origem,
          latitude: sessao.latitude,
          longitude: sessao.longitude,
          alertaId: sessao.alertaId,
        );
        return;
      }
      await _despacharFoto(
        fotoUrl: fotoUrl,
        origem: sessao.origem,
        alertaId: sessao.alertaId,
        latitude: sessao.latitude,
        longitude: sessao.longitude,
      );
      enviada = true;
    });
    sessao.fotoEnviada = enviada;
    return enviada;
  }

  Future<void> _despacharFoto({
    required String fotoUrl,
    required String origem,
    required String alertaId,
    double? latitude,
    double? longitude,
  }) async {
    await HistoricoAlertasService().anexarFoto(alertaId, fotoUrl: fotoUrl);
    final link = await _linkCurtoParaSms(fotoUrl);
    await Future.wait([
      _sms.enviarSmsComLinkDaFoto(link),
      FirebaseSyncService().dispararAlertaSosFoto(
        fotoUrl: fotoUrl,
        origem: origem,
        alertaIdSos: alertaId,
        latitude: latitude,
        longitude: longitude,
      ),
    ]);
  }

  /// Reenvio da fila (ver [RetryUploadService]): upload e, com o link
  /// verdadeiro, push + SMS e a foto anexada à MESMA entrada do histórico.
  Future<bool> tentarReenviarFotoEnfileirada({
    required String fotoPathLocal,
    required String origem,
    String? alertaId,
    double? latitude,
    double? longitude,
  }) async {
    final uid = FirebaseAuthService().uidAtual;
    if (uid == null) {
      debugPrint('📵 [SOS] Reenvio da foto adiado — sem sessão.');
      return false;
    }
    String fotoUrl;
    try {
      fotoUrl = await _uploadFotoParaStorage(XFile(fotoPathLocal), uid);
    } catch (e) {
      debugPrint('⚠️ [SOS] Reenvio da foto falhou de novo (mantido na fila): $e');
      return false;
    }
    try {
      await _despacharFoto(
        fotoUrl: fotoUrl,
        origem: origem,
        alertaId: alertaId ?? HistoricoAlertasService.novoIdLocal(),
        latitude: latitude,
        longitude: longitude,
      );
      return true;
    } catch (e) {
      debugPrint('⚠️ [SOS] Foto no Storage, mas o envio aos contatos falhou (mantido na fila): $e');
      return false;
    }
  }

  /// Link curto (`meuguardiaox.com.br/f/<código>`) para o SMS da foto
  /// caber numa parte só (SMS multi-parte não chegava ao iPhone). Qualquer
  /// falha usa a URL completa do Storage.
  Future<String> _linkCurtoParaSms(String fotoUrlLongo) async {
    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('criarLinkCurtoFoto')
          .call<Map<String, dynamic>>({'fotoUrl': fotoUrlLongo})
          .timeout(const Duration(seconds: 8));
      final String? shortId = resultado.data['shortId'] as String?;
      if (shortId != null && shortId.isNotEmpty) {
        return 'https://www.meuguardiaox.com.br/f/$shortId';
      }
    } catch (e) {
      debugPrint('⚠️ [SOS] Falha ao encurtar o link da foto (usa a URL completa): $e');
    }
    return fotoUrlLongo;
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

  /// Trava em disco (compartilhada pelos engines do mesmo processo) para
  /// um único disparo por aperto do botão físico.
  Future<bool> _reivindicarDisparoUnico() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final agora = DateTime.now().millisecondsSinceEpoch;
      final ultimo = prefs.getInt(_chaveUltimoDisparoEpochMs) ?? 0;
      if (agora - ultimo < _janelaDedupMs) return false;
      await prefs.setInt(_chaveUltimoDisparoEpochMs, agora);
      return true;
    } catch (e) {
      debugPrint('⚠️ [SOS] Falha ao verificar a deduplicação, disparando mesmo assim: $e');
      return true;
    }
  }
}
