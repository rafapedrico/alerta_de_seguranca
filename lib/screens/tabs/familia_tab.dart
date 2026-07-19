import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/rotina_alarme_service.dart';
import '../../services/api_service.dart';
import '../../services/contatos_emergencia_service.dart';
import '../../models/alarme_rotina.dart';

/// Aba responsável pelo gerenciador de múltiplos alarmes de rotina de
/// check-in, no estilo do despertador do iPhone: uma lista de alarmes,
/// cada um com seu próprio horário, dias de repetição e etiqueta, que
/// podem ser ativados/desativados individualmente com um switch.
///
/// Abaixo da lista de alarmes, exibe também (em modo somente leitura) os
/// contatos de emergência que receberão o alerta — reaproveitando
/// EXATAMENTE os mesmos dados cadastrados e centralizados na aba de
/// Configurações (tabela 'contatos_emergencia'), sem duplicar o cadastro.
class FamiliaTab extends StatefulWidget {
  const FamiliaTab({super.key});

  @override
  State<FamiliaTab> createState() => FamiliaTabState();
}

class FamiliaTabState extends State<FamiliaTab> with WidgetsBindingObserver {
  final DatabaseHelper _db = DatabaseHelper();

  bool _carregandoAlarmes = true;
  List<AlarmeRotina> _alarmes = [];

  bool _carregandoContatos = true;
  List<Map<String, dynamic>> _contatosEmergencia = [];
  Map<int, bool> _pausadoHojeMap = {};

  static const List<String> _iniciaisDias = ['S', 'T', 'Q', 'Q', 'S', 'S', 'D'];
  static const List<int> _valoresDias = [1, 2, 3, 4, 5, 6, 7];

  @override
  void initState() {
    super.initState();
    // 🟢 ADICIONE ESTA LINHA:
    WidgetsBinding.instance.addObserver(this);

    // 🟢 MANTENHA ESTAS LINHAS (elas já estão no seu código):
    _carregarAlarmes();
    _carregarContatosEmergencia();
    ContatosEmergenciaService.versaoContatos.addListener(_aoContatosAlterados);
  }

  // 🟢 ADICIONE ESTE MÉTODO COMPLETO (recarrega os cards sempre que você volta pro app):
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _carregarAlarmes();
      _carregarContatosEmergencia();
    }
  }

  @override
  void dispose() {
    // 🟢 ADICIONE ESTA LINHA DENTRO DO DISPOSE:
    WidgetsBinding.instance.removeObserver(this);

    // 🟢 MANTENHA ESTAS LINHAS:
    ContatosEmergenciaService.versaoContatos.removeListener(_aoContatosAlterados);
    super.dispose();
}

  void _aoContatosAlterados() {
    _carregarContatosEmergencia();
  }
  /// Retorna a data de hoje formatada em String (ex: '2026-07-19')
  String _obterDataHojeFormatada() {
    final agora = DateTime.now();
    return '${agora.year}-${agora.month.toString().padLeft(2, '0')}-${agora.day.toString().padLeft(2, '0')}';
  }

  Future<void> _carregarAlarmes() async {
    if (!mounted) return;
    setState(() => _carregandoAlarmes = true);
    try {
      final dados = await _db.listarAlarmes();
      print('DEBUG: Encontrados ${dados.length} alarmes no banco SQLite');

      final alarmesAtualizados = <AlarmeRotina>[];
      final pausadoHojeMap = <int, bool>{};
      final dataHoje = _obterDataHojeFormatada();

      for (var mapa in dados) {
        final alarme = AlarmeRotina.fromMap(mapa);
        if (alarme.id != null) {
          final String estadoPausaNoBanco = mapa['alarme_pausado']?.toString() ?? '0';
          pausadoHojeMap[alarme.id!] = (estadoPausaNoBanco == dataHoje);
        }
        alarmesAtualizados.add(alarme);
      }

      if (mounted) {
        setState(() {
          _alarmes = alarmesAtualizados;
          _pausadoHojeMap = pausadoHojeMap;
          _carregandoAlarmes = false;
        });
      }
    } catch (e) {
      print('DEBUG ERRO ao carregar alarmes: $e');
      if (mounted) setState(() => _carregandoAlarmes = false);
    }
  }

  Future<void> _carregarContatosEmergencia() async {
    if (!mounted) return;
    setState(() => _carregandoContatos = true);
    try {
      await _db.processarExclusoesPendentesExpiradas();
      final contatos = await _db.getContatosEmergencia();
      if (!mounted) return;
      setState(() {
        _contatosEmergencia = contatos;
        _carregandoContatos = false;
      });
    } catch (_) {
      if (mounted) setState(() => _carregandoContatos = false);
    }
  }

  bool _isExclusaoPendente(Map<String, dynamic> contato) {
    final valor = contato['exclusao_pendente'];
    return valor == 1 || valor == true;
  }

  Future<void> _alternarAtivo(AlarmeRotina alarme, bool ativo) async {
    if (alarme.id == null) return;
    await _db.alternarAtivoAlarme(alarme.id!, ativo);

    if (ativo) {
      final atualizado = await _db.buscarAlarmePorId(alarme.id!);
      if (atualizado != null) {
        await RotinaAlarmeService.agendarAlarme(atualizado);
      }
    } else {
      await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    }

    await _db.inserirEventoHistorico(
      titulo: ativo ? 'Alarme de rotina ativado' : 'Alarme de rotina desativado',
      descricao:
          '${alarme.etiqueta.isNotEmpty ? alarme.etiqueta : 'Alarme'} '
          '(${alarme.horarioFormatado}) foi ${ativo ? 'ativado' : 'desativado'}.',
      categoria: 'familia',
    );

    ApiService().salvarRotina(
      alarmeId: alarme.id,
      horario: '${alarme.hora.toString().padLeft(2, '0')}:'
          '${alarme.minuto.toString().padLeft(2, '0')}:00',
      toleranciaMinutos: alarme.minutosTolerancia,
      etiqueta: alarme.etiqueta,
      contextoPersonalizado: alarme.contextoPersonalizado,
      diasSemana: alarme.diasSemana.map((d) => d.toString()).toList(),
      ativo: ativo,
    );

    await _carregarAlarmes();
  }

  Future<void> _excluirAlarme(AlarmeRotina alarme) async {
    if (alarme.id == null) return;

    await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    await _db.deletarAlarme(alarme.id!);

    await _db.inserirEventoHistorico(
      titulo: 'Alarme de rotina removido',
      descricao:
          '${alarme.etiqueta.isNotEmpty ? alarme.etiqueta : 'Alarme'} '
          '(${alarme.horarioFormatado}) foi removido.',
      categoria: 'familia',
    );

    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🗑️ Alarme removido com sucesso.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pausarAlarmePorHoje(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    final dataHoje = _obterDataHojeFormatada();

    final dbInstancia = await _db.database;
    await dbInstancia.update(
      'alarmes_rotina',
      {'alarme_pausado': dataHoje},
      where: 'id = ?',
      whereArgs: [alarme.id],
    );

    await _db.inserirEventoHistorico(
      titulo: 'Alarme de rotina pausado',
      descricao:
          '${alarme.etiqueta.isNotEmpty ? alarme.etiqueta : 'Alarme'} (${alarme.horarioFormatado}) foi pausado até as 00:00.',
      categoria: 'familia',
    );

    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⏸️ Alarme pausado até as 00:00 de hoje.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _despausarAlarmeManual(AlarmeRotina alarme) async {
    if (alarme.id == null) return;

    final dbInstancia = await _db.database;
    await dbInstancia.update(
      'alarmes_rotina',
      {'alarme_pausado': '0'},
      where: 'id = ?',
      whereArgs: [alarme.id],
    );

    await _db.inserirEventoHistorico(
      titulo: 'Alarme de rotina reativado',
      descricao:
          '${alarme.etiqueta.isNotEmpty ? alarme.etiqueta : 'Alarme'} (${alarme.horarioFormatado}) foi reativado pelo usuário.',
      categoria: 'familia',
    );

    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('▶️ Alarme reativado com sucesso.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void abrirModalAdicionarAlarme() {
    _abrirModalAlarme();
  }

  Future<void> _sincronizarRotinaComBackend(AlarmeRotina alarme) async {
    try {
      await ApiService().salvarRotina(
        alarmeId: alarme.id,
        horario: '${alarme.hora.toString().padLeft(2, '0')}:${alarme.minuto.toString().padLeft(2, '0')}:00',
        toleranciaMinutos: alarme.minutosTolerancia,
        etiqueta: alarme.etiqueta,
        contextoPersonalizado: alarme.contextoPersonalizado,
        diasSemana: alarme.diasSemana.map((d) => d.toString()).toList(),
        ativo: alarme.ativo,
      );
    } catch (e) {
      print('⚠️ Backend offline ($e). Alarme mantido normalmente no SQLite.');
    }
  }

  Future<void> _abrirModalAlarme({AlarmeRotina? alarmeExistente}) async {
    int horaSelecionada = alarmeExistente?.hora ?? TimeOfDay.now().hour;
    int minutoSelecionado = alarmeExistente?.minuto ?? 0;
    final Set<int> diasSelecionados = Set<int>.from(alarmeExistente?.diasSemana ?? {});
    final etiquetaController = TextEditingController(text: alarmeExistente?.etiqueta ?? '');
    final contextoController =
        TextEditingController(text: alarmeExistente?.contextoPersonalizado ?? '');
    int minutosTolerancia = alarmeExistente?.minutosTolerancia ?? 10;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.alarm_add, color: Color(0xFF4C7040)),
                          const SizedBox(width: 8),
                          Text(
                            alarmeExistente == null ? 'Adicionar Alarme' : 'Editar Alarme',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            children: [
                              const Text(
                                'Hora',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: horaSelecionada),
                                  onSelectedItemChanged: (index) => setModalState(() => horaSelecionada = index),
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
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey),
                            ),
                          ),
                          Column(
                            children: [
                              const Text(
                                'Minuto',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: minutoSelecionado),
                                  onSelectedItemChanged: (index) => setModalState(() => minutoSelecionado = index),
                                  children: List.generate(
                                    60,
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
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Repetir',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List.generate(_iniciaisDias.length, (index) {
                          final valorDia = _valoresDias[index];
                          final selecionado = diasSelecionados.contains(valorDia);
                          return GestureDetector(
                            onTap: () {
                              setModalState(() {
                                if (selecionado) {
                                  diasSelecionados.remove(valorDia);
                                } else {
                                  diasSelecionados.add(valorDia);
                                }
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selecionado ? const Color(0xFF4C7040) : Colors.grey.shade200,
                              ),
                              child: Center(
                                child: Text(
                                  _iniciaisDias[index],
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: selecionado ? Colors.white : Colors.black54,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: etiquetaController,
                        decoration: InputDecoration(
                          labelText: 'Etiqueta',
                          hintText: 'Ex: Chegada no trabalho de moto',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.label_outline),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: contextoController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'Dica de contexto (opcional)',
                          hintText: 'Ex: Indo de moto para o trabalho',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.edit_note),
                          helperText:
                              'Usada na mensagem de SMS caso o check-in não seja confirmado a tempo.',
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, color: Colors.grey, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Tolerância para confirmar "Cheguei bem"',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                          DropdownButton<int>(
                            value: minutosTolerancia,
                            items: const [5, 10, 15, 20, 30, 45, 60]
                                .map((minutos) => DropdownMenuItem(
                                      value: minutos,
                                      child: Text('$minutos min'),
                                    ))
                                .toList(),
                            onChanged: (valor) {
                              if (valor == null) return;
                              setModalState(() => minutosTolerancia = valor);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF4C7040),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            final etiqueta = etiquetaController.text.trim();
                            final contexto = contextoController.text.trim();

                            final alarme = AlarmeRotina(
                              id: alarmeExistente?.id,
                              hora: horaSelecionada,
                              minuto: minutoSelecionado,
                              diasSemana: diasSelecionados,
                              ativo: alarmeExistente?.ativo ?? true,
                              etiqueta: etiqueta.isNotEmpty ? etiqueta : 'Alarme de rotina',
                              contextoPersonalizado: contexto,
                              minutosTolerancia: minutosTolerancia,
                            );

                            int idSalvo;
                            if (alarmeExistente == null) {
                              idSalvo = await _db.inserirAlarme(alarme.toMap());
                              await _db.inserirEventoHistorico(
                                titulo: 'Alarme de rotina criado',
                                descricao:
                                    '${alarme.etiqueta} às ${alarme.horarioFormatado} '
                                    '(${alarme.diasResumidos}).',
                                categoria: 'familia',
                              );
                            } else {
                              idSalvo = alarmeExistente.id!;
                              await _db.atualizarAlarme(alarme.toMap());
                              await _db.inserirEventoHistorico(
                                titulo: 'Alarme de rotina editado',
                                descricao:
                                    '${alarme.etiqueta} às ${alarme.horarioFormatado} '
                                    '(${alarme.diasResumidos}).',
                                categoria: 'familia',
                              );
                            }

                            if (alarme.ativo) {
                              final dadosSalvos = await _db.buscarAlarmePorId(idSalvo);
                              if (dadosSalvos != null) {
                                await RotinaAlarmeService.agendarAlarme(dadosSalvos);
                              }
                            } else {
                              await RotinaAlarmeService.cancelarAlarme(idSalvo);
                            }

                            _sincronizarRotinaComBackend(alarme.copyWith(id: idSalvo));

                            if (ctx.mounted) Navigator.of(ctx).pop();
                            await _carregarAlarmes();
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.check, color: Colors.white),
                          label: const Text(
                            'Salvar Alarme',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

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
              child: RefreshIndicator(
                onRefresh: () async {
                  await _carregarAlarmes();
                  await _carregarContatosEmergencia();
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.alarm, color: Color(0xFF4C7040), size: 28),
                        const SizedBox(width: 8),
                        const Flexible(
                          child: Text(
                            'Alarmes de Rotina',
                            textAlign: TextAlign.center,
                            softWrap: true,
                            overflow: TextOverflow.clip,
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _construirListaAlarmes(),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    _construirCardContatosEmergencia(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _construirListaAlarmes() {
    if (_carregandoAlarmes) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_alarmes.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            Icon(Icons.alarm_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              'Nenhum alarme de rotina cadastrado.\nToque no "+" para adicionar o primeiro.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return Column(
      children: _alarmes.map((alarme) {
        final bool estaPausadoHoje = _pausadoHojeMap[alarme.id] ?? false;

        return Dismissible(
          key: ValueKey('alarme_dismiss_${alarme.id}'),
          direction: DismissDirection.horizontal,
          background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.pause_circle_filled, color: Colors.white),
                SizedBox(width: 8),
                Text('Pausar por hoje', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.red.shade600,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('Excluir permanente', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(width: 8),
                Icon(Icons.delete, color: Colors.white),
              ],
            ),
          ),
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.endToStart) {
              return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Excluir alarme permanentemente?'),
                      content: Text('Deseja excluir o alarme "${alarme.etiqueta}" (${alarme.horarioFormatado}) permanentemente?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
                        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Excluir')),
                      ],
                    ),
                  ) ?? false;
            } else if (direction == DismissDirection.startToEnd) {
              return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Pausar alarme por hoje?'),
                      content: Text('Deseja pausar o alarme "${alarme.etiqueta}" (${alarme.horarioFormatado}) até as 00:00? Ele retornará à ativa amanhã automaticamente.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
                        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.blue), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Pausar')),
                      ],
                    ),
                  ) ?? false;
            }
            return false;
          },
          onDismissed: (direction) async {
            if (direction == DismissDirection.endToStart) {
              await _excluirAlarme(alarme);
            } else if (direction == DismissDirection.startToEnd) {
              await _pausarAlarmePorHoje(alarme);
            }
          },
          child: Card(
            elevation: 0,
            color: estaPausadoHoje ? Colors.amber.shade50.withOpacity(0.9) : Colors.white.withOpacity(0.92),
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: estaPausadoHoje ? Colors.amber.shade300 : Colors.grey.shade200, width: estaPausadoHoje ? 1.5 : 1),
            ),
            child: GestureDetector(
              onLongPress: () => _abrirModalAlarme(alarmeExistente: alarme),
              child: SwitchListTile(
                activeColor: const Color(0xFF4C7040),
                onChanged: (ativo) => _alternarAtivo(alarme, ativo),
                value: alarme.ativo,
                title: estaPausadoHoje
                    ? Row(
                        children: [
                          Icon(Icons.pause_circle_filled, color: Colors.amber.shade800, size: 22),
                          const SizedBox(width: 6),
                          Text(
                            'Pausado até 00:00',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amber.shade800),
                          ),
                        ],
                      )
                    : Text(
                        alarme.horarioFormatado,
                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: alarme.ativo ? Colors.black87 : Colors.grey),
                      ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alarme.etiqueta,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: alarme.ativo ? Colors.black87 : Colors.grey),
                    ),
                    Text(
                      alarme.diasResumidos,
                      style: TextStyle(fontSize: 12, color: alarme.ativo ? Colors.grey.shade700 : Colors.grey.shade400),
                    ),
                    if (estaPausadoHoje)
                      GestureDetector(
                        onTap: () => _despausarAlarmeManual(alarme),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(Icons.play_circle_outline, size: 16, color: Colors.green.shade700),
                              const SizedBox(width: 4),
                              Text(
                                'Toque para reativar agora',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.green.shade700),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _construirCardContatosEmergencia() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.contact_emergency, color: Color(0xFF4C7040)),
              const SizedBox(width: 8),
              const Flexible(
                child: Text(
                  'Contatos de Emergência',
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Estes contatos recebem os alertas de emergência. Gerencie-os na aba Configurações.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          if (_carregandoContatos)
            const Center(child: CircularProgressIndicator())
          else if (_contatosEmergencia.isEmpty)
            Text(
              'Nenhum contato de emergência cadastrado ainda.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            )
          else
            Column(
              children: _contatosEmergencia.map((contato) {
                final nome = contato['nome'] as String? ?? 'Sem nome';
                final telefone = contato['telefone'] as String? ?? '';
                final pendente = _isExclusaoPendente(contato);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFFE8F5E9),
                        child: Text(
                          nome.isNotEmpty ? nome[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Color(0xFF4C7040),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              nome,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            Text(
                              pendente ? 'Removendo em 24h...' : telefone,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: pendente ? Colors.orange.shade800 : Colors.black54,
                                fontWeight: pendente ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (pendente)
                        const Icon(Icons.hourglass_bottom, color: Colors.orange, size: 18),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}