import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'firebase_auth_service.dart';

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
/// - Bloco B ("compartilhar minha localização com ele"): documento onde
///   EU sou `uidAlvo` — só passa a existir quando ELE me solicitou ao
///   menos uma vez — ver [responderSolicitacao]/[alternarCompartilhamento].
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

  /// Remove definitivamente o contato da lista local. NÃO revoga, por si
  /// só, nenhuma permissão já concedida no Firestore — o compartilhamento
  /// de localização continua ativo até ser bloqueado explicitamente (ver
  /// [alternarCompartilhamento]).
  Future<void> removerContato(int id) async {
    await DatabaseHelper().deletarContatoMonitoramento(id);
    _notificarAlteracao();
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
  /// `firestore.rules`. Ao aprovar, garante que o solicitante também
  /// exista na minha lista local (o Bloco B só é exibido para contatos já
  /// resolvidos localmente), criando a linha automaticamente se ausente.
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

  /// Variante de [responderSolicitacao] que busca os dados do
  /// solicitante diretamente do próprio documento antes de responder —
  /// usada pela seção "Compartilhar minha localização" da UI (Etapa 2),
  /// que já está posicionada sobre o card do contato e só precisa do
  /// [permissaoId] e da decisão do usuário.
  Future<void> responderSolicitacaoPorId({
    required String permissaoId,
    required bool aprovar,
  }) async {
    if (!_firebaseDisponivel) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(colecaoPermissoes)
          .doc(permissaoId)
          .get();
      final dados = snap.data();
      if (dados == null) return;

      await responderSolicitacao(
        permissaoId: permissaoId,
        aprovar: aprovar,
        uidSolicitante: dados['uidSolicitante'] as String? ?? '',
        nomeSolicitante: dados['nomeSolicitante'] as String? ?? '',
        telefoneSolicitante: dados['telefoneSolicitante'] as String? ?? '',
      );
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao responder solicitação $permissaoId: $e');
    }
  }

  /// Liga/desliga o compartilhamento da MINHA localização com um contato
  /// que já teve a solicitação aprovada anteriormente — reativação DIRETA
  /// (sem nova solicitação/aprovação), pois a permissão já existe no
  /// Firestore, só transiciona entre `aprovado` e `bloqueado`.
  Future<void> alternarCompartilhamento({
    required int idContatoLocal,
    required String permissaoId,
    required bool compartilhar,
  }) async {
    if (!_firebaseDisponivel) return;
    final novoStatus = compartilhar ? statusAprovado : statusBloqueado;

    try {
      await FirebaseFirestore.instance
          .collection(colecaoPermissoes)
          .doc(permissaoId)
          .update({
        'status': novoStatus,
        'atualizadoEm': FieldValue.serverTimestamp(),
      });
      await DatabaseHelper()
          .atualizarStatusCompartilhamento(idContatoLocal, novoStatus);
      _notificarAlteracao();
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao alternar compartilhamento $permissaoId: $e');
    }
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
