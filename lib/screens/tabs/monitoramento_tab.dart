import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/monitoramento_service.dart';
import '../../services/wallpaper_service.dart';
import '../../widgets/monitoramento_decisao_dialog.dart';

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
/// Lista única "Localização de familiares" com TODOS os contatos
/// cadastrados localmente. Cada card reúne as duas direções independentes
/// de permissão para aquele contato:
/// - "Solicitar Localização" (`uidSolicitante` = eu): pede para VER a
///   localização dele.
/// - Switch de pré-autorização (`uidAlvo` = eu): permite CONCEDER ou
///   BLOQUEAR, individualmente e preventivamente, se ELE pode receber a
///   MINHA localização — mesmo que ele nunca tenha solicitado antes (ver
///   [MonitoramentoService.definirPermissaoCompartilhamento]). Pedidos
///   recebidos enquanto a tela está aberta continuam sendo interceptados
///   por um diálogo de consentimento explícito antes de qualquer decisão
///   automática.
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
    final dados = doc.data();
    await exibirDialogoDecisaoMonitoramento(
      context: context,
      idPermissao: doc.id,
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
    String? erroValidacao;

    // StatefulBuilder (em vez de SnackBar) porque um SnackBar disparado a
    // partir do `context` da tela fica renderizado ATRÁS da barreira do
    // AlertDialog (dialogs abrem em uma rota separada, acima do Scaffold
    // onde o SnackBar é ancorado) — o aviso de campos obrigatórios ficava
    // efetivamente invisível. Exibindo o erro dentro do próprio diálogo,
    // ele fica sempre visível e some assim que o usuário corrige os campos.
    final salvou = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          // `scrollable: true` (embrulha title+content num SingleChildScrollView
          // interno do próprio AlertDialog) — sem isso, com a fonte do
          // sistema aumentada os 2 campos + botão "+ Adicionar Contato da
          // Agenda" (+ eventual texto de erro) ultrapassavam a altura do
          // diálogo, e a área de `actions` ("Cancelar"/"Salvar Contato")
          // era desenhada por cima do conteúdo, encobrindo o botão da
          // agenda. Com fonte padrão o comportamento visual é idêntico —
          // só passa a rolar internamente quando não couber.
          scrollable: true,
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
                  // Sem isso, o label às vezes não flutua acima da borda a
                  // tempo (efeito visível ao digitar rápido no teclado
                  // numérico) e fica sobreposto aos dígitos já digitados.
                  floatingLabelBehavior: FloatingLabelBehavior.always,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),
              // Composto manualmente (em vez de TextButton.icon) porque o
              // Row interno do TextButton.icon não dá nenhuma flexibilidade
              // ao label — com a fonte do sistema bem aumentada, o texto
              // "+ Adicionar Contato da Agenda" estourava a largura do
              // diálogo (RenderFlex overflow) em vez de quebrar linha. O
              // Flexible aqui permite quebrar em 2 linhas quando não couber.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _importarContatoDaAgenda(
                    nomeController: nomeController,
                    telefoneController: telefoneController,
                  ),
                  style: TextButton.styleFrom(foregroundColor: _corDestaque),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(Icons.contact_phone_outlined, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          l10n.adicionarContatoAgenda,
                          softWrap: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (erroValidacao != null) ...[
                const SizedBox(height: 8),
                Text(
                  erroValidacao!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.cancelar),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _corDestaque),
              onPressed: () {
                final nome = nomeController.text.trim();
                final telefone = telefoneController.text.trim();
                if (nome.isEmpty || telefone.isEmpty) {
                  setStateDialog(() {
                    erroValidacao = l10n.monitoramentoCamposObrigatorios;
                  });
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: Text(l10n.monitoramentoSalvarContato),
            ),
          ],
        ),
      ),
    );

    if (salvou != true) return;
    final nome = nomeController.text.trim();
    final telefone = telefoneController.text.trim();
    if (nome.isEmpty || telefone.isEmpty) return;

    await _servico.adicionarContato(nome: nome, telefone: telefone);
  }

  /// Abre o seletor nativo de contatos (mesmo mecanismo usado na aba
  /// Configurações, ver `ConfiguracoesTabState._adicionarContatoDaAgenda`)
  /// e apenas PRE-PREENCHE os campos do diálogo — quem confirma o
  /// cadastro continua sendo o botão "Salvar", dando ao usuário a chance
  /// de revisar/editar antes de gravar.
  Future<void> _importarContatoDaAgenda({
    required TextEditingController nomeController,
    required TextEditingController telefoneController,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    final bool permitido = await FlutterContacts.requestPermission(readonly: true);
    if (!permitido) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.contatosPermissaoNegada),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    Contact? contatoSelecionado;
    try {
      contatoSelecionado = await FlutterContacts.openExternalPick();
    } catch (_) {
      contatoSelecionado = null;
    }
    if (contatoSelecionado == null) return;

    final contatoCompleto = await FlutterContacts.getContact(contatoSelecionado.id);
    if (contatoCompleto == null || contatoCompleto.phones.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.contatoSemTelefone),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final nome = contatoCompleto.displayName.trim();
    if (nome.isNotEmpty) nomeController.text = nome;
    telefoneController.text = contatoCompleto.phones.first.number;
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
    final revogacaoOk = await _servico.removerContato(id);
    if (!mounted || revogacaoOk) return;

    // Falha CRÍTICA de privacidade em potencial: o contato já saiu da
    // lista local, mas a revogação da permissão de compartilhamento no
    // Firestore falhou de verdade (rede/servidor) — nunca deixar isso
    // passar em silêncio, ver `MonitoramentoService.removerContato`.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.monitoramentoRevogacaoFalhouAoExcluir),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 6),
      ),
    );
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
      'bloqueado_pelo_alvo' => l10n.monitoramentoContatoIndisponivel,
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
    final uid = contato['uid_contato'] as String?;
    final permissaoId = uid != null ? _servico.idPermissaoParaCompartilhar(uid) : null;

    // Sem doc de permissão ainda resolvido (contato nunca interagiu nesta
    // direção): não há nada bloqueado por definição — mas o controle já
    // fica disponível para bloquear preventivamente, já que
    // `definirBloqueioPorTelefone` resolve o telefone server-side, sem
    // depender de um `uid_contato` local previamente resolvido.
    if (permissaoId == null) {
      return _construirConteudoCardVerLocalizacao(
        contato: contato,
        bloqueado: false,
        l10n: l10n,
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        final bloqueado = snapshot.data?.data()?['bloqueado'] as bool? ?? false;
        return _construirConteudoCardVerLocalizacao(
          contato: contato,
          bloqueado: bloqueado,
          l10n: l10n,
        );
      },
    );
  }

  /// Confirma (só para BLOQUEAR — desbloquear é sempre imediato, é uma
  /// ação reversível e não-destrutiva) e então persiste o bloqueio via
  /// [_alternarBloqueioSolicitante].
  Future<void> _alternarBloqueioComConfirmacao(
    Map<String, dynamic> contato,
    bool bloquear,
  ) async {
    if (bloquear) {
      final l10n = AppLocalizations.of(context)!;
      final nome = contato['nome'] as String? ?? '';
      final confirmou = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.monitoramentoBloquearContatoTitulo),
              content: Text(l10n.monitoramentoBloquearContatoConteudo(nome)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.cancelar),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(l10n.monitoramentoBloquear),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmou) return;
    }
    await _alternarBloqueioSolicitante(contato, bloquear);
  }

  Future<void> _alternarBloqueioSolicitante(
    Map<String, dynamic> contato,
    bool bloquear,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final resultado = await _servico.definirBloqueioSolicitante(
      idContatoLocal: id,
      bloquear: bloquear,
    );
    if (!mounted) return;

    final mensagem = switch (resultado) {
      'sucesso' => bloquear
          ? l10n.monitoramentoContatoBloqueadoSucesso
          : l10n.monitoramentoContatoDesbloqueadoSucesso,
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      _ => l10n.monitoramentoErroSolicitar,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        backgroundColor: resultado == 'sucesso' ? null : Colors.redAccent,
      ),
    );
  }

  Widget _construirConteudoCardVerLocalizacao({
    required Map<String, dynamic> contato,
    required bool bloqueado,
    required AppLocalizations l10n,
  }) {
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
            const Divider(height: 20),
            _construirSwitchCompartilhar(contato, l10n),
            const SizedBox(height: 10),
            _construirControleBloqueio(contato, bloqueado, l10n),
          ],
        ),
      ),
    );
  }

  /// Bloco ISOLADO e dedicado ao bloqueio de solicitações — texto
  /// explicativo, e logo abaixo um controle de arraste fluido (`Switch`,
  /// que no Material já aceita tanto toque quanto arrastar o próprio
  /// polegar para os dois lados) com hit-area PRÓPRIA, restrita a este
  /// bloco — ao contrário de um `Dismissible` cobrindo o card inteiro
  /// (tentativa anterior), nunca interfere com o resto do card (nome,
  /// telefone, botões de editar/excluir, o outro switch).
  ///
  /// CORREÇÃO DE INVERSÃO (bug real reportado, 2026-08-11): o `Switch`
  /// exibia `value: bloqueado` diretamente — ligado (polegar à direita)
  /// == BLOQUEADO. Isso ficava "ao contrário do esperado": o usuário
  /// espera que ligar/"ativar" o controle signifique PERMITIR (estado
  /// positivo), não bloquear. Agora o `Switch` representa `permitido`
  /// (`!bloqueado`) — ligado (verde) = permite solicitações; desligado
  /// (vermelho) = bloqueado — e o `onChanged` converte de volta
  /// (`bloquear: !valor`) antes de chamar
  /// [_alternarBloqueioComConfirmacao], que continua recebendo/tratando
  /// exclusivamente o significado "bloquear", sem nenhuma outra mudança
  /// de comportamento.
  Widget _construirControleBloqueio(
    Map<String, dynamic> contato,
    bool bloqueado,
    AppLocalizations l10n,
  ) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.monitoramentoPermitirOuBloquearSolicitacoes,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              _linhaStatus(
                icone: bloqueado ? Icons.block : Icons.check_circle,
                cor: bloqueado ? Colors.red.shade700 : Colors.green.shade700,
                texto: bloqueado
                    ? l10n.monitoramentoIndicadorBloqueado
                    : l10n.monitoramentoIndicadorLiberado,
              ),
            ],
          ),
        ),
        Switch(
          value: !bloqueado,
          activeColor: Colors.green.shade600,
          activeTrackColor: Colors.green.shade100,
          inactiveThumbColor: Colors.red.shade600,
          inactiveTrackColor: Colors.red.shade100,
          onChanged: (valor) => _alternarBloqueioComConfirmacao(contato, !valor),
        ),
      ],
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
        final aindaCarregando = snapshot.connectionState == ConnectionState.waiting;
        final dados = snapshot.data;
        // `dados == null` após a busca terminar significa que a permissão já
        // foi aprovada, mas o alvo ainda não teve nenhuma coordenada
        // capturada/enviada (ver Solução A em
        // `MonitoramentoService._enviarLocalizacaoImediataAoAceitar`, que é
        // fire-and-forget e pode levar alguns segundos) — em vez de deixar o
        // botão "Ver no mapa" silenciosamente desabilitado, avisamos
        // explicitamente que a primeira localização ainda está a caminho.
        final semLocalizacaoAinda = !aindaCarregando && dados == null;

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
                  if (semLocalizacaoAinda)
                    _linhaStatusAguardandoLocalizacao(l10n)
                  else
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
              onPressed: semLocalizacaoAinda
                  ? () => _avisarLocalizacaoAindaNaoDisponivel(l10n)
                  : (dados == null ? null : () => _abrirMapa(uid)),
              icon: const Icon(Icons.map_outlined, size: 18),
              label: Text(l10n.monitoramentoVerNoMapa),
              style: TextButton.styleFrom(foregroundColor: _corDestaque),
            ),
          ],
        );
      },
    );
  }

  Widget _linhaStatusAguardandoLocalizacao(AppLocalizations l10n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            l10n.monitoramentoAguardandoPrimeiraLocalizacao,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.amber.shade800,
            ),
          ),
        ),
      ],
    );
  }

  void _avisarLocalizacaoAindaNaoDisponivel(AppLocalizations l10n) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.monitoramentoLocalizacaoSendoAtualizada),
        behavior: SnackBarBehavior.floating,
      ),
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
  // Switch de pré-autorização — "Permitir receber minha localização"
  // ------------------------------------------------------------

  /// Switch individual exibido em CADA card da lista, independentemente
  /// de o contato já ter solicitado a MINHA localização alguma vez — ver
  /// [MonitoramentoService.definirPermissaoCompartilhamento]. Sem
  /// documento de permissão ainda existente (contato nunca resolvido /
  /// nunca autorizado), o padrão é BLOQUEADO (nega por padrão).
  Widget _construirSwitchCompartilhar(
    Map<String, dynamic> contato,
    AppLocalizations l10n,
  ) {
    final uid = contato['uid_contato'] as String?;
    final permissaoId = uid != null
        ? _servico.idPermissaoParaCompartilhar(uid)
        : null;

    if (permissaoId == null) {
      return _linhaSwitchCompartilhar(
        contato: contato,
        status: contato['status_compartilhamento'] as String? ??
            MonitoramentoService.statusCompartilharInexistente,
        l10n: l10n,
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        final status = snapshot.data?.data()?['status'] as String? ??
            (contato['status_compartilhamento'] as String? ??
                MonitoramentoService.statusCompartilharInexistente);
        return _linhaSwitchCompartilhar(contato: contato, status: status, l10n: l10n);
      },
    );
  }

  Widget _linhaSwitchCompartilhar({
    required Map<String, dynamic> contato,
    required String status,
    required AppLocalizations l10n,
  }) {
    final compartilhando = status == MonitoramentoService.statusAprovado;
    final String rotuloStatus = compartilhando
        ? l10n.monitoramentoStatusAprovado
        : l10n.monitoramentoStatusBloqueado;

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        l10n.monitoramentoPermitirReceberLocalizacao,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        rotuloStatus,
        // CORREÇÃO (pedido do usuário, 2026-08-11): rótulo "Bloqueado"
        // usava cinza — sem destaque nenhum de urgência/restrição.
        // Agora vermelho quando bloqueado, mesma cor verde de sempre
        // quando aprovado.
        style: TextStyle(
          fontSize: 12,
          color: compartilhando ? Colors.green.shade700 : Colors.red.shade700,
          fontWeight: FontWeight.w600,
        ),
      ),
      // Cores padrão dos switches da aba Monitoramento (pedido do
      // usuário, 2026-08-11): verde quando ativado (permitido/
      // compartilhando), vermelho quando desativado (bloqueado) — antes
      // o estado desligado caía no cinza padrão do Material por falta de
      // `inactiveThumbColor`/`inactiveTrackColor` explícitos.
      activeColor: Colors.green.shade600,
      activeTrackColor: Colors.green.shade100,
      inactiveThumbColor: Colors.red.shade600,
      inactiveTrackColor: Colors.red.shade100,
      value: compartilhando,
      onChanged: (valor) => _alternarPermissaoCompartilhar(contato, valor),
    );
  }

  Future<void> _alternarPermissaoCompartilhar(
    Map<String, dynamic> contato,
    bool permitir,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final resultado = await _servico.definirPermissaoCompartilhamento(
      idContatoLocal: id,
      permitir: permitir,
    );
    if (!mounted || resultado == 'sucesso') return;

    final mensagem = switch (resultado) {
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      _ => l10n.monitoramentoErroSolicitar,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
      ),
    );
  }
}
