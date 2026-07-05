import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';


class SegurancaTab extends StatefulWidget {
  const SegurancaTab({super.key});

  @override
  State<SegurancaTab> createState() => _SegurancaTabState();
}

class _SegurancaTabState extends State<SegurancaTab> {
  final DatabaseHelper _db = DatabaseHelper();

  // Canal nativo (MethodChannel) usado para disparar SMS diretamente via
  // Android SmsManager, sem depender de pacotes externos de terceiros.
  static const MethodChannel _canalSms =
      MethodChannel('com.example.security_check_app/sms');

  // Controlador para o campo de Anotações/Dica de Contexto
  final TextEditingController _contextoController = TextEditingController();

  // Estilos de texto reutilizados na tela, centralizados para evitar
  // duplicação e facilitar futuras alterações de tema.
  static const TextStyle _estiloTituloSecao = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: Colors.black87,
  );
  static const TextStyle _estiloLabelPicker = TextStyle(
    color: Colors.grey,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle _estiloRodape = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: Colors.grey,
    fontStyle: FontStyle.italic,
  );
  static const TextStyle _estiloBloqueioTitulo = TextStyle(
    color: Colors.white,
    fontSize: 20,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.5,
  );
  static const TextStyle _estiloBloqueioTolerancia = TextStyle(
    color: Colors.amber,
    fontSize: 16,
    fontWeight: FontWeight.w500,
  );

  // Variáveis do Banco de Dados
  String? _pinRealConfirmado;
  String? _pinCoacaoConfirmado;
  String? _senhaPendente;
  String? _timestampAlteracaoSenha;

  // Regra de segurança: 24 horas em milissegundos
  static const int _prazoSegurancaMs = 86400000;

  // Variáveis de controle do Timer Padrão
  int _horaSelecionada = 0;
  int _minutoSelecionada = 5;

  // Variáveis de controle do Timer Ativo
  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  // Estado de Bloqueio por PIN
  bool _estaBloqueadoAguardandoPIN = false;
  Timer? _timerToleranciaBloqueio;
  int _segundosToleranciaBloqueio = 60;
  String _pinDigitadoNoBloqueio = '';

  @override
  void initState() {
    super.initState();
    _carregarConfiguracoesSeguranca();
  }

  @override
  void dispose() {
    _contextoController.dispose();
    _timer?.cancel();
    _timerToleranciaBloqueio?.cancel();
    super.dispose();
  }

  Future<void> _carregarConfiguracoesSeguranca() async {
    try {
      final config = await _db.getUserConfig();
      if (config != null && mounted) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
          _pinCoacaoConfirmado = config['pin_coacao'] as String?;
          _senhaPendente = config['senha_pendente'] as String?;
          _timestampAlteracaoSenha = config['timestamp_alteracao_senha'] as String?;
        });
        // Verifica se o prazo de segurança de 24h já expirou, e caso
        // afirmativo, efetiva a troca de senha pendente automaticamente.
        await _processarSenhaPendenteSeExpirada();
      }
    } catch (_) {}
  }

  /// Verifica se existe uma senha pendente e se o prazo de segurança de
  /// 24 horas desde a solicitação já se passou. Se sim, promove a senha
  /// pendente para senha principal (pin_real) e limpa os campos temporários.
  /// Caso contrário, mantém a senha antiga como válida para autenticação.
  Future<void> _processarSenhaPendenteSeExpirada() async {
    if (_senhaPendente == null || _timestampAlteracaoSenha == null) return;

    final timestampSolicitacao = int.tryParse(_timestampAlteracaoSenha!);
    if (timestampSolicitacao == null) return;

    final agora = DateTime.now().millisecondsSinceEpoch;
    final decorrido = agora - timestampSolicitacao;

    if (decorrido >= _prazoSegurancaMs) {
      // Prazo de segurança cumprido: efetiva a nova senha.
      final config = await _db.getUserConfig();
      if (config == null) return;
      final id = config['id'] as int;
      await _db.updateUserConfig({
        'id': id,
        'pin_real': _senhaPendente,
        'senha_pendente': null,
        'timestamp_alteracao_senha': null,
      });
      if (mounted) {
        setState(() {
          _pinRealConfirmado = _senhaPendente;
          _senhaPendente = null;
          _timestampAlteracaoSenha = null;
        });
      }
    }
    // Se ainda não passaram 24h, nada é feito: a senha antiga
    // (_pinRealConfirmado) continua sendo a única válida para autenticação.
  }

  /// Ação disparada ao tocar no botão circular de check-in.
  ///
  /// Regra de segurança crítica: uma vez que o timer esteja ativo (em
  /// contagem regressiva), ele NUNCA pode ser cancelado diretamente por um
  /// simples toque. Em vez disso, o toque interrompe a contagem regressiva
  /// e abre a MESMA tela de bloqueio com teclado de PIN (com os mesmos 60s
  /// de tolerância) usada quando o timer expira naturalmente. Isso garante
  /// que, mesmo para desarmar voluntariamente, o usuário precise confirmar
  /// com o PIN — permitindo que a vítima sinalize coação mesmo ao tentar
  /// simplesmente "cancelar" o check-in na frente de um agressor.
  void _alternarTimer() {
    if (_isTimerAtivo) {
      _ativarBloqueioDeSeguranca();
    } else {
      _iniciarTimer();
    }
  }


  void _iniciarTimer() {
    _carregarConfiguracoesSeguranca();
    int totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);

    if (totalSegundos <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, selecione um tempo maior que zero!')),
      );
      return;
    }

    setState(() {
      _segundosRestantes = totalSegundos;
      _isTimerAtivo = true;
      _estaBloqueadoAguardandoPIN = false;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        _timer?.cancel();
        _ativarBloqueioDeSeguranca();
      }
    });
  }

  void _pararTimer() {
    _timer?.cancel();
    _timerToleranciaBloqueio?.cancel();
    setState(() {
      _isTimerAtivo = false;
      _estaBloqueadoAguardandoPIN = false;
      _segundosRestantes = 0;
      _pinDigitadoNoBloqueio = '';
    });
  }

  void _ativarBloqueioDeSeguranca() {
    setState(() {
      _estaBloqueadoAguardandoPIN = true;
      _segundosToleranciaBloqueio = 60;
      _pinDigitadoNoBloqueio = '';
    });

    _timerToleranciaBloqueio = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_segundosToleranciaBloqueio > 0) {
        setState(() {
          _segundosToleranciaBloqueio--;
        });
      } else {
        _timerToleranciaBloqueio?.cancel();
        _executarDisparoDeEmergencia();
      }
    });
  }

  void _pressionarTecladoPIN(String caractere) {
    if (_pinDigitadoNoBloqueio.length < 4) {
      setState(() {
        _pinDigitadoNoBloqueio += caractere;
      });
    }

    if (_pinDigitadoNoBloqueio.length == 4) {
      _verificarPINInserido();
    }
  }

  /// Verifica o PIN digitado no teclado de bloqueio, comparando com os dois
  /// PINs possíveis cadastrados pelo usuário:
  ///
  /// - PIN real: desarma o sistema normalmente, sem disparar alerta.
  /// - PIN de coação (sob ameaça): desarma "aparentemente" a tela mostrando
  ///   a MESMA mensagem de sucesso do PIN real (para não levantar suspeitas
  ///   de quem estiver coagindo o usuário), mas dispara silenciosamente o
  ///   alerta de emergência em segundo plano, sem qualquer indicação visual.
  /// - Qualquer outro valor: trata como PIN incorreto e dispara o alerta de
  ///   emergência normalmente (comportamento já existente).
  void _verificarPINInserido() {
    if (_pinDigitadoNoBloqueio == _pinRealConfirmado) {
      _pararTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Check-in desarmado com sucesso!'), backgroundColor: Colors.green),
      );
    } else if (_pinCoacaoConfirmado != null &&
        _pinCoacaoConfirmado!.isNotEmpty &&
        _pinDigitadoNoBloqueio == _pinCoacaoConfirmado) {
      _executarDisparoDeCoacaoSilencioso();
    } else {
      _executarDisparoDeEmergencia();
    }
  }

  /// Dispara o alerta de emergência de forma totalmente silenciosa, usando
  /// exatamente a mesma mensagem padrão de emergência (para não deixar
  /// rastro visível no dispositivo caso seja inspecionado pelo agressor).
  /// A interface finge que o check-in foi desarmado com sucesso, idêntico
  /// ao fluxo do PIN real, para não alertar quem estiver coagindo o usuário.
  Future<void> _executarDisparoDeCoacaoSilencioso() async {
    _pararTimer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Check-in desarmado com sucesso!'), backgroundColor: Colors.green),
      );
    }
    // Dispara o alerta em segundo plano, sem qualquer feedback visual
    // adicional, mesmo que o envio de SMS falhe.
    await _dispararAlertaDeEmergencia();
  }

  /// Formata uma [Position] em texto legível (latitude/longitude + link do
  /// Google Maps) para ser inserida no corpo do SMS.
  String _formatarPosicao(Position posicao) {
    return 'Latitude: ${posicao.latitude}, Longitude: ${posicao.longitude} '
        '(https://maps.google.com/?q=${posicao.latitude},${posicao.longitude})';
  }

  /// Obtém a localização a ser usada no alerta de emergência, com estratégia
  /// resiliente para garantir que o SMS nunca saia sem coordenadas caso
  /// exista algum registro histórico de localização no aparelho:
  ///
  /// 1. Busca primeiro a última localização conhecida (rápida, em cache).
  /// 2. Tenta obter a localização atual com alta precisão e timeout curto.
  /// 3. Se a localização atual falhar/der timeout, usa a última conhecida
  ///    obtida no passo 1 como fallback.
  Future<String> _obterLocalizacaoFormatada() async {
    Position? ultimaConhecida;

    // Passo 1: última localização conhecida (não depende de sinal de GPS
    // em tempo real, é praticamente instantânea).
    try {
      ultimaConhecida = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    try {
      bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) {
        if (ultimaConhecida != null) {
          return _formatarPosicao(ultimaConhecida);
        }
        return 'Localização indisponível (serviço de GPS desativado no aparelho).';
      }

      LocationPermission permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        if (ultimaConhecida != null) {
          return _formatarPosicao(ultimaConhecida);
        }
        return 'Localização indisponível (permissão de localização negada).';
      }

      // Passo 2: tenta obter a localização atual com alta precisão e
      // timeout curto, para não travar o disparo de emergência.
      try {
        final posicaoAtual = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 7),
        );
        return _formatarPosicao(posicaoAtual);
      } catch (_) {
        // Passo 3: falhou ou deu timeout (ex: sem sinal de GPS).
        // Usa a última localização conhecida como fallback, se existir.
        if (ultimaConhecida != null) {
          return _formatarPosicao(ultimaConhecida);
        }
        return 'Não foi possível obter a localização atual do aparelho.';
      }
    } catch (_) {
      if (ultimaConhecida != null) {
        return _formatarPosicao(ultimaConhecida);
      }
      return 'Não foi possível obter a localização atual do aparelho.';
    }
  }

  /// Monta a mensagem de alerta e dispara o SMS de emergência para todos os
  /// contatos cadastrados. Extraído em método próprio para ser reaproveitado
  /// tanto pelo disparo normal (timer expirado / PIN incorreto) quanto pelo
  /// disparo silencioso via PIN de coação.
  ///
  /// Qualquer falha no envio (ex: SmsManager indisponível, permissão
  /// negada, etc.) é apenas registrada via [debugPrint] e nunca exibida ao
  /// usuário, garantindo que o fluxo de coação permaneça 100% silencioso.
  Future<void> _dispararAlertaDeEmergencia() async {
    String anotacoesUsuario = _contextoController.text.trim();
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = 'Nenhuma anotação de contexto informada pelo usuário.';
    }

    // Busca os contatos de emergência salvos na tabela isolada
    // 'contatos_emergencia' (cadastrados na aba Família via Agenda).
    // Inclui também os contatos com exclusão pendente (ainda dentro da
    // trava de segurança de 24h), pois continuam válidos para receber
    // alertas de emergência até que a exclusão seja efetivada.
    List<Map<String, dynamic>> contatosEmergencia = [];
    try {
      contatosEmergencia = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ Falha ao buscar contatos de emergência: $e');
    }

    // Obtém e formata a última localização conhecida (coordenadas de
    // latitude/longitude) para incluir no corpo do SMS.
    final localizacaoFormatada = await _obterLocalizacaoFormatada();

    final mensagemAlerta =
        'ALERTA DE EMERGÊNCIA! Não realizei meu check-in de segurança.\n'
        'Localização: $localizacaoFormatada\n'
        'Contexto: $anotacoesUsuario';

    debugPrint('🚨 DISPARANDO ALERTA MÁXIMO DE EMERGÊNCIA!');
    debugPrint('📋 Mensagem enviada via SMS: $mensagemAlerta');

    // Coleta os números de telefone de todos os destinatários cadastrados
    // (incluindo os que estão com exclusão pendente).
    final List<String> numerosDestinatarios = contatosEmergencia
        .map((contato) => (contato['telefone'] as String?) ?? '')
        .where((telefone) => telefone.isNotEmpty)
        .toList();

    if (numerosDestinatarios.isNotEmpty) {
      try {
        // Dispara o alerta via SMS nativo do aparelho, chamando o
        // MethodChannel implementado em MainActivity.kt, que por sua vez
        // usa o SmsManager do Android para enviar as mensagens de forma
        // totalmente invisível e em segundo plano (sem depender de
        // pacotes externos ou do WhatsApp).
        await _canalSms.invokeMethod('enviarSms', {
          'telefones': numerosDestinatarios,
          'mensagem': mensagemAlerta,
        });
      } catch (e) {
        // Nunca exibimos erro ao usuário: qualquer falha aqui é apenas
        // registrada para depuração, mantendo o fluxo 100% silencioso
        // (essencial para o cenário de PIN de coação).
        debugPrint('⚠️ Falha ao enviar SMS de emergência: $e');
      }
    } else {
      debugPrint('⚠️ Nenhum contato de emergência cadastrado para receber o alerta.');
    }
  }

  Future<void> _executarDisparoDeEmergencia() async {
    _timerToleranciaBloqueio?.cancel();
    await _dispararAlertaDeEmergencia();
    _pararTimer();
  }


  String _formatarTempo(int totalSegundos) {
    int horas = totalSegundos ~/ 3600;
    int minutos = (totalSegundos % 3600) ~/ 60;
    int segundos = totalSegundos % 60;
    return "${horas.toString().padLeft(2, '0')}:${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    if (_estaBloqueadoAguardandoPIN) {
      return _buildTelaBloqueio();
    }
    return _buildTelaPrincipal();
  }

  /// Tela exibida quando o timer expira e o sistema aguarda a digitação do
  /// PIN (real ou de coação) dentro do prazo de tolerância.
  Widget _buildTelaBloqueio() {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.security, color: Colors.redAccent, size: 50),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'SISTEMA BLOQUEADO',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: _estiloBloqueioTitulo,
              ),
            ),

            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Tempo de tolerância: ${_segundosToleranciaBloqueio}s',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: _estiloBloqueioTolerancia,
              ),
            ),
            const SizedBox(height: 32),
            _buildIndicadoresPIN(),
            const SizedBox(height: 40),
            Expanded(child: _buildTecladoPIN()),
          ],
        ),
      ),
    );
  }

  /// Bolinhas indicadoras de quantos dígitos do PIN já foram digitados.
  Widget _buildIndicadoresPIN() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        bool preenchido = index < _pinDigitadoNoBloqueio.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: preenchido ? Colors.redAccent : Colors.white24,
            border: Border.all(color: Colors.white54),
          ),
        );
      }),
    );
  }

  /// Teclado numérico exibido na tela de bloqueio para digitação do PIN.
  Widget _buildTecladoPIN() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 20,
          mainAxisSpacing: 20,
          childAspectRatio: 1.3,
        ),
        itemCount: 12,
        itemBuilder: (context, index) {
          if (index == 9) return const SizedBox.shrink();
          if (index == 11) {
            return IconButton(
              icon: const Icon(Icons.backspace_outlined, color: Colors.white70, size: 28),
              onPressed: () {
                if (_pinDigitadoNoBloqueio.isNotEmpty) {
                  setState(() {
                    _pinDigitadoNoBloqueio = _pinDigitadoNoBloqueio.substring(0, _pinDigitadoNoBloqueio.length - 1);
                  });
                }
              },
            );
          }
          String numero = index == 10 ? '0' : (index + 1).toString();
          return ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.08),
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              elevation: 0,
            ),
            onPressed: () => _pressionarTecladoPIN(numero),
            child: Text(numero, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          );
        },
      ),
    );
  }

  /// Tela de funcionamento normal com plano de fundo dinâmico, sincronizado
  /// em tempo real com a escolha feita em Configurações.
  Widget _buildTelaPrincipal() {
    return Scaffold(
      backgroundColor: Colors.transparent, // Permite que o fundo do Container apareça
      body: ValueListenableBuilder<String>(
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
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildCampoContexto(),
                  const SizedBox(height: 24),
                  const Text(
                    'Daqui quanto tempo vou chegar',
                    textAlign: TextAlign.center,
                    softWrap: true,
                    overflow: TextOverflow.clip,
                    style: _estiloTituloSecao,
                  ),
                  const SizedBox(height: 16),
                  _buildSeletoresDeTempo(),
                  const SizedBox(height: 32),
                  _buildBotaoCheckIn(),
                  const SizedBox(height: 32),
                  _buildRodape(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Card com o campo de texto para anotações/dica de contexto.
  Widget _buildCampoContexto() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Row(
          children: [
            const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _contextoController,
                enabled: !_isTimerAtivo,
                decoration: const InputDecoration(
                  labelText: 'Dica de Contexto',
                  hintText: 'Ex: Placa do carro / Ônibus / Localização',
                  hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Seletores (pickers estilo iOS) de horas e minutos para definir a
  /// duração do timer de check-in.
  Widget _buildSeletoresDeTempo() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _horaSelecionada),
                onSelectedItemChanged: (index) => setState(() => _horaSelecionada = index),
                children: List.generate(24, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            const Text(
              'Horas',
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
        const SizedBox(width: 40),
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _minutoSelecionada),
                onSelectedItemChanged: (index) => setState(() => _minutoSelecionada = index),
                children: List.generate(60, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            const Text(
              'Minutos',
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
      ],
    );
  }

  /// Botão circular central que inicia/desarma o timer de check-in.
  Widget _buildBotaoCheckIn() {
    return GestureDetector(
      onTap: _alternarTimer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isTimerAtivo ? const Color(0xFFE67E22) : const Color(0xFF4C7040),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_isTimerAtivo ? Icons.timer : Icons.check_circle_outline, color: Colors.white, size: 36),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _isTimerAtivo ? _formatarTempo(_segundosRestantes) : 'Fazer\nCheck-in',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: _isTimerAtivo ? 20 : 16, letterSpacing: _isTimerAtivo ? 1.2 : 0),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _isTimerAtivo ? 'Toque: desarmar' : 'Toque para iniciar',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Rodapé decorativo exibido ao final da tela principal.
  Widget _buildRodape() {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.favorite, color: Colors.red, size: 16),
        SizedBox(width: 8),
        Flexible(
          child: Text(
            'Cuidando de você com carinho',
            textAlign: TextAlign.center,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: _estiloRodape,
          ),
        ),
        SizedBox(width: 8),
        Icon(Icons.favorite, color: Colors.red, size: 16),
      ],
    );
  }
}


