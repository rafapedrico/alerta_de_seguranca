import 'package:security_check_app/l10n/app_localizations.dart';

/// Modelo de dados de um Alarme de Rotina, usado pela aba Família no
/// gerenciador de múltiplos alarmes (estilo despertador do iPhone).
class AlarmeRotina {
  /// Chave neutra (independente de idioma) persistida no campo
  /// [etiqueta] quando o usuário deixa o rótulo em branco ao
  /// criar/editar um alarme — em vez de gravar o texto JÁ TRADUZIDO no
  /// idioma do momento (bug real observado: agendamentos antigos
  /// ficavam presos para sempre no idioma em que foram criados, mesmo
  /// depois de trocar o idioma do app nas Configurações). Resolvida
  /// dinamicamente em [etiquetaExibida] — nunca deve aparecer
  /// diretamente na UI.
  static const String chaveEtiquetaPadrao = 'KEY_ALARME_ROTINA';

  /// Traduções LEGADAS de "Alarme de rotina" (uma por idioma suportado)
  /// que podem já estar gravadas em [etiqueta] para alarmes criados
  /// ANTES desta correção — tratadas como equivalentes a
  /// [chaveEtiquetaPadrao] em [etiquetaExibida], para que agendamentos
  /// antigos também passem a traduzir corretamente ao trocar de idioma,
  /// e não só os criados dali em diante.
  static const Set<String> _etiquetasPadraoLegadas = {
    'Alarme de rotina', // pt
    'Routine alarm', // en
    'Alarma de rutina', // es
    'Alarme de routine', // fr
    'Routinealarm', // de
    'Allarme di routine', // it
    '定期アラーム', // ja
    '常规闹钟', // zh
    'Плановый будильник', // ru
    'منبه روتيني', // ar
    'नियमित अलार्म', // hi
  };

  final int? id;
  final int hora;
  final int minuto;
  final Set<int> diasSemana;
  final bool ativo;
  final String etiqueta;
  final String contextoPersonalizado;
  final int minutosTolerancia;
  final int? ultimoDisparoEpoch;

  /// Dia da pausa (`yyyy-MM-dd`) — a pausa vale só até 00h00 do dia
  /// seguinte. Gravado como está ao editar (editar NUNCA despausa).
  final String? pausadoEm;

  /// Pausado AGORA (pausa de hoje, até 00h00).
  bool get pausado => pausadoEm != null && pausadoEm == dataIso(DateTime.now());

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
    this.pausadoEm,
  });

  /// `yyyy-MM-dd` de [data] (formato da coluna `alarme_pausado`).
  static String dataIso(DateTime data) =>
      '${data.year.toString().padLeft(4, '0')}-${data.month.toString().padLeft(2, '0')}-'
      '${data.day.toString().padLeft(2, '0')}';

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
        'alarme_pausado': pausadoEm ?? '0',
      };

  factory AlarmeRotina.fromMap(Map<String, dynamic> map) {
    int parseInt(dynamic val, int defaultValue) {
      if (val is int) return val;
      if (val is String) return int.tryParse(val) ?? defaultValue;
      return defaultValue;
    }

    // Só uma data é pausa (até 00h00). Valores antigos ('1' = pausa sem
    // fim, da ação sem PIN da notificação, removida) não pausam mais.
    final rawPausa = map['alarme_pausado']?.toString();
    final pausadoEm =
        rawPausa != null && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(rawPausa) ? rawPausa : null;

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
      pausadoEm: pausadoEm,
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
    String? pausadoEm,
    bool limparPausa = false,
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
      pausadoEm: limparPausa ? null : (pausadoEm ?? this.pausadoEm),
    );
  }

  /// Retorna o horário formatado no padrão "HH:mm".
  String get horarioFormatado =>
      '${hora.toString().padLeft(2, '0')}:${minuto.toString().padLeft(2, '0')}';

  /// `true` quando [etiqueta] é a chave neutra padrão ([chaveEtiquetaPadrao]),
  /// uma das traduções legadas ([_etiquetasPadraoLegadas]) ou está
  /// simplesmente vazia — em todos esses casos o rótulo exibido deve ser
  /// resolvido dinamicamente via [etiquetaExibida], nunca o valor bruto
  /// de [etiqueta] (que pode não estar no idioma atual do app).
  bool get temEtiquetaPadrao =>
      etiqueta.isEmpty ||
      etiqueta == chaveEtiquetaPadrao ||
      _etiquetasPadraoLegadas.contains(etiqueta);

  /// Rótulo do alarme pronto para exibição: resolve a chave neutra (ou
  /// uma tradução legada já gravada no banco) para o texto traduzido no
  /// idioma ATUAL do app — nunca lê diretamente um texto já traduzido
  /// persistido no banco. Use esta função em toda a UI (listagem, pausa,
  /// exclusão, histórico) em vez de ler [etiqueta] diretamente.
  String etiquetaExibida(AppLocalizations l10n) =>
      temEtiquetaPadrao ? l10n.familiaEtiquetaPadrao : etiqueta;

  /// Retorna uma descrição resumida dos dias da semana selecionados, no
  /// idioma ativo do app — chaves dinâmicas de [AppLocalizations], nunca
  /// hardcoded, para que o rótulo/frequência do card de alarme (aba
  /// Família) apareça corretamente traduzido nos 11 idiomas suportados.
  String diasResumidos(AppLocalizations l10n) {
    if (diasSemana.isEmpty) return l10n.familiaDiasNuncaLabel;
    if (diasSemana.length == 7) return l10n.familiaDiasTodosLabel;

    final nomesDias = {
      1: l10n.familiaDiaAbrevSeg,
      2: l10n.familiaDiaAbrevTer,
      3: l10n.familiaDiaAbrevQua,
      4: l10n.familiaDiaAbrevQui,
      5: l10n.familiaDiaAbrevSex,
      6: l10n.familiaDiaAbrevSab,
      7: l10n.familiaDiaAbrevDom,
    };

    final diasOrdenados = diasSemana.toList()..sort();

    if (diasOrdenados.length == 5 &&
        diasOrdenados.every((d) => d >= 1 && d <= 5)) {
      return l10n.familiaDiasSegASexLabel;
    }

    return diasOrdenados.map((d) => nomesDias[d] ?? '').join(', ');
  }
}