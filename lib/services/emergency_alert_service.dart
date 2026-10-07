import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:geolocator/geolocator.dart';

import 'database_helper.dart';
import 'l10n_headless_service.dart';
import 'plano_ciclo_service.dart';
import '../utils/telefone_utils.dart';

/// Resultado REAL de um envio de SMS (ver `SmsSender.kt`,
/// `enviarSmsComConfirmacao`): [confirmados] = contatos com todas as partes
/// aceitas pelo rádio dentro do limite de tempo.
@immutable
class ResultadoSms {
  const ResultadoSms({
    this.semContatos = false,
    this.bloqueado = false,
    this.tentados = 0,
    this.confirmados = 0,
    this.tempoEsgotado = false,
  });

  final bool semContatos;
  final bool bloqueado;
  final int tentados;
  final int confirmados;
  final bool tempoEsgotado;

  bool get confirmado => confirmados > 0;
}


/// Envio dos SMS de emergência pelo `SmsManager` do Android (canal nativo
/// `sms`), com o resultado REAL do rádio — usado pelo SOS
/// ([SosDisparoService]) e pelos alertas do cronômetro/despertador
/// ([AlertaDesarmeService]). Não grava histórico: quem dispara o alerta
/// cuida da entrada única do histórico (ver [HistoricoAlertasService]).
class EmergencyAlertService {
  EmergencyAlertService._internal();
  static final EmergencyAlertService _instance =
      EmergencyAlertService._internal();
  factory EmergencyAlertService() => _instance;

  static const MethodChannel _canalSms =
      MethodChannel('com.example.security_check_app/sms');

  final DatabaseHelper _db = DatabaseHelper();

  /// Emojis decorativos usados nos textos de SMS (`sms*Corpo` em
  /// `app_XX.arb`) — nenhum caractere fora do alfabeto padrão GSM 03.38
  /// (o único que caracteres puramente ASCII/latino cobrem no envio real
  /// de SMS; acentos do português já fazem parte desse alfabeto, então
  /// NÃO são afetados aqui).
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-23, confirmado via logcat nativo —
  /// `adb logcat -s SmsSender`): um SMS com QUALQUER caractere fora do
  /// GSM 03.38 obriga o Android a codificar a mensagem INTEIRA em UCS-2
  /// (70 caracteres por parte) em vez de GSM-7 concatenado (153
  /// caracteres por parte) — o emoji sozinho, no INÍCIO da mensagem,
  /// bastava para triplicar o número de partes. Um teste real (Moto G7
  /// Play, "TENTATIVA DE DESARME") mostrou a mensagem completa
  /// (~280 caracteres) sendo dividida em 5 partes por contato; o rádio
  /// aceitou TODAS (nenhum RESULT_ERROR_*), mas levou mais de 2 MINUTOS
  /// entre a primeira e a última parte, chegando fora de ordem — janela
  /// mais que suficiente para o app do destinatário desistir de
  /// remontar a mensagem multi-parte, resultando em "SMS não chegou"
  /// mesmo com o envio 100% confirmado do lado de quem manda.
  ///
  /// Removido SOMENTE do texto que sai de verdade pelo SmsManager (ver
  /// [_enviarSms]) — o emoji continua intacto em qualquer outro lugar
  /// (Push/histórico local/notificação), onde não custa nada e ajuda a
  /// chamar atenção visualmente.
  static final RegExp _emojiDecorativo = RegExp(
    '[\u{2600}-\u{27BF}\u{1F300}-\u{1FAFF}\u{FE00}-\u{FE0F}\u{2B00}-\u{2BFF}]',
    unicode: true,
  );

  /// Casa o trecho "Rótulo: número, Rótulo: número " (ex: "Latitude:
  /// -23.5, Longitude: -47.4 ") logo ANTES do link do Google Maps entre
  /// parênteses — ver [_formatarPosicao]. `\p{L}` (letra Unicode) em vez
  /// de "Latitude"/"Longitude" fixos porque esses rótulos são
  /// localizados (`historicoLatitudeLabel`/`historicoLongitudeLabel`,
  /// diferentes em cada um dos 11 idiomas do app).
  ///
  /// CORREÇÃO (2026-08-23, pedido do usuário): o link já contém as
  /// mesmas coordenadas (`?q=lat,lng`) — repeti-las por extenso no corpo
  /// do SMS só engordava a mensagem sem agregar nenhuma informação nova
  /// para quem recebe (o link abre direto no mapa). Removido SOMENTE do
  /// texto que sai pelo SMS — o histórico local continua mostrando
  /// latitude/longitude por extenso normalmente.
  static final RegExp _rotuloLatLongAntesDoLink = RegExp(
    r'[\p{L}]+:\s*-?[\d.]+,\s*[\p{L}]+:\s*-?[\d.]+\s*(?=\()',
    unicode: true,
  );

  /// Transliteração para ASCII dos diacríticos latinos mais comuns entre
  /// os 11 idiomas do app (á, ã, â, à, ä, é, ê, è, ë, í, ì, î, ï, ó, ô,
  /// õ, ò, ö, ú, ù, û, ü, ñ, ç, ß, œ, æ — e variantes maiúsculas).
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-23): o alfabeto GSM 03.38 (SMS) só
  /// cobre um subconjunto BEM menor de acentos do que o esperado (à, è,
  /// é, ì, ò, ù, Ä, Ö, Ñ, Ü, ä, ö, ñ, ü) — confirmado via
  /// `adb logcat -s SmsSender` que, mesmo depois de remover o emoji (ver
  /// [_emojiDecorativo]), a mensagem em português CONTINUAVA saindo em
  /// UCS-2/5 partes por causa só de "ã"/"ç"/"á"/"ó" (nenhum destes está
  /// no alfabeto básico do GSM 03.38). Em vez de reimplementar essa
  /// tabela reduzida (e arriscar esquecer algum idioma), transliterar
  /// tudo para o equivalente ASCII mais próximo é mais simples e
  /// garante GSM-7 (153 caracteres/parte) para qualquer idioma de
  /// escrita latina — idiomas de escrita não-latina (ex: árabe)
  /// continuam exigindo UCS-2 de qualquer forma, limitação real do
  /// protocolo SMS, não deste app.
  static const Map<String, String> _transliteracaoAscii = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
    'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
    'ß': 'ss', 'œ': 'oe', 'æ': 'ae',
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A',
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E',
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I',
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O',
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U',
    'Ñ': 'N', 'Ç': 'C', 'Ý': 'Y',
    'Œ': 'Oe', 'Æ': 'Ae',
  };

  /// Pontuação "tipográfica" (smart quotes/travessão/reticências) para o
  /// equivalente ASCII/GSM-7 mais próximo — mesmo motivo do
  /// [_transliteracaoAscii] acima: qualquer um destes caracteres, sozinho,
  /// já basta para forçar a mensagem INTEIRA para UCS-2.
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-23, mesmo dia da correção de acentos):
  /// `smsLocalizacaoCacheIndisponivel` (usada no PRIMEIRO SMS do SOS
  /// físico, ver [dispararSosComDuplaLocalizacao], quando a localização em
  /// cache ainda não está disponível) tem um travessão "—" (U+2014) nos
  /// 11 idiomas — sozinho, ele já reintroduzia a mesma degradação para
  /// UCS-2/5-partes que a transliteração de acentos foi feita para evitar.
  /// Mais importante: [anotacoesUsuario] (o campo "contexto", TEXTO LIVRE
  /// digitado pelo usuário — ver [_prepararMensagemParaSms]) pode conter
  /// qualquer um destes caracteres sem que nenhuma tradução do app tenha
  /// culpa nenhuma; sem esta normalização, um usuário digitando aspas
  /// "inteligentes" do teclado do próprio Android (comportamento padrão
  /// de autocorreção) já bastaria para degradar o SMS inteiro de novo.
  static const Map<String, String> _pontuacaoTipografica = {
    '–': '-', // – en dash
    '—': '-', // — em dash
    '‘': "'", '’': "'", // ' '
    '“': '"', '”': '"', // " "
    '…': '...', // …
    '•': '-', // •
    ' ': ' ', // espaço não separável
  };

  /// `yyyy-MM-dd HH:mm` — formato numérico ISO, sem ambiguidade de
  /// ordem dia/mês entre os países atendidos pelo app (diferente de
  /// "23/08" ou "08/23", que significam datas diferentes dependendo da
  /// região do destinatário). Pedido do usuário (2026-08-23): toda
  /// mensagem de emergência passa a informar quando foi enviada, para o
  /// contato saber o quão recente é o alerta.
  String _formatarDataHoraEnvio(DateTime agora) {
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${agora.year}-${dois(agora.month)}-${dois(agora.day)} '
        '${dois(agora.hour)}:${dois(agora.minute)}';
  }

  /// Remove [_emojiDecorativo] e acentos (via [_transliteracaoAscii]),
  /// normaliza os espaços/linhas resultantes (um caractere removido do
  /// início de uma linha deixava um espaço em branco solto antes do
  /// texto) e prefixa a data/hora do envio. Só chamado imediatamente
  /// antes de [_canalSms].invokeMethod — nunca deve vazar para fora de
  /// [_enviarSms] (o texto acentuado/com emoji original continua sendo
  /// usado em qualquer outro lugar: Push, histórico local, notificação).
  String _prepararMensagemParaSms(String mensagem) {
    var semDecoracao = mensagem
        .replaceAll(_emojiDecorativo, '')
        .replaceAll(_rotuloLatLongAntesDoLink, '');
    _transliteracaoAscii.forEach((acentuado, ascii) {
      semDecoracao = semDecoracao.replaceAll(acentuado, ascii);
    });
    _pontuacaoTipografica.forEach((tipografico, ascii) {
      semDecoracao = semDecoracao.replaceAll(tipografico, ascii);
    });
    semDecoracao = semDecoracao
        .split('\n')
        .map((linha) => linha.trim())
        .join('\n')
        .trim();

    final dataHora = _formatarDataHoraEnvio(DateTime.now());
    return '[$dataHora] $semDecoracao';
  }

  /// Posição em texto (latitude/longitude + link do Google Maps). No SMS,
  /// "Latitude: x, Longitude: y" sai e fica só o link (ver
  /// [_prepararMensagemParaSms]).
  String formatarPosicao(Position posicao, AppLocalizations l10n) {
    return '${l10n.historicoLatitudeLabel}: ${posicao.latitude}, '
        '${l10n.historicoLongitudeLabel}: ${posicao.longitude} '
        '(https://maps.google.com/?q=${posicao.latitude},${posicao.longitude})';
  }

  /// Texto da localização de um alerta (ou o aviso de indisponível).
  String textoLocalizacao(Position? posicao, AppLocalizations l10n) =>
      posicao != null ? formatarPosicao(posicao, l10n) : l10n.smsLocalizacaoIndisponivelMomentoEnvio;

  /// Contatos que recebem o SMS (sem telefone vazio e sem o próprio número).
  Future<List<String>> numerosDestinatarios() async {
    List<Map<String, dynamic>> contatos = [];
    try {
      contatos = await _db.getContatosEmergencia();
    } catch (e) {
      debugPrint('⚠️ [SMS] Falha ao buscar contatos de emergência: $e');
    }
    String? telefoneProprio;
    try {
      final config = await _db.getUserConfig();
      telefoneProprio = config?['telefone'] as String?;
    } catch (_) {}
    // O PRÓPRIO número cadastrado por engano como contato faria a vítima
    // receber o próprio alerta (ver TelefoneUtils.excluirProprioNumero).
    return TelefoneUtils.excluirProprioNumero(contatos, telefoneProprio)
        .map((c) => (c['telefone'] as String?) ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// `true` se há ao menos um contato de emergência com telefone.
  Future<bool> temContatos() async => (await numerosDestinatarios()).isNotEmpty;

  /// Envia [mensagem] a todos os contatos de emergência e devolve o
  /// resultado REAL do rádio (espera no máximo [limite]). Bloqueado só se o
  /// status do plano EM CACHE disser claramente "bloqueado" (nunca espera a
  /// rede).
  Future<ResultadoSms> enviarSms(
    String mensagem, {
    Duration limite = const Duration(seconds: 15),
  }) async {
    final status = await PlanoCicloService().statusEmCache();
    if (status != null && !status.ativo) {
      debugPrint('🔒 [SMS] Plano Free fora da janela de 10 dias ativos — SMS bloqueado '
          '(isPremium=${status.isPremium}, dia=${status.diaAtualCiclo}/30).');
      return const ResultadoSms(bloqueado: true);
    }

    final numeros = await numerosDestinatarios();
    if (numeros.isEmpty) {
      debugPrint('⚠️ [SMS] Nenhum contato de emergência com telefone — SMS NÃO enviado.');
      return const ResultadoSms(semContatos: true);
    }
    debugPrint('📨 [SMS] Enviando para ${numeros.length} contato(s)...');
    try {
      final resumo = await _canalSms.invokeMapMethod<String, dynamic>('enviarSmsComConfirmacao', {
        'telefones': numeros,
        'mensagem': _prepararMensagemParaSms(mensagem),
        'limiteMs': limite.inMilliseconds,
      });
      final resultado = ResultadoSms(
        tentados: (resumo?['tentados'] as num?)?.toInt() ?? 0,
        confirmados: (resumo?['confirmados'] as num?)?.toInt() ?? 0,
        tempoEsgotado: resumo?['tempoEsgotado'] == true,
      );
      debugPrint('📨 [SMS] Resultado do rádio: tentados=${resultado.tentados} '
          'confirmados=${resultado.confirmados} tempoEsgotado=${resultado.tempoEsgotado} '
          'erro=${resumo?['erro']}');
      return resultado;
    } on MissingPluginException catch (e) {
      // Engine headless (android_alarm_manager_plus/firebase_messaging): o
      // canal nativo de SMS não existe aqui — nunca repete em loop.
      debugPrint('⚠️ [SMS] Canal de SMS indisponível neste engine: $e');
      return const ResultadoSms();
    } catch (e) {
      debugPrint('⚠️ [SMS] Falha ao enviar SMS de emergência: $e');
      return const ResultadoSms();
    }
  }

  /// SMS da foto do SOS (link REAL da foto já enviada) — sem localização
  /// (já foi no SMS do SOS) para caber numa parte só.
  Future<ResultadoSms> enviarSmsComLinkDaFoto(String fotoUrl) async {
    final l10n = await L10nHeadlessService.obter();
    return enviarSms(l10n.smsFotoCorpo(fotoUrl));
  }
}
