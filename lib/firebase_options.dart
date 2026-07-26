// Configuração manual do Firebase (equivalente ao que `flutterfire configure`
// geraria automaticamente), montada a partir dos dados já presentes em
// `android/app/google-services.json` (projeto "guardiaox"). Escrito à mão
// porque o CLI do FlutterFire exige login interativo, indisponível neste
// ambiente.
//
// Cobre APENAS Android, único alvo mobile real do projeto no momento — ver
// [DefaultFirebaseOptions.currentPlatform]. Caso o app venha a rodar em
// iOS/Web no futuro, rode `flutterfire configure` de verdade para gerar as
// credenciais reais dessas plataformas (as daqui não servem para elas).
library firebase_options;

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions não foi configurado para Web. '
        'Rode `flutterfire configure` para gerar as credenciais reais.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions só foi configurado para Android neste '
          'projeto. Rode `flutterfire configure` para adicionar suporte a '
          '${defaultTargetPlatform.name}.',
        );
    }
  }

  /// Extraído de android/app/google-services.json (projeto "guardiaox").
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAD3cnaZu1w7EeBvgoazJYXnEd5nAP1R7M',
    appId: '1:555863351772:android:1b76bbad7fe800e14def19',
    messagingSenderId: '555863351772',
    projectId: 'guardiaox',
    storageBucket: 'guardiaox.firebasestorage.app',
  );
}
