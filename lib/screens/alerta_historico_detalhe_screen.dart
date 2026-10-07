import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/historico_alertas_service.dart';

/// Detalhe de uma entrada da área protegida do Histórico (alerta enviado
/// ou evento do cronômetro): data e hora, status, foto (cópia na pasta
/// privada do app — nunca na galeria — ou o link do Firebase), "Ver no
/// mapa" com as coordenadas e a precisão, e o texto personalizado.
class AlertaHistoricoDetalheScreen extends StatelessWidget {
  const AlertaHistoricoDetalheScreen({super.key, required this.evento});

  /// Linha da tabela `historico`.
  final Map<String, dynamic> evento;

  static String textoStatus(String? status, AppLocalizations l10n) {
    switch (status) {
      case StatusAlertaHistorico.enviando:
        return l10n.historicoStatusEnviando;
      case StatusAlertaHistorico.enviado:
        return l10n.historicoStatusEnviado;
      case StatusAlertaHistorico.pendente:
        return l10n.historicoStatusPendente;
      case StatusAlertaHistorico.falhou:
        return l10n.historicoStatusFalhou;
      default:
        return '';
    }
  }

  static Color corStatus(String? status) {
    switch (status) {
      case StatusAlertaHistorico.enviado:
        return Colors.green.shade700;
      case StatusAlertaHistorico.pendente:
      case StatusAlertaHistorico.enviando:
        return Colors.orange.shade800;
      case StatusAlertaHistorico.falhou:
        return Colors.red.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tipo = evento['tipo'] as String?;
    final titulo = (evento['titulo'] as String?) ??
        (tipo != null ? HistoricoAlertasService.tituloPorTipo(tipo, l10n) : '');
    final descricao = (evento['descricao'] as String?) ?? '';
    final status = evento['status'] as String?;
    final latitude = (evento['latitude'] as num?)?.toDouble();
    final longitude = (evento['longitude'] as num?)?.toDouble();
    final precisao = (evento['precisao'] as num?)?.toDouble();
    final fotoLocal = evento['foto_local'] as String?;
    final fotoUrl = evento['foto_url'] as String?;
    final contexto = evento['contexto'] as String?;
    final quando = DateTime.tryParse((evento['timestamp'] as String?) ?? '');
    final locale = Localizations.localeOf(context).toString();

    Widget? foto;
    if (fotoLocal != null && fotoLocal.isNotEmpty && File(fotoLocal).existsSync()) {
      foto = Image.file(File(fotoLocal), fit: BoxFit.cover);
    } else if (fotoUrl != null && fotoUrl.isNotEmpty) {
      foto = Image.network(fotoUrl, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Center(child: Text(l10n.historicoDetalheSemFoto)));
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.historicoDetalheTitulo)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(titulo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          if (descricao.isNotEmpty && descricao != titulo) ...[
            const SizedBox(height: 6),
            Text(descricao, style: TextStyle(fontSize: 14, color: Colors.grey.shade800)),
          ],
          const SizedBox(height: 16),
          _linha(l10n.historicoDetalheDataHora,
              quando != null ? DateFormat.yMd(locale).add_Hms().format(quando.toLocal()) : '—'),
          if (status != null && status.isNotEmpty)
            _linha(l10n.historicoDetalheStatus, textoStatus(status, l10n), cor: corStatus(status)),
          const SizedBox(height: 12),
          Text(l10n.historicoDetalheLocalizacao, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (latitude != null && longitude != null) ...[
            Text('${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}'),
            if (precisao != null) Text(l10n.historicoDetalhePrecisao(precisao.round())),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('https://maps.google.com/?q=$latitude,$longitude'),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.map_outlined),
                label: Text(l10n.historicoDetalheVerNoMapa),
              ),
            ),
          ] else
            Text(l10n.historicoDetalheSemLocalizacao, style: TextStyle(color: Colors.grey.shade700)),
          if (contexto != null && contexto.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.historicoDetalheTextoPersonalizado, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(contexto),
          ],
          const SizedBox(height: 16),
          Text(l10n.historicoDetalheFoto, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (foto != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(aspectRatio: 3 / 4, child: foto),
            )
          else
            Text(l10n.historicoDetalheSemFoto, style: TextStyle(color: Colors.grey.shade700)),
        ],
      ),
    );
  }

  Widget _linha(String rotulo, String valor, {Color? cor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(rotulo, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(valor, style: TextStyle(color: cor, fontWeight: cor != null ? FontWeight.bold : null))),
        ],
      ),
    );
  }
}
