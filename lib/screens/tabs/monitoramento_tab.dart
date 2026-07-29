import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/monitoramento_service.dart';
import '../../services/wallpaper_service.dart';

const Color _corDestaque = Color(0xFF4C7040);

/// Aba Monitoramento: permite ao usuário controlar, contato a contato, o
/// compartilhamento bilateral de localização GPS em tempo real com
/// familiares que também usam o Guardião X — com consentimento explícito
/// em ambas as direções (ver [MonitoramentoService]).
///
/// EXCLUSIVAMENTE de visualização/gerenciamento: esta tela NÃO contém
/// teclado de PIN nem dispara qualquer som de alarme/sirene — apenas lê e
/// escreve permissões e localização na nuvem.
///
/// Duas seções, espelhando as duas direções independentes de permissão:
/// - "Localização de familiares" (Bloco A, `uidSolicitante` = eu): lista
///   TODOS os contatos cadastrados localmente, com o gerenciamento do
///   próprio contato (editar nome/excluir) e o controle de solicitar/ver
///   a localização de cada um.
/// - "Compartilhar minha localização" (Bloco B, `uidAlvo` = eu): lista
///   apenas os contatos que já solicitaram MINHA localização ao menos uma
///   vez, com o switch ON/OFF de bloqueio/desbloqueio.
class MonitoramentoTab extends StatefulWidget {
  const MonitoramentoTab({super.key});

  @override
  State<MonitoramentoTab> createState() => MonitoramentoTabState();
}

class MonitoramentoTabState extends State<MonitoramentoTab> {
  final MonitoramentoService _servico = MonitoramentoService();

  bool _carregando = true;
  List<Map<String, dynamic>> _contatos = [];

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _pedidosSub;
  final Set<String> _pedidosJaNotificados = {};

  @override
  void initState() {
    super.initState();
    _carregarContatos();
    MonitoramentoService.versaoMonitoramento.addListener(_aoAlterarLocal);
    _pedidosSub = _servico
        .pedidosRecebidosPendentesStream()
        .listen(_aoAtualizarPedidosRecebidos);
  }

  @override
  void dispose() {
    MonitoramentoService.versaoMonitoramento.removeListener(_aoAlterarLocal);
    _pedidosSub?.cancel();
    super.dispose();
  }

  void _aoAlterarLocal() => _carregarContatos();

  Future<void> _carregarContatos() async {
    if (!mounted) return;
    setState(() => _carregando = true);
    final contatos = await _servico.listarContatos();
    if (!mounted) return;
    setState(() {
      _contatos = contatos;
      _carregando = false;
    });
  }

  /// Sempre que uma NOVA solicitação pendente aparecer (id ainda não
  /// visto nesta sessão da tela), exibe o diálogo de consentimento
  /// explícito exigido pelo fluxo: "Fulano está solicitando a sua
  /// localização. Permitir ou Bloquear?".
  void _aoAtualizarPedidosRecebidos(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    for (final doc in snapshot.docs) {
      if (_pedidosJaNotificados.contains(doc.id)) continue;
      _pedidosJaNotificados.add(doc.id);
      _exibirDialogoSolicitacaoRecebida(doc);
    }
  }

  Future<void> _exibirDialogoSolicitacaoRecebida(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final dados = doc.data();
    final nome = (dados['nomeSolicitante'] as String?)?.trim();
    final telefone = (dados['telefoneSolicitante'] as String?) ?? '';
    final nomeExibido = (nome != null && nome.isNotEmpty) ? nome : telefone;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoSolicitacaoRecebidaTitulo),
        content: Text(l10n.monitoramentoSolicitacaoRecebidaConteudo(nomeExibido)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _responderSolicitacao(doc, aprovar: false);
            },
            child: Text(l10n.monitoramentoBloquearRecusar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _corDestaque),
            onPressed: () {
              Navigator.of(ctx).pop();
              _responderSolicitacao(doc, aprovar: true);
            },
            child: Text(l10n.monitoramentoPermitir),
          ),
        ],
      ),
    );
  }

  Future<void> _responderSolicitacao(
    QueryDocumentSnapshot<Map<String, dynamic>> doc, {
    required bool aprovar,
  }) async {
    final dados = doc.data();
    await _servico.responderSolicitacao(
      permissaoId: doc.id,
      aprovar: aprovar,
      uidSolicitante: dados['uidSolicitante'] as String? ?? '',
      nomeSolicitante: dados['nomeSolicitante'] as String? ?? '',
      telefoneSolicitante: dados['telefoneSolicitante'] as String? ?? '',
    );
  }

  // ==========================================================
  // GERENCIAMENTO DE CONTATOS (adicionar/editar/excluir)
  // ==========================================================

  /// Acionado pelo botão "+" do AppBar global (ver HomeScreen), mesmo
  /// padrão de [FamiliaTabState.abrirModalAdicionarAlarme].
  Future<void> abrirModalAdicionarContato() async {
    final l10n = AppLocalizations.of(context)!;
    final nomeController = TextEditingController();
    final telefoneController = TextEditingController();

    final salvou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoAdicionarContato),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nomeController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.monitoramentoNomeLabel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: telefoneController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: l10n.monitoramentoTelefoneLabel,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.phone_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _corDestaque),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.monitoramentoSalvarContato),
          ),
        ],
      ),
    );

    if (salvou != true) return;
    final nome = nomeController.text.trim();
    final telefone = telefoneController.text.trim();
    if (nome.isEmpty || telefone.isEmpty) return;

    await _servico.adicionarContato(nome: nome, telefone: telefone);
  }

  Future<void> _editarNomeContato(Map<String, dynamic> contato) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final controller = TextEditingController(text: contato['nome'] as String? ?? '');

    final novoNome = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoEditarNomeTooltip),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.monitoramentoNomeLabel,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _corDestaque),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.monitoramentoSalvarContato),
          ),
        ],
      ),
    );

    if (novoNome == null || novoNome.isEmpty) return;
    await _servico.editarNomeContato(id, novoNome);
  }

  Future<void> _excluirContato(Map<String, dynamic> contato) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final nome = contato['nome'] as String? ?? '';

    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoExcluirContatoTitulo),
        content: Text(l10n.monitoramentoExcluirContatoConteudo(nome)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.excluir),
          ),
        ],
      ),
    );

    if (confirmou != true) return;
    await _servico.removerContato(id);
  }

  // ==========================================================
  // SOLICITAR / ABRIR MAPA
  // ==========================================================

  Future<void> _solicitarLocalizacao(int idContato) async {
    final l10n = AppLocalizations.of(context)!;
    final resultado = await _servico.solicitarLocalizacao(idContato);
    if (!mounted) return;

    final mensagem = switch (resultado) {
      'enviada' => l10n.monitoramentoSolicitacaoEnviada,
      'ja_aprovado' => l10n.monitoramentoJaAprovado,
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      _ => l10n.monitoramentoErroSolicitar,
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _abrirMapa(String uidAlvo) async {
    final dados = await _servico.buscarUltimaLocalizacao(uidAlvo);
    final latitude = (dados?['latitude'] as num?)?.toDouble();
    final longitude = (dados?['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) return;

    final uri = Uri.parse('https://maps.google.com/?q=$latitude,$longitude');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort — se não houver app de mapas disponível, ignora.
    }
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<String>(
      valueListenable: WallpaperService.wallpaperNotifier,
      builder: (context, fundoAtivo, _) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(image: AssetImage(fundoAtivo), fit: BoxFit.cover),
          ),
          child: SafeArea(
            child: RefreshIndicator(
              onRefresh: _carregarContatos,
              child: _carregando
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        if (_contatos.isEmpty)
                          _construirEstadoVazio(l10n)
                        else ...[
                          _construirCabecalhoSecao(
                            icone: Icons.location_searching,
                            titulo: l10n.monitoramentoSecaoVerLocalizacao,
                          ),
                          const SizedBox(height: 8),
                          ..._contatos.map(_construirCardVerLocalizacao),
                          const SizedBox(height: 16),
                          const Divider(),
                          const SizedBox(height: 8),
                          _construirCabecalhoSecao(
                            icone: Icons.share_location,
                            titulo: l10n.monitoramentoSecaoCompartilhar,
                          ),
                          const SizedBox(height: 8),
                          ..._contatos.map(_construirCardCompartilhar),
                        ],
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _construirCabecalhoSecao({required IconData icone, required String titulo}) {
    return Row(
      children: [
        Icon(icone, color: _corDestaque),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            titulo,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  Widget _construirEstadoVazio(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.person_search, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            l10n.monitoramentoNenhumContato,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _construirAvatar(String nome) {
    return CircleAvatar(
      backgroundColor: const Color(0xFFE8F5E9),
      child: Text(
        nome.isNotEmpty ? nome[0].toUpperCase() : '?',
        style: const TextStyle(color: _corDestaque, fontWeight: FontWeight.bold),
      ),
    );
  }

  // ------------------------------------------------------------
  // Seção "Localização de familiares" (Bloco A)
  // ------------------------------------------------------------

  Widget _construirCardVerLocalizacao(Map<String, dynamic> contato) {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final nome = contato['nome'] as String? ?? '';
    final telefone = contato['telefone'] as String? ?? '';

    return Card(
      elevation: 0,
      color: Colors.white.withOpacity(0.92),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _construirAvatar(nome),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nome,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      Text(
                        telefone,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20, color: Colors.black54),
                  tooltip: l10n.monitoramentoEditarNomeTooltip,
                  onPressed: () => _editarNomeContato(contato),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  tooltip: l10n.monitoramentoExcluirContatoTooltip,
                  onPressed: () => _excluirContato(contato),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _construirBlocoVerLocalizacao(contato, id, l10n),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _construirBlocoVerLocalizacao(
    Map<String, dynamic> contato,
    int id,
    AppLocalizations l10n,
  ) {
    final uid = contato['uid_contato'] as String?;

    if (uid == null) {
      return _botaoSolicitar(id, l10n);
    }

    final permissaoId = _servico.idPermissaoParaVer(uid);
    if (permissaoId == null) return _botaoSolicitar(id, l10n);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        final status = snapshot.data?.data()?['status'] as String? ??
            (contato['status_ver_localizacao'] as String? ??
                MonitoramentoService.statusVerNaoSolicitado);

        switch (status) {
          case MonitoramentoService.statusPendente:
            return _linhaStatus(
              icone: Icons.hourglass_top,
              cor: Colors.amber.shade800,
              texto: l10n.monitoramentoStatusAguardandoAprovacao,
            );
          case MonitoramentoService.statusNegado:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _linhaStatus(
                  icone: Icons.block,
                  cor: Colors.red.shade700,
                  texto: l10n.monitoramentoStatusNegado,
                ),
                const SizedBox(height: 4),
                _botaoSolicitar(id, l10n),
              ],
            );
          case MonitoramentoService.statusExpirado:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _linhaStatus(
                  icone: Icons.timer_off_outlined,
                  cor: Colors.grey.shade600,
                  texto: l10n.monitoramentoStatusExpirado,
                ),
                const SizedBox(height: 4),
                _botaoSolicitar(id, l10n),
              ],
            );
          case MonitoramentoService.statusAprovado:
            return _construirLinhaAprovado(uid, l10n);
          default:
            return _botaoSolicitar(id, l10n);
        }
      },
    );
  }

  Widget _construirLinhaAprovado(String uid, AppLocalizations l10n) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _servico.buscarUltimaLocalizacao(uid),
      builder: (context, snapshot) {
        final dados = snapshot.data;
        final atualizadoEm = dados?['atualizadoEm'];
        String? subtitulo;
        if (atualizadoEm is Timestamp) {
          final minutos = DateTime.now().difference(atualizadoEm.toDate()).inMinutes;
          subtitulo = l10n.monitoramentoAtualizadoHaMinutos(minutos < 0 ? 0 : minutos);
        }

        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _linhaStatus(
                    icone: Icons.check_circle,
                    cor: Colors.green.shade700,
                    texto: l10n.monitoramentoStatusAprovado,
                  ),
                  if (subtitulo != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 22, top: 2),
                      child: Text(
                        subtitulo,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: dados == null ? null : () => _abrirMapa(uid),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: Text(l10n.monitoramentoVerNoMapa),
              style: TextButton.styleFrom(foregroundColor: _corDestaque),
            ),
          ],
        );
      },
    );
  }

  Widget _botaoSolicitar(int id, AppLocalizations l10n) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () => _solicitarLocalizacao(id),
        icon: const Icon(Icons.location_searching, size: 18),
        label: Text(l10n.monitoramentoSolicitarLocalizacao),
        style: OutlinedButton.styleFrom(foregroundColor: _corDestaque),
      ),
    );
  }

  Widget _linhaStatus({required IconData icone, required Color cor, required String texto}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 18, color: cor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            texto,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cor),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // Seção "Compartilhar minha localização" (Bloco B)
  // ------------------------------------------------------------

  Widget _construirCardCompartilhar(Map<String, dynamic> contato) {
    final uid = contato['uid_contato'] as String?;
    if (uid == null) return const SizedBox.shrink();

    final permissaoId = _servico.idPermissaoParaCompartilhar(uid);
    if (permissaoId == null) return const SizedBox.shrink();

    final id = contato['id'] as int;
    final nome = contato['nome'] as String? ?? '';
    final l10n = AppLocalizations.of(context)!;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data?.exists != true) {
          // Este contato nunca solicitou a MINHA localização — nada a
          // exibir nesta seção para ele.
          return const SizedBox.shrink();
        }

        final status = snapshot.data!.data()?['status'] as String?;

        return Card(
          elevation: 0,
          color: Colors.white.withOpacity(0.92),
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _construirConteudoCompartilhar(
              status: status,
              nome: nome,
              idContato: id,
              permissaoId: permissaoId,
              l10n: l10n,
            ),
          ),
        );
      },
    );
  }

  Widget _construirConteudoCompartilhar({
    required String? status,
    required String nome,
    required int idContato,
    required String permissaoId,
    required AppLocalizations l10n,
  }) {
    if (status == MonitoramentoService.statusPendente) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _construirAvatar(nome),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  nome,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.monitoramentoSolicitacaoRecebidaConteudo(nome),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _servico.responderSolicitacaoPorId(
                  permissaoId: permissaoId,
                  aprovar: false,
                ),
                child: Text(l10n.monitoramentoBloquearRecusar),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _corDestaque),
                onPressed: () => _servico.responderSolicitacaoPorId(
                  permissaoId: permissaoId,
                  aprovar: true,
                ),
                child: Text(l10n.monitoramentoPermitir),
              ),
            ],
          ),
        ],
      );
    }

    final compartilhando = status == MonitoramentoService.statusAprovado;
    final String rotuloStatus = compartilhando
        ? l10n.monitoramentoStatusAprovado
        : l10n.monitoramentoStatusBloqueado;

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: _construirAvatar(nome),
      title: Text(
        nome,
        softWrap: true,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        rotuloStatus,
        style: TextStyle(
          fontSize: 12,
          color: compartilhando ? Colors.green.shade700 : Colors.grey.shade600,
          fontWeight: FontWeight.w600,
        ),
      ),
      activeColor: _corDestaque,
      value: compartilhando,
      onChanged: (valor) => _servico.alternarCompartilhamento(
        idContatoLocal: idContato,
        permissaoId: permissaoId,
        compartilhar: valor,
      ),
    );
  }
}
