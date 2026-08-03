import 'package:flutter/material.dart';

/// Tela dedicada de Perguntas Frequentes (FAQ), acessada a partir do
/// botão "Perguntas Frequentes (FAQ)" na Tela de Início (Dashboard) — ver
/// [InicioDashboard]. Fundo 100% preto AMOLED, com campo de busca que
/// filtra as perguntas/respostas em tempo real e uma lista de
/// [ExpansionTile] estilizados no mesmo padrão visual escuro do restante
/// do app.
class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  final TextEditingController _buscaController = TextEditingController();
  String _termoBusca = '';

  @override
  void dispose() {
    _buscaController.dispose();
    super.dispose();
  }

  List<_FaqItem> get _itensFiltrados {
    if (_termoBusca.trim().isEmpty) return _todasAsPerguntas;
    final termo = _termoBusca.trim().toLowerCase();
    return _todasAsPerguntas
        .where((item) =>
            item.pergunta.toLowerCase().contains(termo) ||
            item.resposta.toLowerCase().contains(termo))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final itens = _itensFiltrados;
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
        title: const Text('Perguntas Frequentes (FAQ)'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _buscaController,
              onChanged: (valor) => setState(() => _termoBusca = valor),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar em perguntas e respostas...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                suffixIcon: _termoBusca.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white38),
                        onPressed: () {
                          _buscaController.clear();
                          setState(() => _termoBusca = '');
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF1A1B26),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          Expanded(
            child: itens.isEmpty
                ? const Center(
                    child: Text(
                      'Nenhuma pergunta encontrada.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    itemCount: itens.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _buildFaqTile(itens[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqTile(_FaqItem item) {
    return Theme(
      data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1B26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: Text(
            item.pergunta,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          iconColor: const Color(0xFF9CCC65),
          collapsedIconColor: Colors.white70,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                item.resposta,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static final List<_FaqItem> _todasAsPerguntas = [
    const _FaqItem(
      pergunta:
          'Os alertas de emergência são enviados para os números cadastrados '
          'mesmo se meu celular estiver desligado ou sem sinal de internet?',
      resposta:
          'Sim, os alarmes da página "Família" e o cronômetro regressivo da '
          'página "Segurança" são agendados no servidor do banco de dados do '
          'aplicativo Guardião-X. Se o cronômetro estourar o tempo de '
          'tolerância sem o desarme com a senha do PIN, ou o alarme da '
          'página "Família" não for desarmado após o tempo de tolerância, '
          'imediatamente é enviado um alerta de segurança com a última '
          'localização registrada na nuvem.',
    ),
    const _FaqItem(
      pergunta:
          'A partir de quantos minutos se começa o envio da localização para '
          'o banco de dados do Guardião-X?',
      resposta:
          'A localização começa a ser enviada 120 minutos antes do fim do '
          'cronômetro ou do tempo programado do despertador da página '
          'Família.',
    ),
    const _FaqItem(
      pergunta:
          'Por que se exige um tempo programado para a efetivação da nova '
          'senha ou para a exclusão dos contatos de emergência?',
      resposta:
          'Como o aplicativo Guardião-X tem o objetivo de proteger a '
          'segurança do usuário, este tempo de espera tem como finalidade '
          'evitar que pessoas não autorizadas desbloqueiem algumas das '
          'funções programadas que estão esperando o tempo para ser enviado '
          'o alerta de emergência para os números cadastrados.',
    ),
    const _FaqItem(
      pergunta:
          'Por que na página "Histórico" foi colocada a opção de tempo de '
          'espera caso o usuário decida restringir a visualização imediata '
          'das informações contidas sobre as mensagens de alertas enviadas?',
      resposta:
          'Em casos extremos onde a integridade física do usuário esteja em '
          'risco, talvez o usuário decida que nenhuma outra pessoa saiba que '
          'sua localização ou foto tenha sido enviada para algum número '
          'cadastrado.',
    ),
    const _FaqItem(
      pergunta:
          'Por que quando são utilizados os botões de pânico físico ou da '
          'página de "Segurança" são enviadas duas mensagens de alerta?',
      resposta:
          'Esta função do botão de pânico tem como prioridade máxima a '
          'segurança do usuário. Quando o botão de pânico físico ou da '
          'página "Segurança" é acionado, imediatamente é enviada uma '
          'mensagem de alerta de emergência para os números cadastrados '
          'contendo a localização. Em seguida, após abrir a câmera do '
          'aparelho e a foto ser registrada pelo usuário, uma segunda '
          'mensagem de alerta de emergência é enviada contendo a foto. Isto '
          'garante que a localização chegará ao número cadastrado mesmo se '
          'o usuário demorar ou não registrar a foto.',
    ),
    const _FaqItem(
      pergunta:
          'É possível rastrear e acompanhar a localização de algum aparelho '
          'que não tenha o aplicativo Guardião-X instalado no celular?',
      resposta:
          'Não é possível. A localização só pode ser compartilhada de '
          'aplicativo para aplicativo e apenas com o consentimento e '
          'permissão de ambos os usuários.',
    ),
    const _FaqItem(
      pergunta:
          'É seguro fazer o pagamento para contratar o plano premium ou '
          'depositar dinheiro na carteira de crédito?',
      resposta:
          'Sim, é seguro. Nenhum pagamento é efetuado direto para a empresa '
          'RMF GLOBAL. Todos os pagamentos são efetuados direto na '
          'plataforma do Google Play Store ou Apple App Store, com total '
          'garantia das plataformas.',
    ),
    const _FaqItem(
      pergunta: 'Posso resgatar o dinheiro depositado na carteira de crédito?',
      resposta:
          'Sim, conforme regulamento do Google Play Store e Apple, todos os '
          'valores financeiros depositados como fundo de crédito podem ser '
          'reembolsados pelo usuário. Esta devolução é feita diretamente '
          'pela instituição financeira e pelas plataformas Google Play '
          'Store e Apple seguindo a política de proteção ao crédito do '
          'consumidor. Em caso de resgate de qualquer valor da carteira de '
          'crédito será debitado o valor de US\$ 0,50 (cinquenta centavos de '
          'dólar).',
    ),
    const _FaqItem(
      pergunta: 'Como é feito o compartilhamento dos alertas de emergência?',
      resposta:
          'Todas as mensagens de alerta de segurança são enviadas de duas '
          'formas padrão: de aplicativo para aplicativo e por SMS para os '
          'números de celular cadastrados na página de "Configurações".',
    ),
    const _FaqItem(
      pergunta:
          'Como funciona o envio adicional de alerta de emergência para o '
          'WhatsApp?',
      resposta:
          'O envio de mensagem para o WhatsApp é uma forma adicional de '
          'segurança, sendo a terceira camada de proteção como garantia '
          'extra de que o número cadastrado terá uma garantia a mais de que '
          'o alerta de emergência chegará ao destino e será visualizado '
          'pelo usuário. Cada mensagem enviada para cada número de WhatsApp '
          'será cobrada uma taxa de serviço de US\$ 0,10 (dez centavos de '
          'dólar). As mensagens para o WhatsApp só serão enviadas se houver '
          'fundos na carteira de crédito, se estiver ativada a autorização '
          'para o envio de mensagens para o WhatsApp (na página de '
          'Configurações) e se algum número de celular estiver ativado para '
          'receber estas mensagens.',
    ),
    const _FaqItem(
      pergunta: 'Como funciona o serviço de atendimento ao consumidor?',
      resposta:
          'O chat do WhatsApp foi programado para responder de maneira '
          'automática a maioria das dúvidas e solicitações do usuário. As '
          'solicitações feitas no menu "Falar com o atendente físico" '
          'seguirão as normas dos regulamentos da política estabelecida '
          'pela empresa RMF GLOBAL, onde os usuários do plano Premium serão '
          'atendidos prioritariamente em até 24 horas e os usuários do '
          'plano Free serão atendidos por um atendente físico em até 72 '
          'horas.',
    ),
    const _FaqItem(
      pergunta:
          'As mensagens de alerta de emergência só serão enviadas para os '
          'números cadastrados que tiverem o aplicativo Guardião-X '
          'instalado no celular?',
      resposta:
          'Não. Recomendamos que ambos os celulares tenham o aplicativo '
          'instalado, mas mesmo se o celular de destino não tiver o '
          'Guardião-X, o alerta de emergência é enviado por meio de SMS ou '
          'pelo WhatsApp.',
    ),
  ];
}

class _FaqItem {
  const _FaqItem({required this.pergunta, required this.resposta});
  final String pergunta;
  final String resposta;
}
