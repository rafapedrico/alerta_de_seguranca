import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';

/// Tipos de entrada do histórico de alertas (coluna `tipo` da tabela
/// `historico`) — os MESMOS valores usados no app iOS.
class TipoAlertaHistorico {
  TipoAlertaHistorico._();

  static const String sosManual = 'sos_manual';
  static const String sosFisico = 'sos_fisico';
  static const String cronometroExpirado = 'cronometro_expirado';
  static const String tentativaDesarmeIncorreto = 'tentativa_desarme_incorreto';
  static const String cronometroAtivado = 'cronometro_ativado';
  static const String cronometroDesarmado = 'cronometro_desarmado';

  /// Despertador (aba Família): tolerância esgotada sem PIN.
  static const String despertadorExpirado = 'despertador_expirado';
}

/// Status de envio de uma entrada de alerta (coluna `status`).
class StatusAlertaHistorico {
  StatusAlertaHistorico._();

  static const String enviando = 'enviando';
  static const String enviado = 'enviado';
  static const String pendente = 'pendente';
  static const String falhou = 'falhou';
}

/// Histórico dos alertas ENVIADOS pelo próprio usuário — uma entrada por
/// alerta (pelo `alerta_id`), na área protegida por PIN (categoria
/// `critico`). A entrada nasce `enviando`, passa a `enviado` com a
/// confirmação do SMS ou do Firestore (ou a `pendente` sem confirmação) e
/// recebe a foto na MESMA linha, inclusive quando a fila de reenvio sobe a
/// foto mais tarde.
///
/// Na abertura do app (com sessão) [importarDoFirestore] traz os alertas
/// do próprio usuário que faltam no SQLite (reinstalação, alerta disparado
/// pelo servidor com o app fechado).
class HistoricoAlertasService {
  HistoricoAlertasService._internal();
  static final HistoricoAlertasService _instance = HistoricoAlertasService._internal();
  factory HistoricoAlertasService() => _instance;

  /// Categoria da área protegida por PIN.
  static const String categoriaProtegida = 'critico';

  final DatabaseHelper _db = DatabaseHelper();

  /// Id local para um alerta que ainda não tem documento no Firestore
  /// (sem sessão no momento do disparo).
  static String novoIdLocal() {
    final aleatorio = Random.secure().nextInt(1 << 32).toRadixString(16);
    return 'local_${DateTime.now().millisecondsSinceEpoch}_$aleatorio';
  }

  /// Cria a entrada de um alerta com status `enviando` (ou o [status]
  /// informado). Idempotente pelo [alertaId].
  Future<void> criarAlerta({
    required String alertaId,
    required String tipo,
    required String titulo,
    required String descricao,
    String? contexto,
    double? latitude,
    double? longitude,
    double? precisao,
    String status = StatusAlertaHistorico.enviando,
    DateTime? quando,
  }) async {
    try {
      await _db.inserirEventoHistorico(
        titulo: titulo,
        descricao: descricao,
        categoria: categoriaProtegida,
        alertaId: alertaId,
        tipo: tipo,
        status: status,
        latitude: latitude,
        longitude: longitude,
        precisao: precisao,
        contexto: (contexto ?? '').trim().isEmpty ? null : contexto!.trim(),
        quando: quando,
      );
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao criar a entrada $alertaId: $e');
    }
  }

  /// Evento do cronômetro sem envio aos contatos (ativado/desarmado) —
  /// também na área protegida, com localização quando houver.
  Future<void> registrarEvento({
    required String tipo,
    required String titulo,
    required String descricao,
    String? contexto,
    double? latitude,
    double? longitude,
    double? precisao,
  }) =>
      criarAlerta(
        alertaId: novoIdLocal(),
        tipo: tipo,
        titulo: titulo,
        descricao: descricao,
        contexto: contexto,
        latitude: latitude,
        longitude: longitude,
        precisao: precisao,
        status: '',
      );

  /// Nunca rebaixa um `enviado` para `pendente`/`falhou`.
  Future<void> marcarStatus(String alertaId, String status) async {
    try {
      final atual = await _db.buscarAlertaHistorico(alertaId);
      if (atual == null) return;
      if (atual['status'] == StatusAlertaHistorico.enviado &&
          status != StatusAlertaHistorico.enviado) {
        return;
      }
      await _db.atualizarAlertaHistorico(alertaId, status: status);
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao atualizar o status de $alertaId: $e');
    }
  }

  Future<void> atualizarLocalizacao(
    String alertaId, {
    required double latitude,
    required double longitude,
    double? precisao,
  }) async {
    try {
      await _db.atualizarAlertaHistorico(alertaId,
          latitude: latitude, longitude: longitude, precisao: precisao);
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao atualizar a localização de $alertaId: $e');
    }
  }

  /// Anexa a foto à entrada do alerta. [fotoArquivo] (temporário da
  /// câmera) é copiado para a pasta PRIVADA do app — nunca para a galeria.
  Future<void> anexarFoto(
    String alertaId, {
    String? fotoUrl,
    String? fotoArquivo,
  }) async {
    try {
      String? fotoLocal;
      if (fotoArquivo != null) fotoLocal = await guardarCopiaPrivada(fotoArquivo, alertaId);
      await _db.atualizarAlertaHistorico(alertaId, fotoUrl: fotoUrl, fotoLocal: fotoLocal);
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao anexar a foto a $alertaId: $e');
    }
  }

  /// Cópia da foto em `<documentos do app>/historico_fotos/` (área privada,
  /// fora da galeria). Devolve o caminho da cópia (ou `null`).
  Future<String?> guardarCopiaPrivada(String origem, String alertaId) async {
    try {
      final pasta = Directory(
          path.join((await getApplicationDocumentsDirectory()).path, 'historico_fotos'));
      if (!await pasta.exists()) await pasta.create(recursive: true);
      final nomeSeguro = alertaId.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
      final destino = path.join(pasta.path, '$nomeSeguro.jpg');
      if (path.equals(origem, destino)) return destino;
      await File(origem).copy(destino);
      return destino;
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao copiar a foto para a área privada: $e');
      return null;
    }
  }

  /// Apaga a cópia privada da foto de uma entrada (ao apagar a entrada).
  Future<void> apagarFotoLocal(String? fotoLocal) async {
    if (fotoLocal == null || fotoLocal.isEmpty) return;
    try {
      final arquivo = File(fotoLocal);
      if (await arquivo.exists()) await arquivo.delete();
    } catch (_) {}
  }

  // ==========================================================
  // IMPORTAÇÃO DO FIRESTORE (histórico que não se perde)
  // ==========================================================

  bool _importando = false;

  /// Importa os alertas do próprio usuário (`usuarios/{uid}/alertas` e
  /// `usuarios/{uid}/historico_alertas`) que ainda não estão no SQLite,
  /// pelo id do documento (= `alerta_id`). Fotos (`sos_fisico_foto`) são
  /// anexadas à entrada do SOS pelo campo `alertaId`. Nunca lança.
  Future<void> importarDoFirestore() async {
    if (_importando) return;
    if (Firebase.apps.isEmpty) return;
    _importando = true;
    try {
      final uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid == null) return;
      final usuario = FirebaseFirestore.instance.collection('usuarios').doc(uid);
      final documentos = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      for (final colecao in const ['alertas', 'historico_alertas']) {
        try {
          final snap = await usuario
              .collection(colecao)
              .orderBy('criadoEm', descending: true)
              .limit(300)
              .get()
              .timeout(const Duration(seconds: 15));
          documentos.addAll(snap.docs);
        } catch (e) {
          debugPrint('⚠️ [HistoricoAlertas] Importação de "$colecao" indisponível: $e');
        }
      }
      if (documentos.isEmpty) return;

      final existentes = await _db.idsAlertasNoHistorico();
      final l10n = await L10nHeadlessService.obter();
      final fotos = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      var importados = 0;

      for (final doc in documentos) {
        final dados = doc.data();
        final tipoDoc = (dados['tipo'] as String?) ?? '';
        if (tipoDoc == 'sos_fisico_foto') {
          fotos.add(doc);
          continue;
        }
        final alertaId = (dados['alertaId'] as String?) ?? doc.id;
        if (existentes.contains(alertaId)) continue;

        final tipo = _tipoLocal(dados);
        final quando = _data(dados['criadoEm']) ?? DateTime.now();
        final contexto = (dados['contextoPersonalizado'] as String?) ?? '';
        final motivo = (dados['motivo'] as String?) ?? '';
        await criarAlerta(
          alertaId: alertaId,
          tipo: tipo,
          titulo: _tituloPorTipo(tipo, l10n),
          descricao: motivo.isNotEmpty ? motivo : _tituloPorTipo(tipo, l10n),
          contexto: contexto,
          latitude: (dados['latitude'] as num?)?.toDouble(),
          longitude: (dados['longitude'] as num?)?.toDouble(),
          precisao: (dados['precisao'] as num?)?.toDouble(),
          status: StatusAlertaHistorico.enviado,
          quando: quando,
        );
        existentes.add(alertaId);
        importados++;
      }

      for (final doc in fotos) {
        final dados = doc.data();
        final fotoUrl = dados['fotoUrl'] as String?;
        if (fotoUrl == null || fotoUrl.isEmpty) continue;
        final alertaSos = (dados['alertaId'] as String?) ?? doc.id;
        final atual = await _db.buscarAlertaHistorico(alertaSos);
        if (atual != null) {
          if ((atual['foto_url'] as String?)?.isNotEmpty != true) {
            await _db.atualizarAlertaHistorico(alertaSos, fotoUrl: fotoUrl);
          }
          continue;
        }
        // Foto sem a entrada do SOS (alerta antigo, sem `alertaId`).
        await criarAlerta(
          alertaId: alertaSos,
          tipo: (dados['origem'] as String?) == TipoAlertaHistorico.sosManual
              ? TipoAlertaHistorico.sosManual
              : TipoAlertaHistorico.sosFisico,
          titulo: l10n.historicoFotoSosSmsTitulo,
          descricao: l10n.historicoFotoSosSmsTitulo,
          latitude: (dados['latitude'] as num?)?.toDouble(),
          longitude: (dados['longitude'] as num?)?.toDouble(),
          status: StatusAlertaHistorico.enviado,
          quando: _data(dados['criadoEm']),
        );
        await _db.atualizarAlertaHistorico(alertaSos, fotoUrl: fotoUrl);
        importados++;
      }
      if (importados > 0) {
        debugPrint('📥 [HistoricoAlertas] $importados alerta(s) importado(s) do Firestore.');
      }
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha na importação do Firestore: $e');
    } finally {
      _importando = false;
    }
  }

  static DateTime? _data(Object? valor) {
    if (valor is Timestamp) return valor.toDate();
    if (valor is String) return DateTime.tryParse(valor);
    if (valor is int) return DateTime.fromMillisecondsSinceEpoch(valor);
    return null;
  }

  /// Tipo local a partir do documento do Firestore (`tipo` + `origem`).
  static String _tipoLocal(Map<String, dynamic> dados) {
    final tipo = (dados['tipo'] as String?) ?? '';
    final origem = (dados['origem'] as String?) ?? '';
    if (tipo == 'sos_fisico') {
      return origem == TipoAlertaHistorico.sosManual
          ? TipoAlertaHistorico.sosManual
          : TipoAlertaHistorico.sosFisico;
    }
    if (tipo == TipoAlertaHistorico.cronometroExpirado ||
        tipo == TipoAlertaHistorico.despertadorExpirado ||
        tipo == TipoAlertaHistorico.tentativaDesarmeIncorreto ||
        tipo == TipoAlertaHistorico.sosManual) {
      return tipo;
    }
    if (tipo == 'alarme_rotina' || origem == 'alarme_rotina') {
      return TipoAlertaHistorico.despertadorExpirado;
    }
    return TipoAlertaHistorico.tentativaDesarmeIncorreto;
  }

  /// Título localizado por tipo (entradas importadas e tela de detalhe).
  static String _tituloPorTipo(String tipo, AppLocalizations l10n) {
    switch (tipo) {
      case TipoAlertaHistorico.sosManual:
        return l10n.historicoTipoSosManual;
      case TipoAlertaHistorico.sosFisico:
        return l10n.historicoTipoSosFisico;
      case TipoAlertaHistorico.cronometroExpirado:
        return l10n.historicoTipoCronometroExpirado;
      case TipoAlertaHistorico.cronometroAtivado:
        return l10n.historicoTipoCronometroAtivado;
      case TipoAlertaHistorico.cronometroDesarmado:
        return l10n.historicoTipoCronometroDesarmado;
      case TipoAlertaHistorico.despertadorExpirado:
        return l10n.historicoTipoDespertadorExpirado;
      case TipoAlertaHistorico.tentativaDesarmeIncorreto:
      default:
        return l10n.historicoTipoTentativaDesarme;
    }
  }

  /// Público: título localizado de um [tipo] (tela de detalhe).
  static String tituloPorTipo(String tipo, AppLocalizations l10n) => _tituloPorTipo(tipo, l10n);
}
