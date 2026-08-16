import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'location_service.dart';

/// Serviço central da aba Monitoramento: gerencia a lista LOCAL de
/// contatos (SQLite, tabela `monitoramento_contatos`, TOTALMENTE
/// independente dos contatos de emergência do alarme/pânico) e a
/// permissão bilateral de compartilhamento de localização GPS em tempo
/// real com cada um deles, persistida na nuvem em
/// `permissoes_monitoramento/{uidAlvo}__{uidSolicitante}` (ver
/// `firestore.rules` e `functions/monitoramentoService.js`).
///
/// Cada contato pode ter até DUAS relações de permissão independentes,
/// cada uma com seu próprio ciclo de vida:
/// - Bloco A ("ver localização dele"): documento onde EU sou
///   `uidSolicitante` — ver [solicitarLocalizacao].
/// - Compartilhamento ("compartilhar minha localização com ele"):
///   documento onde EU sou `uidAlvo` — pode ser concedido/bloqueado
///   REATIVAMENTE (ele me solicita, eu respondo — ver
///   [responderSolicitacao]) ou PROATIVAMENTE, direto no switch de cada
///   contato, mesmo sem ele nunca ter solicitado — ver
///   [definirPermissaoCompartilhamento].
///
/// As colunas `status_ver_localizacao`/`status_compartilhamento` da
/// tabela local são apenas um CACHE para exibição imediata/offline — a
/// fonte de verdade é sempre o documento no Firestore, e a UI (Etapa 2)
/// deve preferir os streams em tempo real ([statusPermissaoStream],
/// [pedidosRecebidosPendentesStream]) sempre que houver conexão.
class MonitoramentoService {
  MonitoramentoService._internal();
  static final MonitoramentoService _instance =
      MonitoramentoService._internal();
  factory MonitoramentoService() => _instance;

  static const String colecaoPermissoes = 'permissoes_monitoramento';

  static const String statusPendente = 'pendente';
  static const String statusAprovado = 'aprovado';
  static const String statusNegado = 'negado';
  static const String statusBloqueado = 'bloqueado';
  static const String statusExpirado = 'expirado';

  /// Valores padrão do cache local antes de qualquer solicitação existir.
  static const String statusVerNaoSolicitado = 'nao_solicitado';
  static const String statusCompartilharInexistente = 'inexistente';

  /// Incrementado a cada alteração relevante na lista local de contatos
  /// ou em seus status em cache — mesmo padrão de
  /// [ContatosEmergenciaService.versaoContatos], consumido pela
  /// MonitoramentoTab via [ValueListenableBuilder]/`addListener`.
  static final ValueNotifier<int> versaoMonitoramento = ValueNotifier<int>(0);

  static void _notificarAlteracao() => versaoMonitoramento.value++;

  String? get _meuUid => FirebaseAuthService().uidAtual;

  bool get _firebaseDisponivel => Firebase.apps.isNotEmpty && _meuUid != null;

  // ==========================================================
  // CONTATOS LOCAIS (SQLite) — gerenciamento independente
  // ==========================================================

  Future<List<Map<String, dynamic>>> listarContatos() =>
      DatabaseHelper().listarContatosMonitoramento();

  /// Adiciona um novo contato à lista local. [telefone] é normalizado
  /// para E.164 (mesmo critério de `CadastroScreen`/`smsGateway.js`) antes
  /// de ser salvo, garantindo que corresponda ao que a Cloud Function vai
  /// procurar em `usuarios.telefone`.
  Future<int> adicionarContato({
    required String nome,
    required String telefone,
  }) async {
    final id = await DatabaseHelper().inserirContatoMonitoramento(
      nome: nome,
      telefone: _normalizarTelefoneE164(telefone),
    );
    _notificarAlteracao();
    return id;
  }

  Future<void> editarNomeContato(int id, String novoNome) async {
    await DatabaseHelper().atualizarNomeContatoMonitoramento(id, novoNome);
    _notificarAlteracao();
  }

  /// Remove o contato da lista local E revoga IMEDIATAMENTE, no Firestore,
  /// qualquer permissão de compartilhamento que eu tenha concedido a ele
  /// (reaproveita [definirPermissaoCompartilhamento] com `permitir: false`
  /// — mesmo caminho do switch de compartilhamento).
  ///
  /// CORREÇÃO DE FALHA CRÍTICA DE PRIVACIDADE (pedido do usuário,
  /// 2026-08-16): antes, este método só apagava a linha local do SQLite —
  /// o documento em `permissoes_monitoramento` continuava com `status:
  /// 'aprovado'` no Firestore, então o contato removido CONTINUAVA
  /// conseguindo ver minha localização em tempo real (o `StreamBuilder` do
  /// APARELHO DELE escuta esse documento diretamente, nunca minha lista
  /// local). Agora a revogação é chamada SEMPRE, incondicionalmente, ANTES
  /// de apagar a linha local (que fornece o telefone usado para resolver
  /// o documento certo) — nunca dependendo do cache local
  /// `status_compartilhamento`, que pode estar desatualizado.
  ///
  /// Depois de revogado, o status volta a um estado não aprovado — só
  /// uma NOVA solicitação (ver [solicitarLocalizacao]), com uma NOVA
  /// aprovação explícita minha, pode restabelecer o compartilhamento.
  ///
  /// Best-effort quanto à revogação: a remoção LOCAL sempre acontece
  /// (nunca deixa um contato "preso" na lista por falta de rede), mas
  /// retorna `false` quando a revogação em si falhou de verdade (erro de
  /// rede/servidor — não confundir com "não havia nada para revogar"),
  /// para que a UI ([MonitoramentoTab._excluirContato]) alerte o usuário
  /// a tentar de novo em vez de presumir silenciosamente que está seguro.
  Future<bool> removerContato(int id) async {
    final contato = await DatabaseHelper().buscarContatoMonitoramentoPorId(id);

    bool revogacaoOk = true;
    if (contato != null) {
      final resultado = await definirPermissaoCompartilhamento(
        idContatoLocal: id,
        permitir: false,
      );
      // 'numero_nao_encontrado'/'proprio_numero' não são falhas de
      // revogação — significam que nunca poderia ter existido uma
      // permissão de verdade para esse contato. Só 'erro' (rede/servidor)
      // é reportado como falha real ao chamador.
      revogacaoOk = resultado != 'erro';
    }

    await DatabaseHelper().deletarContatoMonitoramento(id);
    _notificarAlteracao();
    return revogacaoOk;
  }

  // ==========================================================
  // BLOCO A — "Ver localização dele" (eu = uidSolicitante)
  // ==========================================================

  /// Solicita a localização do contato local [idContatoLocal], via Cloud
  /// Function callable `solicitarMonitoramento`. Resolve o `uid` pelo
  /// telefone SERVER-SIDE (o cliente nunca consulta `usuarios` por
  /// telefone diretamente, ver `firestore.rules`).
  ///
  /// Retorna:
  /// - `'enviada'`: solicitação criada/reenviada, aguardando aprovação.
  /// - `'ja_aprovado'`: já havia permissão aprovada — nada a fazer.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'bloqueado_pelo_alvo'`: o contato me bloqueou (ver
  ///   [definirBloqueioPorTelefone]) — a Cloud Function nem chega a criar
  ///   um ciclo pendente nem a enviar Push.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> solicitarLocalizacao(int idContatoLocal) async {
    if (!_firebaseDisponivel) return 'erro';

    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('solicitarMonitoramento')
          .call<Map<String, dynamic>>({
        'telefoneAlvo': contato['telefone'],
      });

      final dados = resultado.data;
      final uidAlvo = dados['uidAlvo'] as String?;
      final status = dados['status'] as String?;

      if (uidAlvo != null) {
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidAlvo);
      }
      if (status != null) {
        await DatabaseHelper()
            .atualizarStatusVerLocalizacao(idContatoLocal, status);
      }
      _notificarAlteracao();

      return status == statusAprovado ? 'ja_aprovado' : 'enviada';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      if (e.code == 'permission-denied') return 'bloqueado_pelo_alvo';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao solicitar localização: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Falha ao solicitar localização: $e');
      return 'erro';
    }
  }

  // ==========================================================
  // BLOCO B — "Compartilhar minha localização" (eu = uidAlvo)
  // ==========================================================

  /// Stream em tempo real das solicitações PENDENTES recebidas por mim —
  /// usada para exibir "Fulano está solicitando a sua localização.
  /// Permitir ou Bloquear?" (ver requisito de fluxo de consentimento).
  Stream<QuerySnapshot<Map<String, dynamic>>>
      pedidosRecebidosPendentesStream() {
    if (!_firebaseDisponivel) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection(colecaoPermissoes)
        .where('uidAlvo', isEqualTo: _meuUid)
        .where('status', isEqualTo: statusPendente)
        .snapshots();
  }

  /// Responde a uma solicitação recebida, aprovando ou negando. Só o alvo
  /// (dono da própria localização) pode escrever este status — ver
  /// `firestore.rules`. Garante que o solicitante também exista na minha
  /// lista local (o switch de pré-autorização só é exibido para contatos
  /// já resolvidos localmente), criando a linha automaticamente se
  /// ausente.
  Future<void> responderSolicitacao({
    required String permissaoId,
    required bool aprovar,
    required String uidSolicitante,
    required String nomeSolicitante,
    required String telefoneSolicitante,
  }) async {
    if (!_firebaseDisponivel) return;
    final novoStatus = aprovar ? statusAprovado : statusNegado;

    try {
      await FirebaseFirestore.instance
          .collection(colecaoPermissoes)
          .doc(permissaoId)
          .update({
        'status': novoStatus,
        'atualizadoEm': FieldValue.serverTimestamp(),
        'respondidoEm': FieldValue.serverTimestamp(),
      });

      // Solução A: ao aprovar, não esperamos o próximo tick do heartbeat de
      // localização (que só roda enquanto o cronômetro de Segurança ou um
      // alarme de rotina estiverem ativos, ver [LocationService]) — capturamos
      // e enviamos a posição atual imediatamente, para que quem acabou de
      // ganhar acesso já encontre uma coordenada válida em
      // `usuarios/{meuUid}/monitoramento/atual` assim que abrir o mapa.
      // Fire-and-forget: o GPS pode levar alguns segundos e não deve atrasar
      // a resposta da solicitação nem quebrar o fluxo se falhar.
      if (aprovar) {
        unawaited(_enviarLocalizacaoImediataAoAceitar());
      }

      final contatoLocal = await DatabaseHelper()
          .buscarContatoMonitoramentoPorUid(uidSolicitante);

      int idContatoLocal;
      if (contatoLocal == null) {
        idContatoLocal = await DatabaseHelper().inserirContatoMonitoramento(
          nome: nomeSolicitante,
          telefone: telefoneSolicitante,
        );
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidSolicitante);
      } else {
        idContatoLocal = contatoLocal['id'] as int;
      }
      await DatabaseHelper()
          .atualizarStatusCompartilhamento(idContatoLocal, novoStatus);
      _notificarAlteracao();
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao responder solicitação $permissaoId: $e');
    }
  }

  /// Captura a posição atual do aparelho e a envia ao Firestore
  /// (`usuarios/{meuUid}/monitoramento/atual`), reaproveitando o mesmo
  /// [LocationService] e [FirebaseSyncService] usados pelo heartbeat
  /// periódico da Segurança/Família — ver [responderSolicitacao]. Falhas
  /// (GPS desligado, permissão negada, sem posição em memória) são apenas
  /// logadas: o próximo heartbeat periódico (se algum monitoramento externo
  /// estiver ativo) ou uma nova solicitação tentam novamente depois.
  Future<void> _enviarLocalizacaoImediataAoAceitar() async {
    try {
      final posicao = await LocationService().capturarLocalizacaoAtual();
      if (posicao == null) return;
      await FirebaseSyncService().atualizarLocalizacaoAtual(
        latitude: posicao.latitude,
        longitude: posicao.longitude,
      );
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao enviar localização imediata após aceite: $e');
    }
  }

  /// Define diretamente — sem esperar uma solicitação prévia do contato —
  /// se o contato local [idContatoLocal] pode receber a MINHA localização.
  /// Usada pelo Switch de pré-autorização exibido em CADA card da lista
  /// "Localização de familiares", via Cloud Function callable
  /// `definirPermissaoCompartilhamento`, que resolve o uid do contato pelo
  /// telefone server-side e cria/atualiza o documento em
  /// `permissoes_monitoramento` diretamente como `aprovado`/`bloqueado`
  /// (pula o ciclo `pendente`, pois quem decide aqui é o dono da própria
  /// localização).
  ///
  /// Retorna:
  /// - `'sucesso'`: permissão definida.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> definirPermissaoCompartilhamento({
    required int idContatoLocal,
    required bool permitir,
  }) async {
    if (!_firebaseDisponivel) return 'erro';

    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('definirPermissaoCompartilhamento')
          .call<Map<String, dynamic>>({
        'telefoneContato': contato['telefone'],
        'permitir': permitir,
      });

      final dados = resultado.data;
      final uidContato = dados['uidContato'] as String?;
      final status = dados['status'] as String?;

      if (uidContato != null) {
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidContato);
      }
      if (status != null) {
        await DatabaseHelper()
            .atualizarStatusCompartilhamento(idContatoLocal, status);
      }
      _notificarAlteracao();

      // Solução A também se aplica aqui: este é o OUTRO caminho (além de
      // [responderSolicitacao]) pelo qual eu (dono da localização) concedo
      // acesso a alguém — via switch de pré-autorização, sem que o contato
      // precise ter solicitado antes. Mesmo gatilho de captura+envio
      // imediato de GPS, para não deixar quem acabou de ganhar acesso pelo
      // switch preso em "aguardando primeira localização" à toa.
      if (status == statusAprovado) {
        unawaited(_enviarLocalizacaoImediataAoAceitar());
      }

      return 'sucesso';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir permissão de compartilhamento: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir permissão de compartilhamento: $e');
      return 'erro';
    }
  }

  // ==========================================================
  // BLOQUEIO DE SOLICITANTES — eixo independente do `status` acima
  // ==========================================================

  /// Bloqueia/desbloqueia — via telefone direto, sem exigir um contato já
  /// resolvido na lista local — que um solicitante específico envie NOVAS
  /// solicitações de localização para mim. Usada por
  /// [definirBloqueioSolicitante] abaixo (fluxo do slider dedicado de cada
  /// card da lista, ver `monitoramento_tab.dart`).
  ///
  /// [idContatoLocal], quando informado, cacheia localmente o `uid`
  /// resolvido pela Cloud Function — INDISPENSÁVEL para a reatividade do
  /// slider: sem ele, um contato cujo uid nunca foi resolvido antes fica
  /// sem `permissaoId` no lado Dart, e o card não consegue montar o
  /// `StreamBuilder` que escuta o campo `bloqueado` em tempo real.
  ///
  /// Persistido como campo booleano DEDICADO (`bloqueado`) no documento de
  /// permissão — eixo antes INDEPENDENTE do `status` de compartilhamento.
  ///
  /// REGRA DE CONSISTÊNCIA DE PRIVACIDADE (pedido do usuário, 2026-08-16):
  /// ao BLOQUEAR (nunca ao desbloquear), agora também força
  /// [definirPermissaoCompartilhamento] com `permitir: false` para o mesmo
  /// contato, se houver um [idContatoLocal] resolvido — não fazia sentido
  /// impedir novas solicitações e, ao mesmo tempo, continuar compartilhando
  /// ATIVAMENTE a localização já aprovada antes. Desbloquear continua
  /// **não** reativando o compartilhamento sozinho — isso ainda exige uma
  /// ação explícita separada do usuário no switch de compartilhamento.
  ///
  /// Retorna:
  /// - `'sucesso'`: bloqueio/desbloqueio definido.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> definirBloqueioPorTelefone({
    required String telefone,
    required bool bloquear,
    int? idContatoLocal,
  }) async {
    if (!_firebaseDisponivel) return 'erro';

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('definirBloqueioSolicitante')
          .call<Map<String, dynamic>>({
        'telefoneContato': telefone,
        'bloquear': bloquear,
      });

      // CRÍTICO para a reatividade do slider: sem cachear o uid resolvido
      // aqui, um contato que NUNCA teve o uid resolvido antes (nunca usou
      // "Solicitar Localização" nem o switch de compartilhamento) continua
      // com `uid_contato` nulo no SQLite local mesmo depois do bloqueio —
      // e é esse uid que `MonitoramentoTab._construirCardVerLocalizacao`
      // usa para montar o `permissaoId` e abrir o StreamBuilder que reflete
      // o campo `bloqueado` em tempo real. Sem ele, o card nunca escuta o
      // documento certo: a escrita no Firestore funciona, mas a UI local
      // parece "não reagir" (volta a mostrar Liberado no próximo rebuild).
      if (idContatoLocal != null) {
        final uidContato = resultado.data['uidContato'] as String?;
        if (uidContato != null) {
          await DatabaseHelper()
              .atualizarUidContatoMonitoramento(idContatoLocal, uidContato);
        }
      }

      // REGRA DE CONSISTÊNCIA DE PRIVACIDADE (ver documentação completa
      // acima): bloquear novas solicitações também revoga o
      // compartilhamento ATIVO já concedido a este contato — nunca ao
      // desbloquear. Reaproveita [definirPermissaoCompartilhamento]
      // inteiro (não só a chamada à Cloud Function) para que o cache local
      // (`status_compartilhamento`) e a notificação de UI fiquem
      // consistentes nos dois eixos. Best-effort: uma falha aqui não deve
      // impedir o bloqueio em si (já concluído com sucesso acima) de ser
      // reportado como êxito — o usuário pode reabrir o switch de
      // compartilhamento manualmente se este segundo passo falhar.
      if (bloquear && idContatoLocal != null) {
        try {
          await definirPermissaoCompartilhamento(
            idContatoLocal: idContatoLocal,
            permitir: false,
          );
        } catch (e) {
          debugPrint(
              '⚠️ [MonitoramentoService] Falha ao revogar compartilhamento em cascata após bloqueio: $e');
        }
      }

      _notificarAlteracao();
      return 'sucesso';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir bloqueio de solicitante: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir bloqueio de solicitante: $e');
      return 'erro';
    }
  }

  /// Mesma operação de [definirBloqueioPorTelefone], mas a partir do
  /// contato local [idContatoLocal] — usada pelo slider deslizante de cada
  /// card da lista "Localização de familiares" (ver `monitoramento_tab.dart`).
  Future<String> definirBloqueioSolicitante({
    required int idContatoLocal,
    required bool bloquear,
  }) async {
    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    return definirBloqueioPorTelefone(
      telefone: contato['telefone'] as String,
      bloquear: bloquear,
      idContatoLocal: idContatoLocal,
    );
  }

  // ==========================================================
  // IDS DETERMINÍSTICOS E LISTENERS EM TEMPO REAL
  // ==========================================================

  String _montarIdPermissao(String uidAlvo, String uidSolicitante) =>
      '${uidAlvo}__$uidSolicitante';

  /// Doc id do Bloco A: "eu (`_meuUid`) vejo a localização de [uidAlvo]".
  String? idPermissaoParaVer(String uidAlvo) {
    final meuUid = _meuUid;
    if (meuUid == null) return null;
    return _montarIdPermissao(uidAlvo, meuUid);
  }

  /// Doc id do Bloco B: "[uidSolicitante] vê a localização de mim
  /// (`_meuUid`)".
  String? idPermissaoParaCompartilhar(String uidSolicitante) {
    final meuUid = _meuUid;
    if (meuUid == null) return null;
    return _montarIdPermissao(meuUid, uidSolicitante);
  }

  /// Listener genérico de um documento de permissão pelo seu id — usado
  /// pela UI (Etapa 2) para refletir o status de cada bloco de cada
  /// contato em tempo real, sem precisar de refresh manual.
  Stream<DocumentSnapshot<Map<String, dynamic>>> statusPermissaoStream(
    String permissaoId,
  ) {
    if (!_firebaseDisponivel) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection(colecaoPermissoes)
        .doc(permissaoId)
        .snapshots();
  }

  /// Busca (leitura única, sem stream) a última posição conhecida de
  /// [uidAlvo] em `usuarios/{uidAlvo}/monitoramento/atual` — só retorna
  /// dados se o Bloco A estiver `aprovado` (ver `firestore.rules`); caso
  /// contrário, a própria leitura é negada pelo Firestore e este método
  /// devolve `null` silenciosamente. Usada pelo botão "Ver no mapa".
  Future<Map<String, dynamic>?> buscarUltimaLocalizacao(String uidAlvo) async {
    if (!_firebaseDisponivel) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uidAlvo)
          .collection('monitoramento')
          .doc('atual')
          .get();
      return snap.data();
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao buscar última localização de $uidAlvo: $e');
      return null;
    }
  }

  /// Mesma normalização de `CadastroScreen._normalizarTelefoneE164` e de
  /// `normalizarTelefoneE164` em `functions/smsGateway.js`: números sem
  /// "+" recebem o prefixo do Brasil ("+55").
  String _normalizarTelefoneE164(String telefone) {
    final limpo = telefone.replaceAll(RegExp(r'[^\d+]'), '');
    if (limpo.startsWith('+')) return limpo;
    return '+55$limpo';
  }
}
