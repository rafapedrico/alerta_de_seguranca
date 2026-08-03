import 'package:flutter/material.dart';

/// Tela jurídica dedicada, com o Contrato de Consentimento do Usuário e a
/// Política de Privacidade do aplicativo Guardião-X, operado pela RMF
/// Global LTDA. Acessada pelos links no rodapé da Tela de Início
/// (Dashboard) — ver [InicioDashboard].
///
/// AVISO IMPORTANTE: o conteúdo abaixo é um MODELO GENÉRICO (boilerplate)
/// redigido para cobrir as funcionalidades reais do app (localização,
/// SMS, câmera, armazenamento em nuvem e dados de contatos de
/// emergência). NÃO substitui a revisão de um advogado antes do uso
/// comercial real do aplicativo.
class TermosPrivacidadeScreen extends StatefulWidget {
  const TermosPrivacidadeScreen({super.key, this.abaInicial = 0});

  /// 0 = abre direto no Contrato de Consentimento, 1 = Política de
  /// Privacidade.
  final int abaInicial;

  @override
  State<TermosPrivacidadeScreen> createState() => _TermosPrivacidadeScreenState();
}

class _TermosPrivacidadeScreenState extends State<TermosPrivacidadeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.abaInicial,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  static const TextStyle _estiloTituloSecao = TextStyle(
    color: Colors.white,
    fontSize: 15,
    fontWeight: FontWeight.bold,
  );
  static const TextStyle _estiloCorpo = TextStyle(
    color: Colors.white70,
    fontSize: 13,
    height: 1.5,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          tooltip: 'Início',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Termos e Privacidade'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF9CCC65),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: 'Contrato de Consentimento'),
            Tab(text: 'Política de Privacidade'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildConteudo(_secoesContrato),
          _buildConteudo(_secoesPrivacidade),
        ],
      ),
    );
  }

  Widget _buildConteudo(List<_Secao> secoes) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        const Text(
          'RMF Global LTDA',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 4),
        const Text(
          'Rua Rio de Janeiro, número 243, Centro, Belo Horizonte, MG, CEP 30160-040',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 20),
        for (final secao in secoes) ...[
          Text(secao.titulo, style: _estiloTituloSecao),
          const SizedBox(height: 6),
          Text(secao.corpo, style: _estiloCorpo),
          const SizedBox(height: 18),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1B26),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: const Text(
            'Este documento é um modelo padrão elaborado para descrever as '
            'funcionalidades reais do aplicativo Guardião-X e deve ser '
            'revisado por um profissional jurídico antes de qualquer uso '
            'comercial em produção.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  static const List<_Secao> _secoesContrato = [
    _Secao(
      titulo: '1. Objeto',
      corpo:
          'O presente Contrato de Consentimento regula o uso do aplicativo '
          'Guardião-X, desenvolvido e operado pela RMF Global LTDA '
          '("RMF Global"), destinado a auxiliar o usuário em situações de '
          'emergência pessoal por meio de check-in de segurança, alertas '
          'automáticos, compartilhamento de localização entre familiares e '
          'contatos de confiança, e captura de evidências fotográficas.',
    ),
    _Secao(
      titulo: '2. Consentimento para uso de localização',
      corpo:
          'Ao ativar o cronômetro de check-in, o botão de SOS, ou o '
          'monitoramento entre familiares, o usuário consente expressamente '
          'com a coleta e o envio da sua localização geográfica (GPS) para '
          'os servidores do Guardião-X e para os contatos de emergência '
          'cadastrados, inclusive de forma automática caso o check-in não '
          'seja confirmado dentro do prazo configurado.',
    ),
    _Secao(
      titulo: '3. Consentimento para envio de mensagens (SMS/App/WhatsApp)',
      corpo:
          'O usuário consente com o envio de mensagens de alerta (contendo '
          'localização, contexto informado e, quando aplicável, fotografia) '
          'para os números de telefone e contas cadastradas como contatos '
          'de emergência, por SMS, notificação entre aplicativos e, '
          'quando habilitado nas Configurações, por WhatsApp — este último '
          'sujeito à cobrança adicional informada dentro do aplicativo.',
    ),
    _Secao(
      titulo: '4. Consentimento para uso da câmera',
      corpo:
          'O usuário consente que, em determinados cenários de emergência '
          '(término do cronômetro sem confirmação, acionamento do botão de '
          'pânico ou tentativa de desarme malsucedida), o aplicativo poderá '
          'abrir automaticamente a câmera do aparelho para capturar uma '
          'fotografia, a ser enviada como evidência adicional aos contatos '
          'de emergência cadastrados.',
    ),
    _Secao(
      titulo: '5. Prazos de segurança (carência)',
      corpo:
          'Determinadas ações sensíveis (alteração de senha/PIN, exclusão '
          'de contatos de emergência, visualização imediata de histórico) '
          'estão sujeitas a um prazo de carência antes de serem efetivadas, '
          'com o objetivo de impedir que terceiros não autorizados '
          'desativem funções de segurança do usuário sob coação.',
    ),
    _Secao(
      titulo: '6. Pagamentos e carteira de crédito',
      corpo:
          'Assinaturas do Plano Premium e recargas da carteira de crédito '
          'são processadas exclusivamente pelas plataformas Google Play '
          'Store e Apple App Store, sujeitas às respectivas políticas de '
          'cobrança, reembolso e proteção ao consumidor dessas '
          'plataformas — a RMF Global não recebe nem processa pagamentos '
          'diretamente.',
    ),
    _Secao(
      titulo: '7. Revogação do consentimento',
      corpo:
          'O usuário pode revogar este consentimento a qualquer momento '
          'desinstalando o aplicativo ou solicitando a exclusão de sua '
          'conta e dos dados associados pelos canais de atendimento '
          'indicados no aplicativo, respeitados os prazos de carência de '
          'segurança descritos na Seção 5.',
    ),
  ];

  static const List<_Secao> _secoesPrivacidade = [
    _Secao(
      titulo: '1. Dados coletados',
      corpo:
          'Coletamos: (a) dados de localização (GPS) durante o uso das '
          'funções de check-in, SOS e monitoramento; (b) fotografias '
          'capturadas pela função de Captura e Dissuasão; (c) dados de '
          'contatos de emergência cadastrados pelo próprio usuário (nome e '
          'telefone); (d) dados de cadastro e autenticação (e-mail, senha/ '
          'PIN criptografado); e (e) dados técnicos do aparelho necessários '
          'ao funcionamento dos alertas (status de conectividade, versão do '
          'app).',
    ),
    _Secao(
      titulo: '2. Finalidade do uso dos dados',
      corpo:
          'Os dados coletados são usados exclusivamente para viabilizar as '
          'funções de segurança do aplicativo: disparo de alertas de '
          'emergência, compartilhamento de localização consentido entre '
          'usuários, envio de evidências fotográficas e manutenção do '
          'histórico de eventos de segurança da própria conta do usuário.',
    ),
    _Secao(
      titulo: '3. Armazenamento e nuvem',
      corpo:
          'Parte dos dados é armazenada localmente no aparelho (banco de '
          'dados local criptografado) e parte é sincronizada com serviços '
          'de nuvem (Firebase/Firestore e armazenamento de mídia) operados '
          'pela RMF Global, com o objetivo de garantir que alertas de '
          'emergência sejam entregues mesmo que o aparelho do usuário seja '
          'desligado, destruído ou perca conexão após o disparo.',
    ),
    _Secao(
      titulo: '4. Compartilhamento com terceiros',
      corpo:
          'A localização e as evidências fotográficas só são '
          'compartilhadas com os contatos de emergência expressamente '
          'cadastrados pelo próprio usuário, e — no caso do monitoramento '
          'entre familiares — apenas mediante consentimento explícito de '
          'ambas as partes. Não vendemos nem compartilhamos dados pessoais '
          'com terceiros para fins publicitários.',
    ),
    _Secao(
      titulo: '5. Segurança dos dados',
      corpo:
          'Senhas e PINs são armazenados de forma criptografada. O acesso a '
          'funções sensíveis (troca de senha, exclusão de contatos, '
          'histórico de alertas) é protegido por prazos de carência e '
          'confirmação por PIN, conforme descrito no Contrato de '
          'Consentimento.',
    ),
    _Secao(
      titulo: '6. Direitos do usuário',
      corpo:
          'O usuário pode, a qualquer momento, solicitar a exclusão da sua '
          'conta e dos dados pessoais armazenados, corrigir dados '
          'cadastrais incorretos e revogar autorizações concedidas a '
          'contatos de monitoramento, pelos canais de atendimento '
          'indicados no aplicativo.',
    ),
    _Secao(
      titulo: '7. Contato',
      corpo:
          'Dúvidas sobre esta Política de Privacidade podem ser '
          'encaminhadas à RMF Global LTDA pelos canais de atendimento '
          'informados na Tela de Início do aplicativo (WhatsApp e '
          'endereço institucional).',
    ),
  ];
}

class _Secao {
  const _Secao({required this.titulo, required this.corpo});
  final String titulo;
  final String corpo;
}
