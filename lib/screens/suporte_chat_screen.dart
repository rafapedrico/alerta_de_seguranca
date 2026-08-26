import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/localization_service.dart';

/// Chat de Suporte Interno com IA — decisão de arquitetura 2026-08-24,
/// substitui o botão de WhatsApp da [InicioDashboard]. Cada usuário tem,
/// no máximo, UM ticket "em aberto" por vez (status diferente de
/// 'resolvido') em `suporte_tickets/{ticketId}` — reaproveitado a cada
/// vez que esta tela é aberta; ver [_prepararTicket].
///
/// A resposta da IA é gerada por completo do lado do servidor (ver
/// `functions/suporteChatService.js`) — esta tela só cria a mensagem do
/// usuário e escuta a subcoleção `mensagens` via [StreamBuilder]; nunca
/// grava uma resposta "da IA" localmente.
class SuporteChatScreen extends StatefulWidget {
  const SuporteChatScreen({super.key});

  @override
  State<SuporteChatScreen> createState() => _SuporteChatScreenState();
}

class _SuporteChatScreenState extends State<SuporteChatScreen> {
  final TextEditingController _mensagemController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? _ticketId;
  bool _carregandoTicket = true;
  bool _enviando = false;

  @override
  void initState() {
    super.initState();
    _prepararTicket();
  }

  @override
  void dispose() {
    _mensagemController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Reaproveita o ticket mais recente ainda não resolvido do usuário, ou
  /// cria um novo com `idioma`/`planoNoMomento` (snapshot do momento —
  /// ver `functions/suporteChatService.js`, que usa `idioma` pra
  /// responder no idioma certo e `planoNoMomento` só como metadado de
  /// apoio pro atendente humano).
  Future<void> _prepararTicket() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _carregandoTicket = false);
      return;
    }
    try {
      final ticketsRef = FirebaseFirestore.instance.collection('suporte_tickets');
      final existente = await ticketsRef
          .where('uid', isEqualTo: uid)
          .where('status',
              whereIn: ['ia_ativa', 'aguardando_humano', 'em_atendimento_humano'])
          .orderBy('criadoEm', descending: true)
          .limit(1)
          .get();

      if (existente.docs.isNotEmpty) {
        _ticketId = existente.docs.first.id;
      } else {
        final perfilSnap =
            await FirebaseFirestore.instance.collection('usuarios').doc(uid).get();
        final bool isPremium = (perfilSnap.data()?['isPremium'] as bool?) ?? false;
        final String idioma = await LocalizationService().carregarIdioma();

        final novoTicket = await ticketsRef.add({
          'uid': uid,
          'status': 'ia_ativa',
          'idioma': idioma,
          'planoNoMomento': isPremium ? 'premium' : 'free',
          'criadoEm': FieldValue.serverTimestamp(),
        });
        _ticketId = novoTicket.id;
      }
    } catch (e) {
      debugPrint('⚠️ [SuporteChat] Falha ao preparar o ticket: $e');
    }
    if (mounted) setState(() => _carregandoTicket = false);
  }

  Future<void> _enviarMensagem() async {
    final texto = _mensagemController.text.trim();
    final ticketId = _ticketId;
    if (texto.isEmpty || ticketId == null || _enviando) return;

    setState(() => _enviando = true);
    _mensagemController.clear();
    try {
      await FirebaseFirestore.instance
          .collection('suporte_tickets')
          .doc(ticketId)
          .collection('mensagens')
          .add({
        'autor': 'usuario',
        'texto': texto,
        'criadoEm': FieldValue.serverTimestamp(),
      });
      _rolarParaFinal();
    } catch (e) {
      debugPrint('⚠️ [SuporteChat] Falha ao enviar mensagem: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.suporteChatErroEnviar)),
        );
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  void _rolarParaFinal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Callable `solicitarAtendenteHumano` — caminho determinístico do
  /// botão "Falar com atendente" (ver cabeçalho de
  /// `functions/suporteChatService.js`).
  Future<void> _falarComAtendente() async {
    final ticketId = _ticketId;
    if (ticketId == null) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      await FirebaseFunctions.instance
          .httpsCallable('solicitarAtendenteHumano')
          .call({'ticketId': ticketId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.suporteChatConfirmarAtendente)),
        );
      }
    } catch (e) {
      debugPrint('⚠️ [SuporteChat] Falha ao solicitar atendente: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(l10n.suporteChatAppBarTitulo),
        actions: [
          if (_ticketId != null)
            IconButton(
              icon: const Icon(Icons.support_agent_outlined),
              tooltip: l10n.suporteChatFalarComAtendente,
              onPressed: _falarComAtendente,
            ),
        ],
      ),
      body: _carregandoTicket
          ? const Center(child: CircularProgressIndicator(color: Colors.white54))
          : _ticketId == null
              ? Center(
                  child: Text(
                    l10n.suporteChatErroEnviar,
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              : SafeArea(
                  child: Column(
                    children: [
                      _StatusBanner(ticketId: _ticketId!),
                      Expanded(
                        child: _ListaMensagens(
                          ticketId: _ticketId!,
                          scrollController: _scrollController,
                        ),
                      ),
                      _CampoEnvio(
                        controller: _mensagemController,
                        enviando: _enviando,
                        onEnviar: _enviarMensagem,
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// Faixa fina no topo da conversa, visível só quando o status do ticket
/// não é o padrão "ia_ativa" — informa o usuário sobre o andamento do
/// handoff pra humano (ver `functions/suporteChatService.js`).
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.ticketId});

  final String ticketId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('suporte_tickets')
          .doc(ticketId)
          .snapshots(),
      builder: (context, snapshot) {
        final status = snapshot.data?.data()?['status'] as String?;
        String? texto;
        switch (status) {
          case 'aguardando_humano':
            texto = l10n.suporteChatAguardandoHumano;
            break;
          case 'em_atendimento_humano':
            texto = l10n.suporteChatEmAtendimentoHumano;
            break;
          case 'resolvido':
            texto = l10n.suporteChatResolvido;
            break;
        }
        if (texto == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          color: const Color(0xFF1A1B26),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            texto,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        );
      },
    );
  }
}

class _ListaMensagens extends StatelessWidget {
  const _ListaMensagens({required this.ticketId, required this.scrollController});

  final String ticketId;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('suporte_tickets')
          .doc(ticketId)
          .collection('mensagens')
          .orderBy('criadoEm')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Sem este ramo, uma falha do listener (regra negada, token
          // expirado etc.) cai no mesmo estado visual de "sem mensagens
          // ainda" abaixo — o usuário não recebe nenhum indício de que a
          // conversa parou de atualizar em tempo real.
          debugPrint('⚠️ [SuporteChat] Falha no listener de mensagens: ${snapshot.error}');
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                l10n.suporteChatErroEnviar,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38),
              ),
            ),
          );
        }

        final docs = snapshot.data?.docs ?? const [];
        if (docs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                l10n.suporteChatVazio,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38),
              ),
            ),
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            scrollController.jumpTo(scrollController.position.maxScrollExtent);
          }
        });

        return ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final dados = docs[index].data();
            return _BolhaMensagem(
              autor: dados['autor'] as String? ?? 'sistema',
              texto: dados['texto'] as String? ?? '',
            );
          },
        );
      },
    );
  }
}

class _BolhaMensagem extends StatelessWidget {
  const _BolhaMensagem({required this.autor, required this.texto});

  final String autor;
  final String texto;

  @override
  Widget build(BuildContext context) {
    final bool doUsuario = autor == 'usuario';
    final bool sistema = autor == 'sistema';

    final Color corFundo = doUsuario
        ? const Color(0xFF7C4DFF)
        : sistema
            ? Colors.transparent
            : const Color(0xFF1A1B26);

    final alinhamento = doUsuario ? Alignment.centerRight : Alignment.centerLeft;

    if (sistema) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            texto,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      );
    }

    return Align(
      alignment: alinhamento,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: corFundo,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          texto,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
    );
  }
}

class _CampoEnvio extends StatelessWidget {
  const _CampoEnvio({
    required this.controller,
    required this.enviando,
    required this.onEnviar,
  });

  final TextEditingController controller;
  final bool enviando;
  final VoidCallback onEnviar;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onEnviar(),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: l10n.suporteChatHint,
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF1A1B26),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: enviando ? null : onEnviar,
            tooltip: l10n.suporteChatEnviar,
            icon: enviando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
