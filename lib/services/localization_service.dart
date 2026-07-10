import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// ==========================================================
/// ETAPA 2 - INTERNACIONALIZAÇÃO (i18n)
/// ==========================================================
/// Estrutura de mapeamento para os 11 idiomas globais estratégicos da
/// expansão mundial do app, com foco no público de motociclistas e nos
/// maiores polos de duas rodas do planeta (Ásia, Europa, Américas e
/// Oriente Médio).
///
/// Este serviço NÃO substitui o Flutter `intl`/`flutter_localizations`
/// definitivo (que deve ser adotado numa etapa futura, com arquivos
/// `.arb` completos para cada idioma) — ele apenas MAPEIA/PREPARA a
/// estrutura de suporte multi-idioma, permitindo que:
/// 1) O usuário já possa escolher seu idioma preferido em Configurações;
/// 2) A escolha seja persistida (SharedPreferences) e sobreviva a
///    reinícios do app;
/// 3) O restante do código-base já tenha um ponto único e centralizado
///    para consultar "qual idioma está ativo" e obter o nome nativo de
///    cada idioma suportado, facilitando a tradução completa da UI numa
///    etapa posterior.
class IdiomaApp {
  final String codigo; // Código ISO 639-1 (ou variante regional)
  final String nomeEmPortugues; // Nome do idioma, em português
  final String nomeNativo; // Nome do idioma, em sua própria língua
  final String bandeiraEmoji; // Emoji de bandeira representativo

  const IdiomaApp({
    required this.codigo,
    required this.nomeEmPortugues,
    required this.nomeNativo,
    required this.bandeiraEmoji,
  });
}

class LocalizationService {
  LocalizationService._internal();
  static final LocalizationService _instance = LocalizationService._internal();
  factory LocalizationService() => _instance;

  static const String _prefsKeyIdioma = 'idioma_selecionado';

  /// Idioma padrão do app: Português (Brasil), mercado de origem.
  static const String idiomaPadrao = 'pt';

  /// ==========================================================
  /// OS 11 IDIOMAS GLOBAIS ESTRATÉGICOS
  /// ==========================================================
  /// Selecionados para cobrir os maiores polos mundiais de
  /// motociclistas/duas rodas:
  /// - Português: Brasil (maior frota de motos da América Latina).
  /// - Inglês: mercado global/EUA/Índia/Filipinas (língua franca).
  /// - Espanhol: América Latina hispânica + Espanha.
  /// - Francês: França + África Ocidental francófona.
  /// - Alemão: Alemanha/Áustria/Suíça (mercado europeu premium).
  /// - Italiano: Itália (berço das motos esportivas).
  /// - Chinês (simplificado): China, maior mercado de duas rodas do mundo.
  /// - Árabe: Oriente Médio e Norte da África.
  /// - Russo: Rússia e Leste Europeu/CEI.
  /// - Hindi: Índia, o maior mercado de motocicletas do planeta.
  /// - Japonês: Japão, polo histórico da indústria de motos.
  static final List<IdiomaApp> idiomasSuportados = [
    const IdiomaApp(
      codigo: 'pt',
      nomeEmPortugues: 'Português',
      nomeNativo: 'Português',
      bandeiraEmoji: '🇧🇷',
    ),
    const IdiomaApp(
      codigo: 'en',
      nomeEmPortugues: 'Inglês',
      nomeNativo: 'English',
      bandeiraEmoji: '🇺🇸',
    ),
    const IdiomaApp(
      codigo: 'es',
      nomeEmPortugues: 'Espanhol',
      nomeNativo: 'Español',
      bandeiraEmoji: '🇪🇸',
    ),
    const IdiomaApp(
      codigo: 'fr',
      nomeEmPortugues: 'Francês',
      nomeNativo: 'Français',
      bandeiraEmoji: '🇫🇷',
    ),
    const IdiomaApp(
      codigo: 'de',
      nomeEmPortugues: 'Alemão',
      nomeNativo: 'Deutsch',
      bandeiraEmoji: '🇩🇪',
    ),
    const IdiomaApp(
      codigo: 'it',
      nomeEmPortugues: 'Italiano',
      nomeNativo: 'Italiano',
      bandeiraEmoji: '🇮🇹',
    ),
    const IdiomaApp(
      codigo: 'zh',
      nomeEmPortugues: 'Chinês',
      nomeNativo: '中文',
      bandeiraEmoji: '🇨🇳',
    ),
    const IdiomaApp(
      codigo: 'ar',
      nomeEmPortugues: 'Árabe',
      nomeNativo: 'العربية',
      bandeiraEmoji: '🇸🇦',
    ),
    const IdiomaApp(
      codigo: 'ru',
      nomeEmPortugues: 'Russo',
      nomeNativo: 'Русский',
      bandeiraEmoji: '🇷🇺',
    ),
    const IdiomaApp(
      codigo: 'hi',
      nomeEmPortugues: 'Hindi (Indiano)',
      nomeNativo: 'हिन्दी',
      bandeiraEmoji: '🇮🇳',
    ),
    const IdiomaApp(
      codigo: 'ja',
      nomeEmPortugues: 'Japonês',
      nomeNativo: '日本語',
      bandeiraEmoji: '🇯🇵',
    ),
  ];

  /// Retorna o [IdiomaApp] correspondente ao código informado, ou o
  /// idioma padrão (Português) caso o código seja inválido/desconhecido.
  IdiomaApp idiomaPorCodigo(String codigo) {
    return idiomasSuportados.firstWhere(
      (i) => i.codigo == codigo,
      orElse: () => idiomasSuportados.first,
    );
  }

  /// Salva o código do idioma escolhido pelo usuário em SharedPreferences.
  Future<void> salvarIdioma(String codigo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyIdioma, codigo);
    debugPrint('🌐 [LocalizationService] Idioma alterado para: $codigo');
  }

  /// Recupera o código do idioma atualmente selecionado, ou
  /// [idiomaPadrao] (Português) caso nunca tenha sido configurado.
  Future<String> carregarIdioma() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKeyIdioma) ?? idiomaPadrao;
  }
}

/// ==========================================================
/// MAPA CENTRALIZADO DE STRINGS TRADUZÍVEIS (placeholder i18n)
/// ==========================================================
/// Estrutura preparatória simples para centralizar, no futuro, TODAS as
/// strings de texto fixo exibidas na UI (hoje ainda hardcoded em
/// português espalhadas pelos widgets). Por enquanto contém apenas as
/// chaves e o valor em português (idioma de origem) — a tradução
/// completa para os outros 10 idiomas deve ser preenchida numa etapa
/// posterior dedicada à internacionalização de fato (ex.: migrando para
/// arquivos `.arb` + `flutter_localizations` + `intl_utils`).
class AppStrings {
  static const Map<String, String> pt = {
    'seguranca_titulo': 'Segurança',
    'fazer_checkin': 'Fazer\nCheck-in',
    'toque_para_iniciar': 'Toque para iniciar',
    'toque_desarmar': 'Toque: desarmar',
    'sos_botao_panico': 'SOS - Botão de Pânico',
    'configuracoes_titulo': 'Configurações',
    'alerta_sonoro_titulo': 'Alerta Sonoro',
    'idioma_titulo': 'Idioma',
    'idioma_alterado_snackbar':
        '🌐 Idioma alterado para {idioma}. Reinicie o app para aplicar completamente.',
  };

  // NOTA: os mapas abaixo (en, es, fr, de, it, zh, ar, ru, hi, ja) ainda
  // herdam a maior parte das chaves em português como placeholders,
  // aguardando a tradução completa futura (Etapa posterior de i18n).
  // A chave 'idioma_alterado_snackbar' é a EXCEÇÃO: já está totalmente
  // traduzida em todos os 11 idiomas, pois é o único texto de feedback
  // imediato exibido logo após a troca de idioma, precisando ser
  // compreendido por um usuário estrangeiro desde já.
  static const Map<String, String> _en = {
    'idioma_alterado_snackbar':
        '🌐 Language changed to {idioma}. Restart the app to apply completely.',
  };
  static const Map<String, String> _es = {
    'idioma_alterado_snackbar':
        '🌐 Idioma cambiado a {idioma}. Reinicia la app para aplicar por completo.',
  };
  static const Map<String, String> _fr = {
    'idioma_alterado_snackbar':
        "🌐 Langue changée en {idioma}. Redémarrez l'application pour appliquer complètement.",
  };
  static const Map<String, String> _de = {
    'idioma_alterado_snackbar':
        '🌐 Sprache geändert zu {idioma}. Starten Sie die App neu, um alles anzuwenden.',
  };
  static const Map<String, String> _it = {
    'idioma_alterado_snackbar':
        "🌐 Lingua cambiata in {idioma}. Riavvia l'app per applicare completamente.",
  };
  static const Map<String, String> _zh = {
    'idioma_alterado_snackbar': '🌐 语言已更改为{idioma}。请重启应用以完全生效。',
  };
  static const Map<String, String> _ar = {
    'idioma_alterado_snackbar':
        '🌐 تم تغيير اللغة إلى {idioma}. أعد تشغيل التطبيق للتطبيق الكامل.',
  };
  static const Map<String, String> _ru = {
    'idioma_alterado_snackbar':
        '🌐 Язык изменён на {idioma}. Перезапустите приложение, чтобы применить полностью.',
  };
  static const Map<String, String> _hi = {
    'idioma_alterado_snackbar':
        '🌐 भाषा बदलकर {idioma} कर दी गई है। पूरी तरह लागू करने के लिए ऐप को पुनः आरंभ करें।',
  };
  static const Map<String, String> _ja = {
    'idioma_alterado_snackbar': '🌐 言語が{idioma}に変更されました。完全に適用するにはアプリを再起動してください。',
  };

  static final Map<String, Map<String, String>> todos = {
    'pt': pt,
    'en': {...pt, ..._en},
    'es': {...pt, ..._es},
    'fr': {...pt, ..._fr},
    'de': {...pt, ..._de},
    'it': {...pt, ..._it},
    'zh': {...pt, ..._zh},
    'ar': {...pt, ..._ar},
    'ru': {...pt, ..._ru},
    'hi': {...pt, ..._hi},
    'ja': {...pt, ..._ja},
  };

  /// Retorna a string traduzida para [codigoIdioma] e [chave], ou o
  /// próprio texto em português como fallback se a chave/idioma não
  /// existir no mapa.
  static String traduzir(String codigoIdioma, String chave) {
    final mapaIdioma = todos[codigoIdioma] ?? pt;
    return mapaIdioma[chave] ?? (pt[chave] ?? chave);
  }

  /// Igual a [traduzir], mas substitui placeholders no formato
  /// `{nomeDoParametro}` pelos valores informados em [parametros].
  /// Usado, por exemplo, para injetar dinamicamente o nome do idioma
  /// recém-selecionado dentro da mensagem de feedback (Snackbar).
  static String traduzirComParametro(
    String codigoIdioma,
    String chave,
    Map<String, String> parametros,
  ) {
    var texto = traduzir(codigoIdioma, chave);
    parametros.forEach((nomeParametro, valor) {
      texto = texto.replaceAll('{$nomeParametro}', valor);
    });
    return texto;
  }
}
