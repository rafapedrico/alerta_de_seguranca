import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/locale_service.dart';

/// Conteúdo da nova Tela de Início (Dashboard) exibida no lugar das 4 abas
/// enquanto `HomeScreen._mostrandoInicio` for `true` — ver
/// [HomeScreen._mostrandoInicio]. Puramente informacional/navegacional:
/// não lê nem grava nenhum estado de plano ou configuração diretamente,
/// reaproveitando toda a lógica de upgrade/downgrade já existente em
/// `ConfiguracoesTab` através do callback [aoAbrirConfiguracoes].
class InicioDashboard extends StatelessWidget {
  const InicioDashboard({super.key, required this.aoAbrirConfiguracoes});

  final VoidCallback aoAbrirConfiguracoes;

  static const String _site = 'https://www.guardiaox.com.br';
  static const String _whatsappNumero = '+1 581 709 5728';
  static const String _whatsappUrl = 'https://wa.me/15817095728';

  Future<void> _abrirUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // Cabeçalho + imagem de destaque: a mesma imagem por idioma usada
        // no topo do Login (já embute ícone + nome "Guardião-X" +
        // ilustração), reaproveitada aqui em largura total.
        ValueListenableBuilder<String>(
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
              ),
            );
          },
        ),

        _buildSecaoPlanos(context),

        _buildRodape(context),
      ],
    );
  }

  Widget _buildSecaoPlanos(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.dashboardSecaoPlanosTitulo,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _CartaoPlano(
                  titulo: l10n.dashboardPlanoFreeTitulo,
                  preco: null,
                  descricao: l10n.dashboardPlanoFreeDescricao,
                  cores: [Colors.grey.shade200, Colors.grey.shade300],
                  corTexto: Colors.black87,
                  onTap: aoAbrirConfiguracoes,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CartaoPlano(
                  titulo: l10n.planoPremiumTitulo,
                  preco: '${l10n.precoMensal}${l10n.porMes}',
                  descricao: l10n.dashboardPlanoPremiumDescricao,
                  cores: [Colors.indigo.shade500, Colors.purple.shade600],
                  corTexto: Colors.white,
                  onTap: aoAbrirConfiguracoes,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRodape(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 24),
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
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

          const Text(
            'RMF Global LTDA',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Rua Rio de Janeiro, número 243, Centro, '
            'Belo Horizonte, MG, CEP 30160-040',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          Text(
            l10n.dashboardCentralAtendimentoTitulo,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          InkWell(
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

class _CartaoPlano extends StatelessWidget {
  const _CartaoPlano({
    required this.titulo,
    required this.preco,
    required this.descricao,
    required this.cores,
    required this.corTexto,
    required this.onTap,
  });

  final String titulo;
  final String? preco;
  final String descricao;
  final List<Color> cores;
  final Color corTexto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: cores,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              titulo,
              style: TextStyle(color: corTexto, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (preco != null) ...[
              const SizedBox(height: 4),
              Text(
                preco!,
                style: TextStyle(color: corTexto, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              descricao,
              style: TextStyle(color: corTexto.withOpacity(0.85), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
