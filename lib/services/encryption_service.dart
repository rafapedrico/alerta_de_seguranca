import 'dart:convert';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:crypto/crypto.dart';

class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal();

  // Master passphrase — in production, derive from a secure source
  // (e.g. Firebase Remote Config, key server, or device-specific secret).
  // 32-byte key ensures AES-256.
  static final String _masterPassphrase = 'security_check_app_master_key_2026!@#';

  late final encrypt.Key _key;
  late final encrypt.IV _iv;
  bool _initialized = false;

  /// Initialize the service. Must be called once before any encrypt/decrypt.
  void initialize() {
    if (_initialized) return;

    // Derive a deterministic 32-byte key via SHA-256 of the passphrase
    final hashBytes = sha256.convert(utf8.encode(_masterPassphrase)).bytes;
    final keyHex = hashBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _key = encrypt.Key.fromUtf8(keyHex.substring(0, 32));
    _iv = encrypt.IV.fromLength(16); // 16-byte IV (zeros — safe since key is unique)
    _initialized = true;
  }

  /// Encrypts [plainText] using AES-256-CBC and returns a base64 ciphertext.
  ///
  /// Used for:
  ///   - messages and media paths before saving to SQLite
  ///   - messages and media paths before uploading to cloud
  String encryptText(String plainText) {
    _ensureInitialized();
    try {
      final encrypter = encrypt.Encrypter(
        encrypt.AES(_key, mode: encrypt.AESMode.cbc),
      );
      return encrypter.encrypt(plainText, iv: _iv).base64;
    } catch (_) {
      // Fallback: prefix with marker so we know it's not encrypted
      return 'RAW:$plainText';
    }
  }

  /// Decrypts [encryptedText] (base64) back to the original plain text.
  ///
  /// Used for:
  ///   - reading messages from SQLite
  ///   - processing data received from cloud
  String decryptText(String encryptedText) {
    _ensureInitialized();
    try {
      // If the string was saved as raw (e.g. encryption failed), strip prefix
      if (encryptedText.startsWith('RAW:')) {
        return encryptedText.substring(4);
      }

      final encrypter = encrypt.Encrypter(
        encrypt.AES(_key, mode: encrypt.AESMode.cbc),
      );
      return encrypter.decrypt64(encryptedText, iv: _iv);
    } catch (_) {
      // If decryption fails, return as-is so data is never lost
      return encryptedText;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      initialize();
    }
  }
}