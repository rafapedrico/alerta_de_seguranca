import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PIN do Guardião-X guardado como hash com sal (nunca em texto puro).
///
/// Formato gravado em `user_config.pin_real`/`senha_pendente`:
/// `pbkdf2$<iteracoes>$<sal base64>$<hash base64>` — PBKDF2-HMAC-SHA256.
/// Um valor sem esse prefixo é um PIN antigo em texto puro (instalações
/// anteriores à migração v20 do banco, ver `DatabaseHelper._onUpgrade`) e
/// continua sendo aceito por [confere] até ser migrado.
class PinSeguro {
  PinSeguro._();

  static const String _prefixo = 'pbkdf2';
  static const int _iteracoes = 20000;
  static const int _tamanhoSal = 16;
  static const int _tamanhoHash = 32;

  /// `true` se [valor] já está no formato de hash (não é texto puro).
  static bool ehHash(String? valor) =>
      valor != null && valor.startsWith('$_prefixo\$');

  /// Gera o hash com um sal novo para o [pin] digitado.
  static String gerarHash(String pin) {
    final aleatorio = Random.secure();
    final sal = List<int>.generate(_tamanhoSal, (_) => aleatorio.nextInt(256));
    final hash = _pbkdf2(utf8.encode(pin), sal, _iteracoes, _tamanhoHash);
    return '$_prefixo\$$_iteracoes\$${base64Encode(sal)}\$${base64Encode(hash)}';
  }

  /// Confere o [pinDigitado] contra o valor gravado ([armazenado]): hash
  /// (formato atual) ou texto puro (legado, antes da migração).
  static bool confere(String pinDigitado, String? armazenado) {
    if (armazenado == null || armazenado.isEmpty || pinDigitado.isEmpty) {
      return false;
    }
    if (!ehHash(armazenado)) {
      return _igualEmTempoConstante(utf8.encode(pinDigitado), utf8.encode(armazenado));
    }
    final partes = armazenado.split('\$');
    if (partes.length != 4) return false;
    final iteracoes = int.tryParse(partes[1]);
    if (iteracoes == null || iteracoes <= 0) return false;
    try {
      final sal = base64Decode(partes[2]);
      final esperado = base64Decode(partes[3]);
      final calculado =
          _pbkdf2(utf8.encode(pinDigitado), sal, iteracoes, esperado.length);
      return _igualEmTempoConstante(calculado, esperado);
    } catch (_) {
      return false;
    }
  }

  /// `null`/vazio = sem PIN cadastrado.
  static bool temPin(String? armazenado) =>
      armazenado != null && armazenado.trim().isNotEmpty;

  static List<int> _pbkdf2(List<int> senha, List<int> sal, int iteracoes, int tamanho) {
    final hmac = Hmac(sha256, senha);
    final resultado = <int>[];
    var bloco = 1;
    while (resultado.length < tamanho) {
      final entrada = [
        ...sal,
        (bloco >> 24) & 0xff,
        (bloco >> 16) & 0xff,
        (bloco >> 8) & 0xff,
        bloco & 0xff,
      ];
      var u = hmac.convert(entrada).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iteracoes; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      resultado.addAll(t);
      bloco++;
    }
    return resultado.sublist(0, tamanho);
  }

  static bool _igualEmTempoConstante(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diferenca = 0;
    for (var i = 0; i < a.length; i++) {
      diferenca |= a[i] ^ b[i];
    }
    return diferenca == 0;
  }
}
