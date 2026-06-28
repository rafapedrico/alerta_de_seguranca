import 'package:flutter/material.dart';
import '../../services/database_helper.dart';

// Simulated preset wallpapers for chat background
const List<_PresetWallpaper> _presetWallpapers = [
  _PresetWallpaper('Padrão Claro', 'light', 0xFFF5F5F5),
  _PresetWallpaper('Padrão Escuro', 'dark', 0xFF121212),
  _PresetWallpaper('Azul Suave', 'blue', 0xFFE3F2FD),
  _PresetWallpaper('Verde Natureza', 'green', 0xFFE8F5E9),
  _PresetWallpaper('Lavanda', 'lavender', 0xFFF3E5F5),
  _PresetWallpaper('Cinza Elegante', 'gray', 0xFFEEEEEE),
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

  @override
  void initState() {
    super.initState();
    _loadConfig();
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
  String? get _pinCoacao => _userConfig?['pin_coacao'] as String?;
  int get _tempoTolerancia => _userConfig?['tempo_padrao_timer'] as int? ?? 15;
  String get _tipoPlano => _userConfig?['tipo_plano'] as String? ?? 'free';
  String? get _planoDeFundoUrl => _userConfig?['plano_de_fundo_url'] as String?;
  
  String get _telefone1 => _userConfig?['telefone_emergencia_1'] as String? ?? '';
  String get _telefone2 => _userConfig?['telefone_emergencia_2'] as String? ?? '';

  Future<void> _ensureUserConfig() async {
    if (_userConfig == null) {
      final id = await _db.insertUserConfig({
        'pin_real': null,
        'pin_coacao': null,
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
            Text('PIN Real'),
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
    await _db.updateUserConfig({'id': id, 'pin_real': pin});
    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ PIN Real definido com sucesso!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showPinCoacaoDialog() {
    final pinController = TextEditingController(text: _pinCoacao ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 22, color: Colors.orange),
            SizedBox(width: 8),
            Text('PIN de Coação'),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.orange.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Este PIN é usado em situações de coação. '
                        'Ao digitar este PIN no lugar do real, o app '
                        'aparenta funcionar normalmente, mas ativa '
                        'silenciosamente o alerta para seus contatos de emergência.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: pinController,
                decoration: const InputDecoration(
                  labelText: 'PIN de Coação',
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
                  if (v.trim() == _pinReal) return 'Deve ser diferente do PIN Real';
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
              await _savePinCoacao(pinController.text.trim());
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  Future<void> _savePinCoacao(String pin) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({'id': id, 'pin_coacao': pin});
    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ PIN de Coação definido com sucesso!'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showTelefonesDialog() {
    final tel1Controller = TextEditingController(text: _telefone1);
    final tel2Controller = TextEditingController(text: _telefone2);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.contact_phone, size: 22, color: Colors.blue),
            SizedBox(width: 8),
            Text('Contatos de Alerta'),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Cadastre os números com DDD (ex: 11999999999). O app tentará enviar primeiro via notificação interna e, caso falhe, pelo WhatsApp.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: tel1Controller,
                decoration: const InputDecoration(
                  labelText: 'Telefone de Emergência 1',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Informe pelo menos um número';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: tel2Controller,
                decoration: const InputDecoration(
                  labelText: 'Telefone de Emergência 2 (Opcional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone_android),
                ),
                keyboardType: TextInputType.phone,
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
              await _saveTelefones(tel1Controller.text.trim(), tel2Controller.text.trim());
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTelefones(String t1, String t2) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({
      'id': id, 
      'telefone_emergencia_1': t1,
      'telefone_emergencia_2': t2,
    });
    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Contatos de emergência atualizados!'),
          behavior: SnackBarBehavior.floating,
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
            Text('Tempo de Tolerância'),
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
                child: Container(
                  decoration: BoxDecoration(
                    color: Color(wp.colorValue),
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
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSelected ? Icons.check_circle : Icons.wallpaper,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade600,
                        size: 28,
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          wp.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.grey.shade700,
                          ),
                        ),
                      ),
                    ],
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

    return ListView(
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
          title: const Text('PIN Real'),
          subtitle: Text(
            _pinReal != null ? '✅ Definido' : '⚠️ Não definido',
            style: TextStyle(
              color: _pinReal != null ? Colors.green.shade600 : Colors.orange.shade600,
              fontSize: 13,
            ),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showPinRealDialog,
        ),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: _pinCoacao != null ? Colors.green.shade100 : Colors.orange.shade100,
            child: Icon(
              _pinCoacao != null ? Icons.warning_amber : Icons.warning_amber_outlined,
              color: _pinCoacao != null ? Colors.green.shade700 : Colors.orange.shade700,
            ),
          ),
          title: const Text('PIN de Coação'),
          subtitle: Text(
            _pinCoacao != null ? '✅ Definido' : '⚠️ Não definido',
            style: TextStyle(
              color: _pinCoacao != null ? Colors.green.shade600 : Colors.orange.shade600,
              fontSize: 13,
            ),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showPinCoacaoDialog,
        ),

        const Divider(),

        _sectionHeader(theme, Icons.av_timer, 'Rotina e Contingência'),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.blue.shade50,
            child: const Icon(Icons.contact_phone, color: Colors.blue),
          ),
          title: const Text('Contatos de Emergência'),
          subtitle: Text(
            _telefone1.isNotEmpty ? '📞 $_telefone1' : '⚠️ Nenhum telefone cadastrado',
            style: const TextStyle(fontSize: 13),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showTelefonesDialog,
        ),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFE8F5E9),
            child: Icon(Icons.hourglass_bottom, color: const Color(0xFF4C7040)),
          ),
          title: const Text('Tempo de Tolerância de Rotina'),
          subtitle: Text(
            '$_tempoTolerancia minutos de atraso permitidos',
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
          title: const Text('Alterar Plano de Fundo'),
          subtitle: Text(
            _planoDeFundoUrl != null
                ? _presetWallpapers
                        .firstWhere(
                          (w) => w.key == _planoDeFundoUrl,
                          orElse: () => const _PresetWallpaper('Customizado', 'custom', 0xFFF5F5F5),
                        )
                        .label
                : 'Padrão',
            style: const TextStyle(fontSize: 13),
          ),
          trailing: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _planoDeFundoUrl != null
                  ? Color(
                      _presetWallpapers
                          .firstWhere(
                            (w) => w.key == _planoDeFundoUrl,
                            orElse: () => const _PresetWallpaper('', 'default', 0xFFF5F5F5),
                          )
                          .colorValue,
                    )
                  : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
          ),
          onTap: _showWallpaperDialog,
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Plano Familiar Ativo',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Todos os recursos premium disponíveis',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
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
                        Text(
                          'Premium',
                          style: TextStyle(
                            color: Colors.amber.shade200,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Proteja quem você ama',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mude para o Plano Premium',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text(
                          'R\$ 9,90',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '/mês',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
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
  final int colorValue;

  const _PresetWallpaper(this.label, this.key, this.colorValue);
}