# Estrutura de Internacionalização (i18n) - 11 Idiomas Globais

Esta pasta é o ponto de destino planejado para os futuros arquivos de
tradução (`.arb` ou `.json`) do app, cobrindo os 11 idiomas globais
estratégicos definidos na Etapa 2 da Expansão Global:

| Código | Idioma            | Nome nativo | Mercado-alvo (motociclistas)         |
|--------|-------------------|-------------|----------------------------------------|
| pt     | Português         | Português   | Brasil (origem)                        |
| en     | Inglês            | English     | EUA / Global / Filipinas               |
| es     | Espanhol          | Español     | América Latina hispânica / Espanha     |
| fr     | Francês           | Français    | França / África Ocidental francófona   |
| de     | Alemão            | Deutsch     | Alemanha / Áustria / Suíça             |
| it     | Italiano          | Italiano    | Itália                                 |
| zh     | Chinês            | 中文        | China (maior mercado de duas rodas)    |
| ar     | Árabe             | العربية     | Oriente Médio / Norte da África        |
| ru     | Russo             | Русский     | Rússia / CEI                           |
| hi     | Hindi (Indiano)   | हिन्दी      | Índia (maior mercado de motos do mundo)|
| ja     | Japonês           | 日本語      | Japão (indústria histórica de motos)   |

## Status atual

Por enquanto, o app usa `lib/services/localization_service.dart` como
fonte única de verdade para:
1. Listar os 11 idiomas suportados (`LocalizationService.idiomasSuportados`);
2. Persistir a escolha do usuário via SharedPreferences;
3. Centralizar strings traduzíveis em `AppStrings` (mapa de chave → texto).

Esta pasta `assets/lang/` está reservada para quando a tradução completa
for migrada para o pipeline oficial do Flutter
(`flutter_localizations` + `intl` + arquivos `.arb`), permitindo geração
automática de código com `intl_utils` ou `flutter gen-l10n`.

## Próximos passos sugeridos

1. Criar `app_pt.arb`, `app_en.arb`, `app_es.arb`, `app_fr.arb`,
   `app_de.arb`, `app_it.arb`, `app_zh.arb`, `app_ar.arb`, `app_ru.arb`,
   `app_hi.arb`, `app_ja.arb` com todas as chaves de `AppStrings.pt`.
2. Adicionar `flutter_localizations` e `intl` ao `pubspec.yaml`.
3. Configurar `MaterialApp.localizationsDelegates` e `supportedLocales`
   em `lib/main.dart`.
4. Substituir os textos hardcoded na UI por `AppLocalizations.of(context)!.chave`.
