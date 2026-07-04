import 'package:flutter/material.dart';
import '../../services/wallpaper_service.dart';

class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

class _HistoricoTabState extends State<HistoricoTab> {
  final List<String> _activities = [
    'Aguardando check-in de Segurança',
    'Alarme Reiniciado',
    'Envio para Contato (Mamãe)',
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: WallpaperService.wallpaperNotifier,
      builder: (context, fundoAtivo, _) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(fundoAtivo),
              fit: BoxFit.cover,
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: _activities.length,
                  itemBuilder: (context, index) {
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(_activities[index]),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () {
                            // Implement delete functionality here
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: ElevatedButton.icon(
                  onPressed: () {
                    // Implement delete selected items functionality here
                  },
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Apagar itens selecionados'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
