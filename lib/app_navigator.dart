import 'package:flutter/material.dart';

/// [GlobalKey] central do [NavigatorState] do aplicativo, registrada no
/// `navigatorKey` do [MaterialApp] em `main.dart`.
///
/// Necessária para o recurso de Captura e Dissuasão: pontos de disparo
/// de emergência que NÃO possuem um [BuildContext] de tela local — como o
/// listener de SOS físico (Volume+) em `main.dart`, que roda fora de
/// qualquer árvore de widgets — ainda assim precisam navegar até a
/// [CameraCapturaScreen] em tela cheia.
///
/// Mantendo essa chave centralizada e desacoplada de qualquer serviço de
/// negócio (ex: EmergencyAlertService), preservamos a regra de que
/// serviços "puros" nunca dependem de UI, deixando cada ponto de chamada
/// (SegurancaTab, listener do main.dart) livre para decidir se e quando
/// deve navegar.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
