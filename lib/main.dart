import 'package:flutter/material.dart';
import 'services/encryption_service.dart';
import 'screens/home_screen.dart';

void main() {
  // Initialize AES-256 encryption service before running the app
  EncryptionService().initialize();

  runApp(const SecurityCheckApp());
}

class SecurityCheckApp extends StatelessWidget {
  const SecurityCheckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Security Check',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
