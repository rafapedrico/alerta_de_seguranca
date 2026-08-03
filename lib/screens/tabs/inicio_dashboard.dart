import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/locale_service.dart';

/// Conteúdo da nova Tela de Início (Dashboard) exibida no lugar das 4 abas
/// enquanto `HomeScreen._mostrandoInicio` for `true` — ver
/// [HomeScreen._mostrandoInicio]. Fundo 100% preto do topo ao rodapé,
/// puramente informacional: os cards de plano abrem modais explicativos
/// nesta própria tela — não navega para Configurações.
class InicioDashboard extends StatelessWidget {
  const InicioDashboard({super.key});

  static const String _site = 'https://www.guardiaox.com.br';
  static const String _whatsappNumero = '+1 581 709 5728';
  static const String _whatsappUrl = 'https://wa.me/15817095728';

  // Pacote Android real ainda não publicado (usa o id placeholder do
  // template do projeto) — usado só para montar o link da Play Store.
  static const String _androidPackageId = 'com.example.security_check_app';
  static const String _playStoreWebUrl =
      'https://play.google.com/store/apps/details?id=$_androidPackageId';
  static const String _playStoreAppUrl = 'market://details?id=$_androidPackageId';

  static const Color _corDestaquePremium = Color(0xFF9C6BFF);

  static Future<void> _abrirUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('⚠️ [InicioDashboard] Falha ao abrir URL "$url": $e');
    }
  }

  /// Abre a área de assinatura/compra do app na Play Store — tenta
  /// primeiro o app nativo da Play Store (`market://`) e cai para o link
  /// web caso o dispositivo não tenha a Play Store instalada.
  static Future<void> _abrirPlayStore() async {
    final uri = Uri.parse(_playStoreAppUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (e) {
      debugPrint('⚠️ [InicioDashboard] Falha ao abrir a Play Store nativa: $e');
    }
    await _abrirUrl(_playStoreWebUrl);
  }

  @override
  Widget build(BuildContext context) {
    // Container preservando o fundo preto por trás de todo o conteúdo,
    // inclusive na área de overscroll/bounce da ListView.
    return Container(
      color: Colors.black,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildCabecalho(context),
          _buildSecaoPlanos(context),
          _buildRodape(context),
        ],
      ),
    );
  }

  /// Imagem de destaque (a mesma por idioma usada no topo do Login, já
  /// com ícone + nome "Guardião-X" + ilustração embutidos) em largura
  /// total, com altura proporcional (sem forçar um tamanho fixo que
  /// distorça a imagem). DOIS níveis de fallback — se o asset do idioma
  /// atual falhar, cai para a imagem padrão em português; se até essa
  /// falhar, cai para um cabeçalho de texto simples — garantindo que a
  /// tela nunca fique em branco.
  Widget _buildCabecalho(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: LocaleService.codigoIdiomaCompletoNotifier,
      builder: (context, codigoIdioma, _) {
        return Image.asset(
          LocaleService.caminhoImagemLoginPara(codigoIdioma),
          width: double.infinity,
          fit: BoxFit.fitWidth,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            LocaleService.imagemLoginPadrao,
            width: double.infinity,
            fit: BoxFit.fitWidth,
            errorBuilder: (context, error, stackTrace) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  'Guardião-X',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSecaoPlanos(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: Text(
              l10n.dashboardSecaoPlanosTitulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // IntrinsicHeight: dá ao Row uma altura finita baseada no
          // conteúdo antes de aplicar `stretch`, permitindo que os dois
          // cartões fiquem com a mesma altura sem propagar uma altura
          // infinita para os filhos (o Row está dentro de uma ListView,
          // cuja altura vertical é irrestrita — aplicar `stretch` direto
          // ali quebrava o layout e deixava a tela em branco).
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _CartaoPlano(
                    titulo: l10n.dashboardPlanoFreeTitulo,
                    preco: null,
                    descricao: l10n.dashboardPlanoFreeDescricao,
                    corPrincipal: Colors.white24,
                    destaque: false,
                    onTap: () => _abrirModalFree(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _CartaoPlano(
                    titulo: l10n.planoPremiumTitulo,
                    preco: '${l10n.precoMensal}${l10n.porMes}',
                    descricao: l10n.dashboardPlanoPremiumDescricao,
                    corPrincipal: _corDestaquePremium,
                    destaque: true,
                    selo: l10n.premiumBadge,
                    onTap: () => _abrirModalPremium(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.dashboardAvisoWhatsappCredito,
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _abrirModalFree(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => _ModalDetalhePlano(
        icone: Icons.shield_outlined,
        corPrincipal: Colors.white24,
        titulo: l10n.dashboardPlanoFreeTitulo,
        destaque: '7 envios de mensagens ou solicitações de localização por mês',
        beneficios: const [
          'Check-in de segurança com cronômetro e PIN',
          'Botão de SOS manual com localização',
          'Até 3 contatos de emergência',
          'Monitoramento de localização entre familiares',
          'Histórico completo de alertas',
        ],
        botaoPrincipalTexto: 'Permanecer no Plano Free',
        onBotaoPrincipal: () => Navigator.of(ctx).pop(),
      ),
    );
  }

  void _abrirModalPremium(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => _ModalDetalhePlano(
        icone: Icons.workspace_premium,
        corPrincipal: _corDestaquePremium,
        titulo: l10n.planoPremiumTitulo,
        destaque: 'Todas as funções do Guardião-X, ILIMITADAS',
        beneficios: [
          l10n.beneficioAlertasNuvem,
          l10n.beneficioMensagensWhatsapp,
          l10n.beneficioGruposIlimitados,
          l10n.beneficioChatsCriptografados,
          l10n.beneficioBackupNuvem,
        ],
        botaoPrincipalTexto: 'Assinar Premium — ${l10n.precoMensal}${l10n.porMes}',
        onBotaoPrincipal: () {
          Navigator.of(ctx).pop();
          _abrirPlayStore();
        },
        botaoSecundarioTexto: l10n.agoraNao,
      ),
    );
  }

  Widget _buildRodape(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.dashboardFaqTitulo,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Theme(
            data: ThemeData.dark().copyWith(
              dividerColor: Colors.white24,
              colorScheme: const ColorScheme.dark(primary: Color(0xFF9CCC65)),
            ),
            child: Column(children: _faqItems.map(_buildFaqTile).toList()),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          Center(
            child: InkWell(
              onTap: () => _abrirUrl(_site),
              child: const Text(
                'www.guardiaox.com.br',
                style: TextStyle(
                  color: Color(0xFF9CCC65),
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          // A partir daqui (dados corporativos e central de atendimento)
          // todo o conteúdo fica centralizado, conforme pedido de UX.
          const Center(
            child: Text(
              'RMF Global LTDA',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text(
              'Rua Rio de Janeiro, número 243, Centro, '
              'Belo Horizonte, MG, CEP 30160-040',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          Center(
            child: Text(
              l10n.dashboardCentralAtendimentoTitulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: InkWell(
              onTap: () => _abrirUrl(_whatsappUrl),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FontAwesomeIcons.whatsapp, color: Color(0xFF25D366), size: 26),
                  SizedBox(width: 10),
                  Text(
                    _whatsappNumero,
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),

          // Padding inferior para o conteúdo não terminar colado na
          // BottomNavigationBar.
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildFaqTile(_FaqItem item) {
    return ExpansionTile(
      title: Text(
        item.pergunta,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
      ),
      iconColor: const Color(0xFF9CCC65),
      collapsedIconColor: Colors.white70,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            item.resposta,
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
        ),
      ],
    );
  }

  static final List<_FaqItem> _faqItems = [
    const _FaqItem(
      pergunta: 'Como funciona o check-in de segurança?',
      resposta:
          'Você define um tempo na aba Segurança e, se não confirmar que está bem com '
          'seu PIN antes do cronômetro zerar, o app entende que algo pode estar errado '
          'e dispara um alerta de emergência automaticamente para seus contatos.',
    ),
    const _FaqItem(
      pergunta: 'O que o botão de SOS faz?',
      resposta:
          'Dispara imediatamente um alerta de emergência com sua localização para os '
          'contatos cadastrados, sem precisar esperar o cronômetro de check-in.',
    ),
    const _FaqItem(
      pergunta: 'Como funciona o Monitoramento entre familiares?',
      resposta:
          'Permite compartilhar localização em tempo real com contatos de confiança, '
          'sempre com consentimento explícito nos dois sentidos — ninguém vê sua '
          'localização sem que você autorize.',
    ),
    const _FaqItem(
      pergunta: 'O que são os "Alertas Enviados" no Histórico?',
      resposta:
          'É o registro dos alertas de emergência disparados pela sua própria conta. '
          'Por segurança, essa lista só pode ser visualizada após uma solicitação e um '
          'período de carência, evitando que alguém acesse esse histórico rapidamente '
          'no seu aparelho.',
    ),
    const _FaqItem(
      pergunta: 'Como funciona o alerta por WhatsApp?',
      resposta:
          'Além da notificação dentro do app, o Guardião X pode enviar uma mensagem de '
          'contingência via WhatsApp para os contatos que você habilitar, garantindo '
          'que o alerta chegue mesmo se o app deles estiver fechado.',
    ),
    const _FaqItem(
      pergunta: 'O que o Plano Premium oferece?',
      resposta:
          'Alertas em nuvem em tempo real, mais mensagens de contingência via WhatsApp, '
          'grupos de alerta ilimitados, chats criptografados e backup automático na nuvem.',
    ),
  ];
}

class _FaqItem {
  const _FaqItem({required this.pergunta, required this.resposta});
  final String pergunta;
  final String resposta;
}

/// Card de plano com visual moderno: fundo translúcido escuro para o
/// Free (discreto, se funde ao fundo preto da página) e um brilho/glow
/// gradiente para o Premium (borda e sombra luminosas, chamando atenção).
class _CartaoPlano extends StatelessWidget {
  const _CartaoPlano({
    required this.titulo,
    required this.preco,
    required this.descricao,
    required this.corPrincipal,
    required this.destaque,
    required this.onTap,
    this.selo,
  });

  final String titulo;
  final String? preco;
  final String descricao;
  final Color corPrincipal;
  final bool destaque;
  final VoidCallback onTap;
  final String? selo;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: destaque
              ? LinearGradient(
                  colors: [corPrincipal.withOpacity(0.85), const Color(0xFF4C1F91)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: destaque ? null : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: destaque ? corPrincipal.withOpacity(0.9) : Colors.white24,
            width: destaque ? 1.4 : 1,
          ),
          boxShadow: destaque
              ? [
                  BoxShadow(
                    color: corPrincipal.withOpacity(0.55),
                    blurRadius: 20,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selo != null) ...[
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, color: Colors.white, size: 12),
                      const SizedBox(width: 3),
                      Text(
                        selo!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              titulo,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (preco != null) ...[
              const SizedBox(height: 4),
              Text(
                preco!,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              descricao,
              style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal de detalhes de um plano (Free ou Premium), aberto ao tocar no
/// respectivo card. Estrutura compartilhada: ícone + título, banner de
/// destaque, lista de benefícios, nota de rodapé sobre o custo do envio
/// extra via WhatsApp, e ação(ões) no rodapé.
class _ModalDetalhePlano extends StatelessWidget {
  const _ModalDetalhePlano({
    required this.icone,
    required this.corPrincipal,
    required this.titulo,
    required this.destaque,
    required this.beneficios,
    required this.botaoPrincipalTexto,
    required this.onBotaoPrincipal,
    this.botaoSecundarioTexto,
  });

  final IconData icone;
  final Color corPrincipal;
  final String titulo;
  final String destaque;
  final List<String> beneficios;
  final String botaoPrincipalTexto;
  final VoidCallback onBotaoPrincipal;
  final String? botaoSecundarioTexto;

  static const String _notaRodape =
      '* O envio adicional para WhatsApp é um recurso opcional que pode ser '
      'ativado na página "Configurações" e tem um custo de US\$ 0,10 (10 '
      'centavos de dólar).';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(icone, color: corPrincipal),
          const SizedBox(width: 8),
          Expanded(child: Text(titulo)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: corPrincipal.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: corPrincipal.withOpacity(0.4)),
              ),
              child: Text(
                destaque,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: corPrincipal,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ...beneficios.map(
              (texto) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, size: 18, color: corPrincipal),
                    const SizedBox(width: 10),
                    Expanded(child: Text(texto, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _notaRodape,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
      actions: [
        if (botaoSecundarioTexto != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(botaoSecundarioTexto!),
          ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: corPrincipal),
          onPressed: onBotaoPrincipal,
          child: Text(botaoPrincipalTexto),
        ),
      ],
    );
  }
}
