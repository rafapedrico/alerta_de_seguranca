import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../services/wallpaper_service.dart';


/// Aba responsável pela configuração da rotina diária de check-in,
/// no estilo do despertador do iPhone (dias da semana + hora/minuto).
class FamiliaTab extends StatefulWidget {
  const FamiliaTab({super.key});

  @override
  State<FamiliaTab> createState() => _FamiliaTabState();
}

class _FamiliaTabState extends State<FamiliaTab> {
  // Vem ativado por padrão nesta tela
  bool _rotinaAtiva = true;

  // Dias da semana para a opção diária
  final List<String> _diasSemana = [
    'SEGUNDA-FEIRA',
    'TERÇA-FEIRA',
    'QUARTA-FEIRA',
    'QUINTA-FEIRA',
    'SEXTA-FEIRA',
    'SÁBADO',
    'DOMINGO',
  ];

  final Set<String> _diasAtivos = {};

  int _horaRotina = 23;
  int _minutoRotina = 45;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
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
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.people, color: Color(0xFF4C7040), size: 28),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Rotina em Família',
                        textAlign: TextAlign.center,
                        softWrap: true,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const Text(
                  'Definir horário fixo de rotina',
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
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
                          // Iniciais do iPhone: S, T, Q, Q, S, S, D
                          final String inicial = index == 0
                              ? 'S'
                              : index == 1
                                  ? 'T'
                                  : index == 2
                                      ? 'Q'
                                      : index == 3
                                          ? 'Q'
                                          : index == 4
                                              ? 'S'
                                              : index == 5
                                                  ? 'S'
                                                  : 'D';
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
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    inicial,
                                    softWrap: true,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: isSelecionado ? Colors.white : Colors.black54,
                                    ),
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
                              const Text(
                                'Hora',
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: _horaRotina),
                                  onSelectedItemChanged: (index) => setState(() => _horaRotina = index),
                                  children: List.generate(
                                    24,
                                    (index) => Center(
                                      child: Text(
                                        index.toString().padLeft(2, '0'),
                                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Flexible(
                            child: Text(
                              ':',
                              softWrap: true,
                              overflow: TextOverflow.clip,
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey),
                            ),
                          ),
                          Column(
                            children: [
                              const Text(
                                'Minuto',
                                softWrap: true,
                                overflow: TextOverflow.clip,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: _minutoRotina ~/ 5),
                                  onSelectedItemChanged: (index) => setState(() => _minutoRotina = index * 5),
                                  children: List.generate(
                                    12,
                                    (index) => Center(
                                      child: Text(
                                        (index * 5).toString().padLeft(2, '0'),
                                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _rotinaAtiva,
                      activeColor: const Color(0xFF4C7040),
                      onChanged: (value) => setState(() => _rotinaAtiva = value ?? false),
                    ),
                    Flexible(
                      child: Text(
                        'Manter rotina diária ativada',
                        softWrap: true,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black87),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
          );
        },
      ),
    );
  }
}
