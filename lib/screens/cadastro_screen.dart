import 'package:flutter/material.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;

/// Tela de Cadastro (primeiro acesso) do "SOS Security Personal".
///
/// MOCK/TEMPORÁRIO: assim como a [LoginScreen], não existe ainda
/// integração real com backend — o botão "Criar Conta" apenas simula um
/// cadastro bem-sucedido (sem persistir nada em servidor) e navega
/// DIRETAMENTE para o fluxo principal já existente do app
/// ([TelaInicialComPossivelDialogoPin]), substituindo toda a pilha de
/// navegação (Login + Cadastro), de forma que o usuário recém-cadastrado
/// não volte para essas telas ao apertar "voltar".
class CadastroScreen extends StatefulWidget {
  const CadastroScreen({super.key});

  @override
  State<CadastroScreen> createState() => _CadastroScreenState();
}

class _CadastroScreenState extends State<CadastroScreen> {
  static const Color _corPrincipal = Color(0xFF4C7040);

  final _formKey = GlobalKey<FormState>();
  final _nomeController = TextEditingController();
  final _emailController = TextEditingController();
  final _senhaController = TextEditingController();
  final _confirmarSenhaController = TextEditingController();

  bool _senhaVisivel = false;
  bool _confirmarSenhaVisivel = false;

  @override
  void dispose() {
    _nomeController.dispose();
    _emailController.dispose();
    _senhaController.dispose();
    _confirmarSenhaController.dispose();
    super.dispose();
  }

  /// MOCK: simula a criação de conta com sucesso e navega direto para o
  /// fluxo principal do app, removendo Login e Cadastro da pilha de
  /// navegação.
  void _criarContaMock() {
    if (_formKey.currentState?.validate() != true) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (context) =>
            const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
      ),
      (route) => false,
    );
  }

  void _voltarParaLogin() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCabecalho(),
                  const SizedBox(height: 40),
                  _buildCampoNome(),
                  const SizedBox(height: 16),
                  _buildCampoEmail(),
                  const SizedBox(height: 16),
                  _buildCampoSenha(),
                  const SizedBox(height: 16),
                  _buildCampoConfirmarSenha(),
                  const SizedBox(height: 28),
                  _buildBotaoCriarConta(),
                  const SizedBox(height: 20),
                  _buildLinkVoltarParaLogin(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Topo idêntico ao da tela de Login, mantendo a mesma identidade
  /// visual do "SOS Security Personal".
  Widget _buildCabecalho() {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: const BoxDecoration(
            color: _corPrincipal,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.shield, color: Colors.white, size: 44),
        ),
        const SizedBox(height: 18),
        const Text(
          'SOS Security Personal',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Crie sua conta para começar',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildCampoNome() {
    return TextFormField(
      controller: _nomeController,
      textInputAction: TextInputAction.next,
      decoration: _decoracaoInput(label: 'Nome completo', icone: Icons.person_outline),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return 'Informe seu nome';
        }
        return null;
      },
    );
  }

  Widget _buildCampoEmail() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      decoration: _decoracaoInput(label: 'E-mail', icone: Icons.email_outlined),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return 'Informe seu e-mail';
        }
        if (!valor.contains('@') || !valor.contains('.')) {
          return 'E-mail inválido';
        }
        return null;
      },
    );
  }

  Widget _buildCampoSenha() {
    return TextFormField(
      controller: _senhaController,
      obscureText: !_senhaVisivel,
      textInputAction: TextInputAction.next,
      decoration: _decoracaoInput(
        label: 'Senha',
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _senhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.grey,
          ),
          onPressed: () => setState(() => _senhaVisivel = !_senhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return 'Informe uma senha';
        }
        if (valor.length < 6) {
          return 'A senha deve ter ao menos 6 caracteres';
        }
        return null;
      },
    );
  }

  Widget _buildCampoConfirmarSenha() {
    return TextFormField(
      controller: _confirmarSenhaController,
      obscureText: !_confirmarSenhaVisivel,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _criarContaMock(),
      decoration: _decoracaoInput(
        label: 'Confirmar senha',
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _confirmarSenhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.grey,
          ),
          onPressed: () => setState(() => _confirmarSenhaVisivel = !_confirmarSenhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return 'Confirme sua senha';
        }
        if (valor != _senhaController.text) {
          return 'As senhas não coincidem';
        }
        return null;
      },
    );
  }

  Widget _buildBotaoCriarConta() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _criarContaMock,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        child: const Text(
          'Criar Conta',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildLinkVoltarParaLogin() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Já tem uma conta?', style: TextStyle(color: Colors.black54)),
        TextButton(
          onPressed: _voltarParaLogin,
          child: const Text(
            'Faça login',
            style: TextStyle(color: _corPrincipal, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Mesmo estilo de input arredondado/discreto usado na tela de Login.
  static InputDecoration _decoracaoInput({
    required String label,
    required IconData icone,
    Widget? sufixo,
  }) {
    final borda = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icone, color: Colors.grey),
      suffixIcon: sufixo,
      filled: true,
      fillColor: Colors.white,
      border: borda,
      enabledBorder: borda,
      focusedBorder: borda.copyWith(
        borderSide: const BorderSide(color: _corPrincipal, width: 1.5),
      ),
      errorBorder: borda.copyWith(
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
    );
  }
}
