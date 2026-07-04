import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço central para persistência e leitura do fator de escala de
/// fonte escolhido pelo usuário (acessibilidade visual). Segue o mesmo
/// padrão do [WallpaperService]: persiste no SharedPreferences e expõe
/// um [ValueNotifier] global para que TODAS as telas do app atualizem
/// o tamanho das letras instantaneamente assim que o usuário mudar a
/// preferência.
class FontScaleService {
  static const String prefsKey = 'fator_tamanho_fonte';

  // Valores sugeridos de fator de escala.
  static const double pequeno = 1.0;
  static const double padrao = 1.3;
  static const double grande = 1.6;

  static const double defaultValue = padrao;

  /// Notifica em tempo real qualquer widget que precise reagir à troca
  /// do tamanho da fonte (ex: MaterialApp via MediaQuery/TextScaler).
  static final ValueNotifier<double> fontScaleNotifier =
      ValueNotifier<double>(defaultValue);

  /// Deve ser chamado uma vez na inicialização do app (ex: main.dart)
  /// para carregar o valor persistido e popular o [fontScaleNotifier].
  static Future<void> inicializar() async {
    fontScaleNotifier.value = await carregar();
  }

  /// Salva o fator de escala escolhido e atualiza o [fontScaleNotifier]
  /// imediatamente, fazendo com que todo o app seja redesenhado com o
  /// novo tamanho de fonte na hora.
  static Future<void> salvar(double fator) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(prefsKey, fator);
    fontScaleNotifier.value = fator;
  }

  /// Recupera o fator salvo, ou o padrão caso não exista.
  static Future<double> carregar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(prefsKey) ?? defaultValue;
  }

  /// Rótulo amigável para exibição na UI, de acordo com o fator atual.
  static String rotuloPara(double fator) {
    if (fator <= pequeno) return 'Pequeno';
    if (fator >= grande) return 'Grande';
    return 'Padrão';
  }
}
