import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bloqueio_app_service.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'rastreamento_continuo_service.dart';

/// Resultado da tentativa de exclusão de conta — ver
/// [ExclusaoContaService.excluirContaCompleta].
enum ResultadoExclusaoConta {
  sucesso,
  naoAutenticado,
  erroRede,
}

/// Orquestra o fluxo completo de "Excluir Conta e Dados" (Configurações >
/// Minha Conta), acionado pela `ExcluirContaScreen` depois da confirmação
/// do PIN de segurança:
///
/// 1. Chama a Cloud Function callable `excluirContaCompleta`, que roda
///    com o Admin SDK no servidor e apaga, nessa ordem: os documentos do
///    Firestore (`usuarios/{uid}` + subcoleções + `alarmes_agendados`/
///    `permissoes_monitoramento` referenciando o uid), as fotos do SOS no
///    Storage e, por último, o próprio registro no Firebase
///    Authentication (ver `functions/exclusaoContaService.js` — só o
///    Admin SDK consegue apagar essas coleções, protegidas por
///    `firestore.rules`, e o próprio usuário do Auth sem exigir
///    reautenticação recente).
/// 2. Só DEPOIS de confirmado o sucesso no servidor, limpa os dados
///    locais deste aparelho (SQLite completo via
///    [DatabaseHelper.apagarTudoLocal] + todas as SharedPreferences) e
///    encerra a sessão local do Firebase Auth.
///
/// Ordem deliberada (nuvem primeiro, local depois): se o passo 1 falhar
/// (sem rede, erro do servidor), os dados locais permanecem intactos e o
/// usuário pode tentar de novo — nunca existe um estado intermediário em
/// que os dados locais já foram apagados mas a conta na nuvem continua
/// existindo.
class ExclusaoContaService {
  ExclusaoContaService._internal();
  static final ExclusaoContaService _instance = ExclusaoContaService._internal();
  factory ExclusaoContaService() => _instance;

  Future<ResultadoExclusaoConta> excluirContaCompleta() async {
    if (FirebaseAuthService().uidAtual == null) {
      return ResultadoExclusaoConta.naoAutenticado;
    }

    // A conta some do servidor ANTES do logout local abaixo: o SDK pode
    // deslogar sozinho no meio do caminho (não é sessão encerrada em outro
    // aparelho).
    BloqueioAppService().marcarSaidaVoluntaria();
    // Rastreamento contínuo: para ainda com sessão, gravando o motivo.
    await RastreamentoContinuoService().pararAntesDeSair('conta_excluida');
    try {
      await FirebaseFunctions.instance
          .httpsCallable('excluirContaCompleta')
          .call<Map<String, dynamic>>();
    } on FirebaseFunctionsException catch (e) {
      debugPrint('⚠️ [ExclusaoContaService] Falha ao excluir conta (nuvem): ${e.code} ${e.message}');
      BloqueioAppService().desmarcarSaidaVoluntaria();
      unawaited(RastreamentoContinuoService().retomarAposSaidaCancelada());
      return ResultadoExclusaoConta.erroRede;
    } catch (e) {
      debugPrint('⚠️ [ExclusaoContaService] Falha ao excluir conta (nuvem): $e');
      BloqueioAppService().desmarcarSaidaVoluntaria();
      unawaited(RastreamentoContinuoService().retomarAposSaidaCancelada());
      return ResultadoExclusaoConta.erroRede;
    }

    // A partir daqui, o registro na nuvem já foi excluído com sucesso —
    // qualquer falha na limpeza local abaixo é só best-effort (o usuário
    // já não tem mais conta, de qualquer forma) e nunca deve impedir o
    // retorno de sucesso.
    try {
      await DatabaseHelper().apagarTudoLocal();
    } catch (e) {
      debugPrint('⚠️ [ExclusaoContaService] Falha ao limpar SQLite local: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      debugPrint('⚠️ [ExclusaoContaService] Falha ao limpar SharedPreferences: $e');
    }

    await FirebaseAuthService().logout();

    return ResultadoExclusaoConta.sucesso;
  }
}
