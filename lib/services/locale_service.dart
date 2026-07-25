import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gerenciador de estado do idioma ativo do app (Locale). Segue o mesmo
/// padrão já usado por [FontScaleService]/[WallpaperService]: persiste a
/// escolha em SharedPreferences e expõe um [ValueNotifier] global para
/// que o [MaterialApp] (e toda a árvore de widgets) seja reconstruído
/// instantaneamente ao trocar de idioma, sem precisar reiniciar o app.
///
/// Reaproveita a mesma chave `idioma_selecionado` já usada por
/// [LocalizationService], preservando a escolha já persistida.
class LocaleService {
  static const String _prefsKeyIdioma = 'idioma_selecionado';

  /// Idioma padrão (Português), usado como fallback.
  static const String idiomaPadrao = 'pt';

  /// Idiomas com tradução completa via AppLocalizations (arquivos .arb em
  /// lib/l10n/) — os 11 idiomas globais listados em
  /// [LocalizationService.idiomasSuportados] têm todos arquivo .arb
  /// próprio. Qualquer código fora desta lista (nunca deveria ocorrer, já
  /// que o seletor só oferece estes 11) cai para o idioma padrão.
  static const List<String> idiomasComTraducaoCompleta = [
    'pt', 'en', 'es', 'fr', 'de', 'it', 'zh', 'ar', 'ru', 'hi', 'ja',
  ];

  static final ValueNotifier<Locale> localeNotifier =
      ValueNotifier<Locale>(const Locale(idiomaPadrao));

  /// Código de idioma BRUTO selecionado pelo usuário (um dos 11 do
  /// seletor legado em Configurações), independente de já existir
  /// tradução completa (.arb) para ele ou não. Usado para decidir qual
  /// imagem do cabeçalho da tela de Login exibir (ver
  /// [caminhoImagemLoginPara]), já que a imagem é um asset estático por
  /// idioma e não depende do AppLocalizations.
  static final ValueNotifier<String> codigoIdiomaCompletoNotifier =
      ValueNotifier<String>(idiomaPadrao);

  /// Mapa do código de idioma para o arquivo de imagem do cabeçalho da
  /// tela de Login correspondente, em assets/images/ (pasta já registrada
  /// por inteiro no pubspec.yaml). Basta adicionar o arquivo com esse
  /// nome exato na pasta para ele passar a ser usado automaticamente,
  /// sem precisar mexer em código.
  static const Map<String, String> _imagensLoginPorIdioma = {
    'pt': 'assets/images/logo_guardiao_x_topo.png',
    'en': 'assets/images/logo_guardiao_x_topo_ingles.png',
    'es': 'assets/images/logo_guardiao_x_topo_espanhol.png',
    'fr': 'assets/images/logo_guardiao_x_topo_frances.png',
    'de': 'assets/images/logo_guardiao_x_topo_alemao.png',
    'it': 'assets/images/logo_guardiao_x_topo_italiano.png',
    'zh': 'assets/images/logo_guardiao_x_topo_chines.png',
    'hi': 'assets/images/logo_guardiao_x_topo_hindi.png',
    'ja': 'assets/images/logo_guardiao_x_topo_japones.png',
    'ar': 'assets/images/logo_guardiao_x_topo_arabe.png',
    'ru': 'assets/images/logo_guardiao_x_topo_russo.png',
  };

  /// Imagem padrão (Português), usada como fallback tanto quando o
  /// código de idioma não está no mapa quanto quando o arquivo mapeado
  /// ainda não foi adicionado fisicamente à pasta (ver `errorBuilder` do
  /// Image.asset em LoginScreen).
  static const String imagemLoginPadrao = 'assets/images/logo_guardiao_x_topo.png';

  /// Caminho do asset de imagem do cabeçalho da tela de Login para o
  /// [codigoIdioma] informado. Cai para [imagemLoginPadrao] se o código
  /// não estiver mapeado.
  static String caminhoImagemLoginPara(String codigoIdioma) {
    return _imagensLoginPorIdioma[codigoIdioma] ?? imagemLoginPadrao;
  }

  /// Deve ser chamado uma vez na inicialização do app (main.dart) para
  /// carregar o idioma persistido e popular os notifiers.
  static Future<void> inicializar() async {
    final codigo = await _carregarCodigoPersistido();
    codigoIdiomaCompletoNotifier.value = codigo;
    localeNotifier.value = Locale(_codigoResolvido(codigo));
  }

  /// Persiste o novo idioma escolhido e atualiza os notifiers
  /// imediatamente: [localeNotifier] reconstrói toda a interface textual
  /// (AppLocalizations) e [codigoIdiomaCompletoNotifier] troca a imagem
  /// do cabeçalho do Login, ambos sem precisar reiniciar o app.
  static Future<void> definirIdioma(String codigo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyIdioma, codigo);
    codigoIdiomaCompletoNotifier.value = codigo;
    localeNotifier.value = Locale(_codigoResolvido(codigo));
  }

  static Future<String> _carregarCodigoPersistido() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKeyIdioma) ?? idiomaPadrao;
  }

  /// Resolve qualquer código de idioma para um dos que já têm tradução
  /// completa, caindo para [idiomaPadrao] apenas em caso de código
  /// desconhecido/inválido.
  static String _codigoResolvido(String codigo) {
    return idiomasComTraducaoCompleta.contains(codigo) ? codigo : idiomaPadrao;
  }
}
