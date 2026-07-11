/// Modelo de dados de um Alarme de Rotina, usado pela aba Família no
/// gerenciador de múltiplos alarmes (estilo despertador do iPhone).
///
/// Cada alarme representa um horário de check-in de rotina que pode se
/// repetir em um ou mais dias da semana (ex: "Chegada no trabalho de
/// moto" às 08:00, repetindo Segunda a Sexta).
///
/// Os dias da semana são representados como um [Set<int>] onde:
/// 1 = Segunda-feira, 2 = Terça-feira, 3 = Quarta-feira, 4 = Quinta-feira,
/// 5 = Sexta-feira, 6 = Sábado, 7 = Domingo.
/// Esses valores são persistidos no SQLite como uma string CSV (ex:
/// "1,3,5") na coluna 'dias_semana'.
class AlarmeRotina {
  final int? id;
  final int hora;
  final int minuto;
  final Set<int> diasSemana;
  final bool ativo;
  final String etiqueta;

  /// Dica de contexto PRÓPRIA deste alarme de rotina (ex: "Indo de moto
  /// para o trabalho"), usada para montar a mensagem de SMS de
  /// emergência caso o check-in de rotina não seja confirmado a tempo.
  /// Independente do campo de contexto do check-in manual (SegurancaTab).
  final String contextoPersonalizado;

  /// Tempo de tolerância (em minutos) que o usuário tem, após a
  /// notificação de check-in de rotina ser exibida, para confirmar
  /// "Cheguei bem" antes do disparo automático de emergência.
  final int minutosTolerancia;

  /// Timestamp (epoch ms) do último disparo NATIVO já processado para
  /// este alarme, usado internamente pelo RotinaAlarmeService para
  /// evitar reagendamentos duplicados. Não editável pela UI.
  final int? ultimoDisparoEpoch;

  /// Indica se o usuário pausou este alarme específico através do
  /// botão "Pausar Alarme" exibido no `pin_dialog.dart` quando o
  /// check-in de rotina dispara. Enquanto `true`, os disparos deste
  /// alarme são ignorados (ver `_callbackCheckinRotina` em
  /// `rotina_alarme_service.dart`), e a aba Família exibe o texto
  /// "Alarme Pausado" no lugar do horário. É resetado para `false`
  /// (despausado) quando o usuário toca em "Toque para reativar".
  final bool pausado;

  AlarmeRotina({
    this.id,
    required this.hora,
    required this.minuto,
    required this.diasSemana,
    this.ativo = true,
    this.etiqueta = '',
    this.contextoPersonalizado = '',
    this.minutosTolerancia = 10,
    this.ultimoDisparoEpoch,
    this.pausado = false,
  });



  /// Converte o conjunto de dias da semana em uma string CSV ordenada
  /// (ex: {5, 1, 3} -> "1,3,5"), pronta para ser persistida no SQLite.
  static String diasParaCsv(Set<int> dias) {
    final ordenados = dias.toList()..sort();
    return ordenados.join(',');
  }

  /// Converte uma string CSV (ex: "1,3,5") de volta para um Set<int>.
  /// Retorna um conjunto vazio caso a string esteja vazia ou nula.
  static Set<int> diasDeCsv(String? csv) {
    if (csv == null || csv.trim().isEmpty) return {};
    return csv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'hora': hora,
        'minuto': minuto,
        'dias_semana': diasParaCsv(diasSemana),
        'ativo': ativo ? 1 : 0,
        'etiqueta': etiqueta,
        'contexto_personalizado': contextoPersonalizado,
        'minutos_tolerancia': minutosTolerancia,
        'ultimo_disparo_epoch': ultimoDisparoEpoch,
      };

  factory AlarmeRotina.fromMap(Map<String, dynamic> map) => AlarmeRotina(
        id: map['id'] as int?,
        hora: map['hora'] as int? ?? 0,
        minuto: map['minuto'] as int? ?? 0,
        diasSemana: diasDeCsv(map['dias_semana'] as String?),
        ativo: (map['ativo'] as int?) == 1,
        etiqueta: map['etiqueta'] as String? ?? '',
        contextoPersonalizado: map['contexto_personalizado'] as String? ?? '',
        minutosTolerancia: map['minutos_tolerancia'] as int? ?? 10,
        ultimoDisparoEpoch: map['ultimo_disparo_epoch'] as int?,
        pausado: (map['alarme_pausado'] as int?) == 1,
      );

  AlarmeRotina copyWith({
    int? id,
    int? hora,
    int? minuto,
    Set<int>? diasSemana,
    bool? ativo,
    String? etiqueta,
    String? contextoPersonalizado,
    int? minutosTolerancia,
    int? ultimoDisparoEpoch,
    bool? pausado,
  }) {
    return AlarmeRotina(
      id: id ?? this.id,
      hora: hora ?? this.hora,
      minuto: minuto ?? this.minuto,
      diasSemana: diasSemana ?? this.diasSemana,
      ativo: ativo ?? this.ativo,
      etiqueta: etiqueta ?? this.etiqueta,
      contextoPersonalizado: contextoPersonalizado ?? this.contextoPersonalizado,
      minutosTolerancia: minutosTolerancia ?? this.minutosTolerancia,
      ultimoDisparoEpoch: ultimoDisparoEpoch ?? this.ultimoDisparoEpoch,
      pausado: pausado ?? this.pausado,
    );
  }



  /// Retorna o horário formatado no padrão "HH:mm".
  String get horarioFormatado =>
      '${hora.toString().padLeft(2, '0')}:${minuto.toString().padLeft(2, '0')}';

  /// Retorna uma descrição resumida dos dias da semana selecionados,
  /// no estilo "Seg, Qua, Sex", "Todos os dias" (7 dias) ou "Nunca"
  /// (nenhum dia selecionado, alarme disparado apenas uma vez/manual).
  String get diasResumidos {
    if (diasSemana.isEmpty) return 'Nunca';
    if (diasSemana.length == 7) return 'Todos os dias';

    const nomesDias = {
      1: 'Seg',
      2: 'Ter',
      3: 'Qua',
      4: 'Qui',
      5: 'Sex',
      6: 'Sáb',
      7: 'Dom',
    };

    final diasOrdenados = diasSemana.toList()..sort();

    // Caso especial comum: Segunda a Sexta.
    if (diasOrdenados.length == 5 &&
        diasOrdenados.every((d) => d >= 1 && d <= 5)) {
      return 'Seg a Sex';
    }

    return diasOrdenados.map((d) => nomesDias[d] ?? '').join(', ');
  }
}
