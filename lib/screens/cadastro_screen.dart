import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
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
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corCampoFundo = Color(0xFF1E313F);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  final _formKey = GlobalKey<FormState>();
  final _nomeController = TextEditingController();
  final _emailController = TextEditingController();
  final _celularController = TextEditingController();
  final _senhaController = TextEditingController();
  final _confirmarSenhaController = TextEditingController();

  bool _senhaVisivel = false;
  bool _confirmarSenhaVisivel = false;

  @override
  void dispose() {
    _nomeController.dispose();
    _emailController.dispose();
    _celularController.dispose();
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
      backgroundColor: _corFundo,
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
                  _buildCampoCelular(),
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
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppLocalizations.of(context)!.cadastroSubtitulo,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildCampoNome() {
    return TextFormField(
      controller: _nomeController,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoNomeLabel,
        icone: Icons.person_outline,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoNomeObrigatorio;
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
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoEmailLabel,
        icone: Icons.email_outlined,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoEmailObrigatorio;
        }
        if (!valor.contains('@') || !valor.contains('.')) {
          return AppLocalizations.of(context)!.campoEmailInvalido;
        }
        return null;
      },
    );
  }

  Widget _buildCampoCelular() {
    return TextFormField(
      controller: _celularController,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoCelularLabel,
        icone: Icons.phone_android_outlined,
      ),
      validator: (valor) {
        if (valor == null || valor.trim().isEmpty) {
          return AppLocalizations.of(context)!.campoCelularObrigatorio;
        }
        final digitos = valor.replaceAll(RegExp(r'\D'), '');
        if (digitos.length < 10) {
          return AppLocalizations.of(context)!.campoCelularInvalido;
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
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoSenhaLabel,
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _senhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.white70,
          ),
          onPressed: () => setState(() => _senhaVisivel = !_senhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return AppLocalizations.of(context)!.campoSenhaObrigatoria;
        }
        if (valor.length < 6) {
          return AppLocalizations.of(context)!.campoSenhaMinima;
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
      style: const TextStyle(color: Colors.white),
      decoration: _decoracaoInput(
        label: AppLocalizations.of(context)!.campoConfirmarSenhaLabel,
        icone: Icons.lock_outline,
        sufixo: IconButton(
          icon: Icon(
            _confirmarSenhaVisivel ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.white70,
          ),
          onPressed: () => setState(() => _confirmarSenhaVisivel = !_confirmarSenhaVisivel),
        ),
      ),
      validator: (valor) {
        if (valor == null || valor.isEmpty) {
          return AppLocalizations.of(context)!.campoConfirmarSenhaObrigatoria;
        }
        if (valor != _senhaController.text) {
          return AppLocalizations.of(context)!.senhasNaoCoincidem;
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
        child: Text(
          AppLocalizations.of(context)!.botaoCriarConta,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildLinkVoltarParaLogin() {
    // Wrap (em vez de Row) permite que o texto quebre para uma segunda
    // linha em idiomas cuja tradução é mais longa que o espaço
    // disponível, evitando overflow horizontal.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(AppLocalizations.of(context)!.jaTemConta, style: const TextStyle(color: Colors.white70)),
        TextButton(
          onPressed: _voltarParaLogin,
          child: Text(
            AppLocalizations.of(context)!.facaLogin,
            style: const TextStyle(color: _corAcentoClaro, fontWeight: FontWeight.bold),
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
      labelStyle: const TextStyle(color: Colors.white70),
      prefixIcon: Icon(icone, color: Colors.white70),
      suffixIcon: sufixo,
      filled: true,
      fillColor: _corCampoFundo,
      border: borda,
      enabledBorder: borda,
      focusedBorder: borda.copyWith(
        borderSide: const BorderSide(color: _corAcentoClaro, width: 1.5),
      ),
      errorBorder: borda.copyWith(
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
    );
  }
}
