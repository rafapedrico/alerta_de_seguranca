import 'package:flutter/material.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;
import 'cadastro_screen.dart';

/// Tela de Login do "SOS Security Personal".
///
/// MOCK/TEMPORÁRIO: por enquanto não existe integração real com backend
/// de autenticação — o botão "Entrar" apenas simula um login bem-sucedido
/// (sem validar e-mail/senha contra nenhum servidor) e navega diretamente
/// para o fluxo já existente do app ([TelaInicialComPossivelDialogoPin],
/// que por sua vez exibe a [HomeScreen] com toda a lógica de segurança
/// já implementada: check-in, PIN de coação, alarme nativo, etc.).
///
/// Esta tela é puramente visual/de UX nesta etapa. A troca por um fluxo
/// de autenticação real (validação de credenciais, persistência de
/// sessão/token, tela de erro em caso de falha) fica para uma etapa
/// futura.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const Color _corPrincipal = Color(0xFF4C7040);

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _senhaController = TextEditingController();
  bool _senhaVisivel = false;

  @override
  void dispose() {
    _emailController.dispose();
    _senhaController.dispose();
    super.dispose();
  }

  /// MOCK: simula um login bem-sucedido sem nenhuma validação real de
  /// backend, e navega diretamente para o fluxo principal do app já
  /// existente ([TelaInicialComPossivelDialogoPin]), substituindo a rota
  /// de Login na pilha de navegação (o usuário não deve conseguir voltar
  /// para o Login apertando o botão "voltar" do Android após logar).
  void _fazerLoginMock() {
    if (_formKey.currentState?.validate() != true) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
      ),
    );
  }

  void _abrirEsqueciMinhaSenha() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Recuperação de senha em breve.')),
    );
  }

  void _abrirCadastro() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const CadastroScreen()),
    );
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
                  const SizedBox(height: 48),
                  _buildCampoEmail(),
                  const SizedBox(height: 16),
                  _buildCampoSenha(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _abrirEsqueciMinhaSenha,
                      child: const Text(
                        'Esqueci minha senha',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildBotaoEntrar(),
                  const SizedBox(height: 20),
                  _buildLinkCadastro(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Topo: ícone de escudo centralizado dentro de um círculo com a cor
  /// verde principal do app, seguido do nome oficial em destaque.
  Widget _buildCabecalho() {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            color: _corPrincipal,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.shield, color: Colors.white, size: 48),
        ),
        const SizedBox(height: 20),
        const Text(
          'SOS Security Personal',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.3,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Entre para continuar protegido(a)',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildCampoEmail() {
    return TextFormField(
      controller: _emailController,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      decoration: _decoracaoInput(
        label: 'E-mail',
        icone: Icons.email_outlined,
      ),
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
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _fazerLoginMock(),
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
          return 'Informe sua senha';
        }
        return null;
      },
    );
  }

  Widget _buildBotaoEntrar() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _fazerLoginMock,
        style: ElevatedButton.styleFrom(
          backgroundColor: _corPrincipal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 2,
        ),
        child: const Text(
          'Entrar',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildLinkCadastro() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Não tem uma conta?', style: TextStyle(color: Colors.black54)),
        TextButton(
          onPressed: _abrirCadastro,
          child: const Text(
            'Cadastre-se',
            style: TextStyle(color: _corPrincipal, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Estilo compartilhado (arredondado, discreto) para os inputs desta
  /// tela e da tela de Cadastro.
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
