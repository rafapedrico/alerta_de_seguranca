import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço central para persistência e leitura do plano de fundo
/// selecionado pelo usuário. Usa SharedPreferences para persistência
/// entre sessões, e um [ValueNotifier] global para que TODAS as telas
/// do app (Segurança, Família, Histórico, Configurações) atualizem o
/// plano de fundo instantaneamente assim que o usuário fizer uma nova
/// escolha, mesmo em telas que não estão sendo reconstruídas no momento
/// da troca (ex: abas dentro de um IndexedStack ou telas abertas via
/// Navigator.push).
class WallpaperService {
  static const String prefsKey = 'plano_fundo_selecionado';
  static const String defaultAsset = 'assets/light.png';

  /// Notifica em tempo real qualquer widget (via [ValueListenableBuilder])
  /// que precise reagir à troca do plano de fundo.
  static final ValueNotifier<String> wallpaperNotifier =
      ValueNotifier<String>(defaultAsset);

  /// Deve ser chamado uma vez na inicialização do app (ex: main.dart)
  /// para carregar o valor persistido e popular o [wallpaperNotifier].
  static Future<void> inicializar() async {
    wallpaperNotifier.value = await carregar();
  }

  /// Salva o caminho do asset selecionado (ex: 'assets/blue.png') no
  /// SharedPreferences e atualiza o [wallpaperNotifier] imediatamente,
  /// fazendo com que todas as telas ouvintes sejam notificadas na hora.
  static Future<void> salvar(String assetPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, assetPath);
    wallpaperNotifier.value = assetPath;
  }

  /// Recupera o caminho do asset salvo, ou o padrão caso não exista.
  static Future<String> carregar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefsKey) ?? defaultAsset;
  }
}
