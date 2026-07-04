import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:async';
import '../../services/api_service.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';


class SegurancaTab extends StatefulWidget {
  const SegurancaTab({super.key});

  @override
  State<SegurancaTab> createState() => _SegurancaTabState();
}

class _SegurancaTabState extends State<SegurancaTab> {
  final ApiService _api = ApiService();
  final DatabaseHelper _db = DatabaseHelper();

  // Controlador para o campo de Anotações/Dica de Contexto
  final TextEditingController _contextoController = TextEditingController();

  // Variáveis do Banco de Dados
  String? _pinRealConfirmado;
  String? _pinCoacaoConfirmado;
  int _toleranciaRotinaMinutos = 15;
  String _telefoneEmergencia1 = '';
  String _telefoneEmergencia2 = '';

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
          _toleranciaRotinaMinutos = config['tempo_padrao_timer'] as int? ?? 15;
          _telefoneEmergencia1 = config['telefone_emergencia_1'] as String? ?? '';
          _telefoneEmergencia2 = config['telefone_emergencia_2'] as String? ?? '';
        });
      }
    } catch (_) {}
  }

  void _alternarTimer() {
    if (_isTimerAtivo) {
      _pararTimer();
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

  void _verificarPINInserido() {
    if (_pinDigitadoNoBloqueio == _pinRealConfirmado) {
      _pararTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Check-in desarmado com sucesso!'), backgroundColor: Colors.green),
      );
    } else {
      _executarDisparoDeEmergencia();
    }
  }

  Future<void> _executarDisparoDeEmergencia() async {
    _timerToleranciaBloqueio?.cancel();

    String anotacoesUsuario = _contextoController.text.trim();
    if (anotacoesUsuario.isEmpty) {
      anotacoesUsuario = 'Nenhuma anotação de contexto informada pelo usuário.';
    }

    final payloadAlerta = {
      'mensagem': 'ALERTA DE EMERGÊNCIA - O usuário não realizou o check-in de segurança previsto.',
      'telefones': [_telefoneEmergencia1, _telefoneEmergencia2],
      'localizacao': 'Última localização conhecida obtida pelo GPS do aparelho',
      'contexto_usuario': anotacoesUsuario,
    };

    print('🚨 DISPARANDO ALERTA MÁXIMO DE EMERGÊNCIA!');
    print('📋 Dados enviados na cascata: $payloadAlerta');

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
    // Caso o sistema esteja bloqueado aguardando PIN
    if (_estaBloqueadoAguardandoPIN) {
      return Scaffold(
        backgroundColor: const Color(0xFF1A1A1A),
        body: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, color: Colors.redAccent, size: 50),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'SISTEMA BLOQUEADO',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.5),
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
                  style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 32),
              Row(
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
              ),
              const SizedBox(height: 40),
              Expanded(
                child: Container(
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
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Tela de funcionamento normal com plano de fundo dinâmico,
    // sincronizado em tempo real com a escolha feita em Configurações.
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
              Card(
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
              ),
              const SizedBox(height: 24),

              const Text(
                'Daqui quanto tempo vou chegar',
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const SizedBox(height: 16),
              Row(
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
                        style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
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
                        style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 32),

              GestureDetector(
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
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.favorite, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Cuidando de você com carinho',
                      textAlign: TextAlign.center,
                      softWrap: true,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.favorite, color: Colors.red, size: 16),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
          );
        },
      ),
    );
  }
}
