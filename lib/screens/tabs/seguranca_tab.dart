import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:async';
import '../../services/api_service.dart';
import '../../services/database_helper.dart';

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
  bool _manterHorarioDiario = false;
  
  // Variáveis de controle do Timer Ativo
  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  // Estado de Bloqueio por PIN
  bool _estaBloqueadoAguardandoPIN = false;
  Timer? _timerToleranciaBloqueio;
  int _segundosToleranciaBloqueio = 60; 
  String _pinDigitadoNoBloqueio = '';

  // Dias da semana para a opção diária
  final List<String> _diasSemana = [
    'SEGUNDA-FEIRA', 'TERÇA-FEIRA', 'QUARTA-FEIRA', 'QUINTA-FEIRA', 'SEXTA-FEIRA', 'SÁBADO', 'DOMINGO'
  ];

  final Set<String> _diasAtivos = {}; 
  int _horaRotina = 23;
  int _minutoRotina = 45;

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
    int totalSegundos = 0;

    if (_manterHorarioDiario) {
      final agora = DateTime.now();
      var dataAlvo = DateTime(agora.year, agora.month, agora.day, _horaRotina, _minutoRotina);
      
      if (dataAlvo.isBefore(agora)) {
        dataAlvo = dataAlvo.add(const Duration(days: 1));
      }
      dataAlvo = dataAlvo.add(Duration(minutes: _toleranciaRotinaMinutos));
      totalSegundos = dataAlvo.difference(agora).inSeconds;
    } else {
      totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);
    }

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
              const Text(
                'SISTEMA BLOQUEADO',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                'Tempo de tolerância: ${_segundosToleranciaBloqueio}s',
                style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.w500),
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

    // Tela de funcionamento normal com plano de fundo
    final theme = Theme.of(context);
    const String fundoAtivo = 'light';

    return Scaffold(
      backgroundColor: Colors.transparent, // Permite que o fundo do Container apareça
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/$fundoAtivo.png'),
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

              if (!_manterHorarioDiario) ...[
                const Text('Daqui quanto tempo vou chegar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
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
                        const Text('Horas', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
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
                        const Text('Minutos', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ],
                ),
              ],

 if (_manterHorarioDiario) ...[
                const Text('Definir horário fixo de rotina', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey.shade100),
                  ),
                  child: Column(
                    children: [
                      // Fileira de dias estilo Bolinhas do iPhone
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: List.generate(_diasSemana.length, (index) {
                          final diaCompleto = _diasSemana[index];
                          // Iniciais do iPhone: D, S, T, Q, Q, S, S
                          final String inicial = index == 0 ? 'S' : index == 1 ? 'T' : index == 2 ? 'Q' : index == 3 ? 'Q' : index == 4 ? 'S' : index == 5 ? 'S' : 'D';
                          final isSelecionado = _diasAtivos.contains(diaCompleto);

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                if (isSelecionado) {
                                  _diasAtivos.remove(diaCompleto);
                                } else {
                                  _diasAtivos.add(diaCompleto);
                                }
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelecionado ? const Color(0xFF4C7040) : Colors.grey.shade100,
                              ),
                              child: Center(
                                child: Text(
                                  inicial,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: isSelecionado ? Colors.white : Colors.black54,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      
                      // Seletores de Hora e Minuto Lado a Lado
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            children: [
                              const Text('Hora', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: _horaRotina),
                                  onSelectedItemChanged: (index) => _horaRotina = index,
                                  children: List.generate(24, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))),
                                ),
                              ),
                            ],
                          ),
                          const Text(':', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey)),
                          Column(
                            children: [
                              const Text('Minuto', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: _minutoRotina ~/ 5),
                                  onSelectedItemChanged: (index) => _minutoRotina = index * 5,
                                  children: List.generate(12, (index) => Center(child: Text((index * 5).toString().padLeft(2, '0'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Checkbox(
                    value: _manterHorarioDiario,
                    activeColor: const Color(0xFF4C7040),
                    onChanged: _isTimerAtivo ? null : (value) => setState(() => _manterHorarioDiario = value ?? false),
                  ),
                  Text('Prefiro manter um horário diário', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _isTimerAtivo ? Colors.grey : Colors.black87)),
                ],
              ),

              const SizedBox(height: 24),

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
                      Text(
                        _isTimerAtivo ? _formatarTempo(_segundosRestantes) : 'Fazer\nCheck-in',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: _isTimerAtivo ? 20 : 16, letterSpacing: _isTimerAtivo ? 1.2 : 0),
                      ),
                      const SizedBox(height: 6),
                      Text(_isTimerAtivo ? 'Toque: desarmar' : 'Toque para iniciar', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.favorite, color: Colors.red, size: 16),
                  SizedBox(width: 8),
                  Text('Cuidando de você com carinho', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey, fontStyle: FontStyle.italic)),
                  SizedBox(width: 8),
                  Icon(Icons.favorite, color: Colors.red, size: 16),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}