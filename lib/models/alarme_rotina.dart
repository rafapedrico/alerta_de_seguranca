/// Modelo de dados de um Alarme de Rotina, usado pela aba Família no
/// gerenciador de múltiplos alarmes (estilo despertador do iPhone).
class AlarmeRotina {
  final int? id;
  final int hora;
  final int minuto;
  final Set<int> diasSemana;
  final bool ativo;
  final String etiqueta;
  final String contextoPersonalizado;
  final int minutosTolerancia;
  final int? ultimoDisparoEpoch;
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

  /// Converte o conjunto de dias da semana em uma string CSV ordenada (ex: {5, 1, 3} -> "1,3,5").
  static String diasParaCsv(Set<int> dias) {
    final ordenados = dias.toList()..sort();
    return ordenados.join(',');
  }

  /// Converte uma string CSV (ex: "1,3,5") de volta para um Set<int>.
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
        'alarme_pausado': pausado ? '1' : '0',
      };

  factory AlarmeRotina.fromMap(Map<String, dynamic> map) {
    int parseInt(dynamic val, int defaultValue) {
      if (val is int) return val;
      if (val is String) return int.tryParse(val) ?? defaultValue;
      return defaultValue;
    }

    final rawPausa = map['alarme_pausado'];
    bool estaPausado = false;
    if (rawPausa != null && rawPausa != 0 && rawPausa != '0' && rawPausa != false) {
      estaPausado = true;
    }

    return AlarmeRotina(
      id: parseInt(map['id'], 0) == 0 ? null : parseInt(map['id'], 0),
      hora: parseInt(map['hora'], 0),
      minuto: parseInt(map['minuto'], 0),
      diasSemana: diasDeCsv(map['dias_semana'] as String?),
      ativo: map['ativo'] == 1 || map['ativo'] == '1' || map['ativo'] == true,
      etiqueta: map['etiqueta']?.toString() ?? '',
      contextoPersonalizado: map['contexto_personalizado']?.toString() ?? '',
      minutosTolerancia: parseInt(map['minutos_tolerancia'], 10),
      ultimoDisparoEpoch: map['ultimo_disparo_epoch'] != null
          ? parseInt(map['ultimo_disparo_epoch'], 0)
          : null,
      pausado: estaPausado,
    );
  }

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

  /// Retorna uma descrição resumida dos dias da semana selecionados.
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

    if (diasOrdenados.length == 5 &&
        diasOrdenados.every((d) => d >= 1 && d <= 5)) {
      return 'Seg a Sex';
    }

    return diasOrdenados.map((d) => nomesDias[d] ?? '').join(', ');
  }
}