import 'package:flutter/material.dart';
import 'services/encryption_service.dart';
import 'services/wallpaper_service.dart';
import 'services/font_scale_service.dart';
import 'services/database_helper.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize AES-256 encryption service before running the app
  EncryptionService().initialize();

  // Carrega as preferências salvas (plano de fundo e tamanho de fonte)
  // antes de exibir a UI, garantindo que o app já abra com os valores
  // corretos escolhidos anteriormente pelo usuário.
  await WallpaperService.inicializar();
  await FontScaleService.inicializar();

  // Regra de segurança/privacidade: a cada cold start real do aplicativo
  // (processo novo), o estado de liberação da Auditoria de Eventos
  // Sensíveis é resetado. Isso garante que, mesmo que a trava de 3h já
  // tenha sido cumprida em uma sessão anterior, o app sempre "esqueça"
  // essa liberação assim que for totalmente fechado e reaberto — embora,
  // se as 3h desde a última solicitação já tiverem se passado, a tela de
  // auditoria libera novamente de forma automática ao ser reaberta.
  await DatabaseHelper().resetarSessaoAuditoria();

  runApp(const SecurityCheckApp());
}


class SecurityCheckApp extends StatelessWidget {
  const SecurityCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Ouve o fator de escala de fonte escolhido pelo usuário e reconstrói
    // todo o MaterialApp instantaneamente quando ele mudar, aplicando o
    // tamanho de letra em todas as telas do app.
    return ValueListenableBuilder<double>(
      valueListenable: FontScaleService.fontScaleNotifier,
      builder: (context, fatorFonte, _) {
        return MaterialApp(
          title: 'Security Check',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: Colors.blue,
            useMaterial3: true,
          ),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(fatorFonte),
              ),
              child: child!,
            );
          },
          home: const HomeScreen(),
        );
      },
    );
  }
}
