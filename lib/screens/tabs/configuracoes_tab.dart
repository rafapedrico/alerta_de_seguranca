import 'package:flutter/material.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/font_scale_service.dart';
import 'package:flutter_contacts/flutter_contacts.dart';


// Planos de fundo reais disponíveis em assets/, com nomes elegantes.
const List<_PresetWallpaper> _presetWallpapers = [
  _PresetWallpaper('Azul Profundo', 'blue'),
  _PresetWallpaper('Escuro Absoluto', 'dark'),
  _PresetWallpaper('Cinza Urbano', 'gray'),
  _PresetWallpaper('Verde Botânico', 'green'),
  _PresetWallpaper('Lavanda Suave', 'lavender'),
  _PresetWallpaper('Luz Clássica', 'light'),
];

class ConfiguracoesTab extends StatefulWidget {
  const ConfiguracoesTab({super.key});

  @override
  State<ConfiguracoesTab> createState() => _ConfiguracoesTabState();
}

class _ConfiguracoesTabState extends State<ConfiguracoesTab> {
  final DatabaseHelper _db = DatabaseHelper();

  Map<String, dynamic>? _userConfig;
  bool _loading = true;

  // Máximo de contatos de emergência permitidos.
  static const int _maxContatos = 3;

  // Lista de contatos de emergência carregada do SQLite (tabela isolada
  // 'contatos_emergencia').
  List<Map<String, dynamic>> _contatosEmergencia = [];
  bool _carregandoContatos = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _carregarContatosEmergencia();
  }

  Future<void> _carregarContatosEmergencia() async {
    setState(() => _carregandoContatos = true);
    try {
      // Antes de exibir a lista, remove definitivamente qualquer contato
      // cuja trava de segurança de 24h já tenha expirado.
      await _db.processarExclusoesPendentesExpiradas();
      final contatos = await _db.getContatosEmergencia();
      if (mounted) {
        setState(() {
          _contatosEmergencia = contatos;
          _carregandoContatos = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _carregandoContatos = false);
    }
  }

  /// Retorna true se o contato estiver marcado como "exclusão pendente"
  /// (aguardando o prazo de segurança de 24h para remoção definitiva).
  bool _isExclusaoPendente(Map<String, dynamic> contato) {
    final valor = contato['exclusao_pendente'];
    return valor == 1 || valor == true;
  }

  /// Remove tudo que não for dígito do número de telefone (espaços,
  /// traços, parênteses, "+" etc.), garantindo que o número fique
  /// pronto para uso em links do WhatsApp (com DDI/DDD numéricos).
  String _limparNumeroTelefone(String numero) {
    return numero.replaceAll(RegExp(r'[^0-9]'), '');
  }

  /// Solicita permissão de acesso aos contatos e, caso concedida, abre o
  /// seletor nativo de contatos para o usuário escolher um familiar.
  /// Após a seleção, o número é limpo e salvo na tabela isolada
  /// 'contatos_emergencia' do SQLite.
  Future<void> _adicionarContatoDaAgenda() async {
    if (_contatosEmergencia.length >= _maxContatos) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Você já cadastrou o máximo de $_maxContatos contatos.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 1) Solicita permissão explicitamente ANTES de abrir a agenda.
    final bool permitido = await FlutterContacts.requestPermission(readonly: true);
    if (!permitido) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Permissão de acesso aos contatos foi negada.'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    // 2) Abre o seletor nativo de contatos do aparelho.
    Contact? contatoSelecionado;
    try {
      contatoSelecionado = await FlutterContacts.openExternalPick();
    } catch (_) {
      contatoSelecionado = null;
    }

    if (contatoSelecionado == null) return; // Usuário cancelou a seleção.

    // 3) Recupera os dados completos do contato (incluindo telefones).
    final contatoCompleto = await FlutterContacts.getContact(contatoSelecionado.id);
    if (contatoCompleto == null || contatoCompleto.phones.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Este contato não possui telefone cadastrado.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final nome = contatoCompleto.displayName.trim().isNotEmpty
        ? contatoCompleto.displayName.trim()
        : 'Sem nome';
    final telefoneOriginal = contatoCompleto.phones.first.number;
    final telefoneLimpo = _limparNumeroTelefone(telefoneOriginal);

    if (telefoneLimpo.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Número de telefone inválido.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 4) Salva na tabela isolada 'contatos_emergencia'.
    await _db.inserirContatoEmergencia({
      'nome': nome,
      'telefone': telefoneLimpo,
    });

    // Registra no histórico ('familia') a adição do novo contato de
    // emergência, tornando a ação 100% transparente e auditável.
    await _db.inserirEventoHistorico(
      titulo: 'Contato de emergência adicionado',
      descricao: '$nome foi cadastrado como contato de emergência.',
      categoria: 'familia',
    );

    await _carregarContatosEmergencia();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ $nome adicionado aos contatos de emergência!'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
        ),
      );
    }
  }


  /// Solicita a exclusão de um contato de emergência, ativando a trava de
  /// segurança de 24h. O contato NÃO é removido imediatamente: fica marcado
  /// como "exclusao_pendente" e continua recebendo alertas de emergência
  /// normalmente até que o prazo de 24h expire.
  Future<void> _excluirContato(int id, String nome) async {
    await _db.solicitarExclusaoContatoEmergencia(id);

    // Registra no histórico ('familia') a solicitação de exclusão do
    // contato, deixando claro que a remoção definitiva ainda está sujeita
    // à trava de segurança de 24h.
    await _db.inserirEventoHistorico(
      titulo: 'Exclusão de contato solicitada',
      descricao: '$nome terá a remoção efetivada em até 24 horas.',
      categoria: 'familia',
    );

    await _carregarContatosEmergencia();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏳ Solicitação recebida. $nome será removido em 24 horas.'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }



  Future<void> _loadConfig() async {
    setState(() => _loading = true);
    try {
      final config = await _db.getUserConfig();
      if (mounted) {
        setState(() {
          _userConfig = config;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? get _pinReal => _userConfig?['pin_real'] as String?;
  String? get _senhaPendente => _userConfig?['senha_pendente'] as String?;
  int get _tempoTolerancia => _userConfig?['tempo_padrao_timer'] as int? ?? 15;

  String get _tipoPlano => _userConfig?['tipo_plano'] as String? ?? 'free';
  String? get _planoDeFundoUrl => _userConfig?['plano_de_fundo_url'] as String?;

  Future<void> _ensureUserConfig() async {
    if (_userConfig == null) {
      final id = await _db.insertUserConfig({
        'pin_real': null,
        'tempo_padrao_timer': 15,
        'forcando_whatsapp': 0,
        'tipo_plano': 'free',
        'plano_de_fundo_url': null,
      });
      _userConfig = {'id': id, 'tipo_plano': 'free', 'forcando_whatsapp': 0, 'tempo_padrao_timer': 15};
    }
  }

  void _showPinRealDialog() {
    final pinController = TextEditingController(text: _pinReal ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.lock_outline, size: 22),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'PIN Real',
                softWrap: true,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Defina um PIN de 4 dígitos para acesso normal ao app.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: pinController,
                decoration: const InputDecoration(
                  labelText: 'PIN Real',
                  hintText: 'Digite 4 números',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.pin),
                  counterText: '',
                ),
                maxLength: 4,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 12),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Informe o PIN';
                  if (v.trim().length != 4) return 'Deve ter exatamente 4 dígitos';
                  if (int.tryParse(v.trim()) == null) return 'Apenas números';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              await _savePinReal(pinController.text.trim());
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  Future<void> _savePinReal(String pin) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;

    // Regra de negócio:
    // 1) Primeiro cadastro (nenhum PIN ainda definido): o PIN é efetivado
    //    INSTANTANEAMENTE, sem qualquer carência.
    // 2) Alteração de um PIN já existente: a nova senha fica pendente por
    //    24 horas, mantendo a senha atual intacta até o prazo se cumprir.
    //
    // O método do DatabaseHelper decide qual dos dois casos se aplica e
    // retorna `true` quando a efetivação foi instantânea (primeiro
    // cadastro) ou `false` quando ficou pendente (alteração).
    final bool efetivadoInstantaneamente =
        await _db.salvarOuAgendarPinReal(id, pin);

    if (efetivadoInstantaneamente) {
      // Registra no histórico ('sistema') o cadastro inicial do PIN.
      await _db.inserirEventoHistorico(
        titulo: 'PIN de acesso definido',
        descricao: 'PIN de acesso cadastrado e ativado imediatamente '
            '(primeiro cadastro, sem carência de segurança).',
        categoria: 'sistema',
      );
    } else {
      // Registra no histórico ('sistema') a solicitação de troca do PIN,
      // deixando claro que a nova senha só entra em vigor após 24h.
      await _db.inserirEventoHistorico(
        titulo: 'Alteração de PIN solicitada',
        descricao: 'Nova senha de acesso pendente, entrará em vigor em 24 horas.',
        categoria: 'sistema',
      );
    }

    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            efetivadoInstantaneamente
                ? '🔒 PIN definido com sucesso!'
                : '🔒 Solicitação recebida. A nova senha entrará em vigor em 24 horas.',
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }


  void _showToleranciaDialog() {
    final toleranciaController = TextEditingController(text: _tempoTolerancia.toString());
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.hourglass_top, size: 22, color: Color(0xFF4C7040)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Tempo de Tolerância',
                softWrap: true,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Indique o tempo extra (em minutos) antes que o disparo silencioso de emergência seja feito de forma automática.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: toleranciaController,
                decoration: const InputDecoration(
                  labelText: 'Minutos de Tolerância',
                  hintText: 'Ex: 10',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.av_timer),
                ),
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Informe o tempo';
                  final numero = int.tryParse(v.trim());
                  if (numero == null || numero <= 0) return 'Digite um número maior que 0';
                  if (numero > 60) return 'O tempo máximo é 60 minutos';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final minutos = int.parse(toleranciaController.text.trim());
              await _saveTolerancia(minutos);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Salvar'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF4C7040)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTolerancia(int minutos) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({'id': id, 'tempo_padrao_timer': minutos});

    // Registra no histórico ('sistema') a alteração da tolerância padrão.
    await _db.inserirEventoHistorico(
      titulo: 'Tolerância de rotina alterada',
      descricao: 'Novo tempo de tolerância configurado: $minutos minutos.',
      categoria: 'sistema',
    );

    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏱️ Tolerância de rotina ajustada para $minutos min!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }


  void _showWallpaperDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alterar Plano de Fundo'),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            itemCount: _presetWallpapers.length,
            itemBuilder: (ctx, index) {
              final wp = _presetWallpapers[index];
              final isSelected = _planoDeFundoUrl == wp.key;
              return GestureDetector(
                onTap: () {
                  _saveWallpaper(wp.key);
                  Navigator.of(ctx).pop();
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                        width: isSelected ? 3 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.3),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          'assets/${wp.key}.png',
                          fit: BoxFit.cover,
                        ),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0.0),
                                Colors.black.withOpacity(0.55),
                              ],
                            ),
                          ),
                        ),
                        if (isSelected)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                              size: 22,
                            ),
                          ),
                        Positioned(
                          left: 4,
                          right: 4,
                          bottom: 4,
                          child: Text(
                            wp.label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: Colors.white,
                              shadows: const [
                                Shadow(color: Colors.black87, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveWallpaper(String key) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({'id': id, 'plano_de_fundo_url': key});

    // Registra no histórico ('sistema') a alteração do plano de fundo.
    await _db.inserirEventoHistorico(
      titulo: 'Plano de fundo alterado',
      descricao: 'Novo plano de fundo selecionado: $key.',
      categoria: 'sistema',
    );

    // Espelha a escolha em SharedPreferences para acesso rápido/síncrono
    // nas demais telas (ex: Segurança, Família).
    await WallpaperService.salvar('assets/$key.png');
    await _loadConfig();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎨 Plano de fundo alterado!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Abre um modal inferior (showModalBottomSheet) com as opções de
  /// tamanho de fonte disponíveis para acessibilidade visual.
  void _mostrarModalTamanhoFonte(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ValueListenableBuilder<double>(
          valueListenable: FontScaleService.fontScaleNotifier,
          builder: (context, fatorAtual, _) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Row(
                      children: [
                        Icon(Icons.text_fields, color: Color(0xFF4C7040)),
                        SizedBox(width: 8),
                        Text(
                          'Tamanho das Letras',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: 'Pequeno',
                    fator: FontScaleService.pequeno,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 14,
                  ),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: 'Padrão',
                    fator: FontScaleService.padrao,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 16,
                  ),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: 'Grande',
                    fator: FontScaleService.grande,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 18,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _opcaoTamanhoFonte(
    BuildContext ctx, {
    required String label,
    required double fator,
    required double fatorAtual,
    required double amostraFontSize,
  }) {
    final bool isSelected = fatorAtual == fator;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? const Color(0xFF4C7040) : Colors.grey,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: amostraFontSize,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: Text(
        'Aa',
        style: TextStyle(fontSize: amostraFontSize, color: Colors.grey.shade600),
      ),
      onTap: () async {
        await _salvarTamanhoFonte(fator);
        if (ctx.mounted) Navigator.of(ctx).pop();
      },
    );
  }

  Future<void> _salvarTamanhoFonte(double fator) async {
    await FontScaleService.salvar(fator);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🔤 Tamanho das letras: ${FontScaleService.rotuloPara(fator)}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }


  void _showPremiumModal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.workspace_premium, color: Colors.amber.shade700),
            const SizedBox(width: 8),
            const Text('Plano Premium'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _benefitRow(Icons.cloud_done, 'Alertas em nuvem em tempo real'),
            const SizedBox(height: 8),
            _benefitRow(
              Icons.chat,
              'Até 10 mensagens de contingência via WhatsApp',
            ),
            const SizedBox(height: 8),
            _benefitRow(Icons.group, 'Criar grupos de alertas ilimitados'),
            const SizedBox(height: 8),
            _benefitRow(
              Icons.lock,
              'Chats criptografados com áudio e vídeo',
            ),
            const SizedBox(height: 8),
            _benefitRow(Icons.backup, 'Backup automático na nuvem'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Agora não'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              _upgradeToPremium();
            },
            icon: Icon(Icons.star, color: Colors.amber.shade200),
            label: const Text('Assinar R\$ 9,90/mês'),
          ),
        ],
      ),
    );
  }

  Widget _benefitRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.green.shade600),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
      ],
    );
  }

  Future<void> _upgradeToPremium() async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({'id': id, 'tipo_plano': 'premium'});
    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.celebration, color: Colors.white),
              SizedBox(width: 8),
              Expanded(child: Text('🎉 Plano Premium ativado!')),
            ],
          ),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isPremium = _tipoPlano == 'premium';

    return ValueListenableBuilder<String>(
      valueListenable: WallpaperService.wallpaperNotifier,
      builder: (context, fundoAtivo, _) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(fundoAtivo),
              fit: BoxFit.cover,
            ),
          ),
          child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [

        _sectionHeader(theme, Icons.security, 'Segurança'),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: _pinReal != null ? Colors.green.shade100 : Colors.orange.shade100,
            child: Icon(
              _pinReal != null ? Icons.lock : Icons.lock_open,
              color: _pinReal != null ? Colors.green.shade700 : Colors.orange.shade700,
            ),
          ),
          title: const Text(
            'PIN Real',
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            _senhaPendente != null
                ? '⏳ Nova senha pendente (aguardando 24h para ativar)'
                : (_pinReal != null ? '✅ Definido' : '⚠️ Não definido'),
            softWrap: true,
            overflow: TextOverflow.clip,
            style: TextStyle(
              color: _senhaPendente != null
                  ? Colors.blue.shade600
                  : (_pinReal != null ? Colors.green.shade600 : Colors.orange.shade600),
              fontSize: 13,
            ),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showPinRealDialog,
        ),

        const Divider(),

        // =========================================
        // SEÇÃO: CONTATOS DE EMERGÊNCIA
        // =========================================
        _sectionHeader(theme, Icons.contact_emergency, 'Contatos de Emergência'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Cadastre até $_maxContatos familiares que receberão o alerta em caso de emergência.',
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
        const SizedBox(height: 12),

        if (_carregandoContatos)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_contatosEmergencia.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'Nenhum contato cadastrado ainda.',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: List.generate(_contatosEmergencia.length, (index) {
                final contato = _contatosEmergencia[index];
                final id = contato['id'] as int;
                final nome = contato['nome'] as String? ?? 'Sem nome';
                final telefone = contato['telefone'] as String? ?? '';
                return Card(
                  elevation: 0,
                  color: Colors.white,
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE8F5E9),
                      child: Text(
                        nome.isNotEmpty ? nome[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: Color(0xFF4C7040),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      nome,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: _isExclusaoPendente(contato)
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.hourglass_bottom, size: 14, color: Colors.orange),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  'Removendo em 24h...',
                                  softWrap: true,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.orange.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Text(
                            telefone,
                            softWrap: true,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                    trailing: _isExclusaoPendente(contato)
                        ? const Icon(Icons.hourglass_bottom, color: Colors.orange)
                        : IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            tooltip: 'Excluir contato',
                            onPressed: () => _excluirContato(id, nome),
                          ),
                  ),
                );
              }),
            ),
          ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _contatosEmergencia.length >= _maxContatos
                  ? null
                  : _adicionarContatoDaAgenda,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text(
                '+ Adicionar Contato da Agenda',
                softWrap: true,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4C7040),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        const Divider(),

        _sectionHeader(theme, Icons.av_timer, 'Rotina e Contingência'),



        ListTile(

          leading: CircleAvatar(
            backgroundColor: const Color(0xFFE8F5E9),
            child: Icon(Icons.hourglass_bottom, color: const Color(0xFF4C7040)),
          ),
          title: const Text(
            'Tempo de Tolerância de Rotina',
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            '$_tempoTolerancia minutos de atraso permitidos',
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showToleranciaDialog,
        ),

        const Divider(),

        _sectionHeader(theme, Icons.palette, 'Visual do Chat'),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.purple.shade100,
            child: Icon(Icons.wallpaper, color: Colors.purple.shade700),
          ),
          title: const Text(
            'Alterar Plano de Fundo',
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            _planoDeFundoUrl != null
                ? _presetWallpapers
                        .firstWhere(
                          (w) => w.key == _planoDeFundoUrl,
                          orElse: () => const _PresetWallpaper('Luz Clássica', 'light'),
                        )
                        .label
                : 'Luz Clássica (padrão)',
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Image.asset(
                'assets/${_planoDeFundoUrl ?? 'light'}.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          onTap: _showWallpaperDialog,
        ),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.teal.shade50,
            child: Icon(Icons.text_fields, color: Colors.teal.shade700),
          ),
          title: const Text(
            'Tamanho das Letras',
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            FontScaleService.rotuloPara(FontScaleService.fontScaleNotifier.value),
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _mostrarModalTamanhoFonte(context),
        ),

        const Divider(),

        _sectionHeader(theme, Icons.workspace_premium, 'Plano'),


        if (isPremium)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.shade400, Colors.orange.shade600],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.withOpacity(0.4),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.verified, color: Colors.white, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Plano Familiar Ativo',
                          softWrap: true,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Todos os recursos premium disponíveis',
                          softWrap: true,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.25),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'Premium',
                          softWrap: true,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: GestureDetector(
              onTap: _showPremiumModal,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.indigo.shade500, Colors.purple.shade600],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.indigo.withOpacity(0.4),
                      blurRadius: 15,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.workspace_premium,
                            color: Colors.amber.shade300, size: 32),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            'Premium',
                            softWrap: true,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              color: Colors.amber.shade200,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Proteja quem você ama',
                      softWrap: true,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mude para o Plano Premium',
                      softWrap: true,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: 8,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'R\$ 9,90',
                              softWrap: true,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '/mês',
                              softWrap: true,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Ver mais',
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                style: TextStyle(
                                  color: Colors.indigo.shade600,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.arrow_forward,
                                size: 16,
                                color: Colors.indigo.shade600,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
      ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String title) {

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetWallpaper {
  final String label;
  final String key;

  const _PresetWallpaper(this.label, this.key);
}
