import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

/// Base URL for the Security Check Backend server.
///
/// - Android emulator: use 10.0.2.2 to reach host machine's localhost
/// - iOS simulator: use 127.0.0.1 or localhost
/// - Physical device: use your machine's local network IP (e.g. 192.168.x.x)
const String kBaseUrl = 'http://10.0.2.2:8000';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  final http.Client _client = http.Client();

  /// Requests location permission and returns the current position.
  Future<Position> _getCurrentPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Serviço de localização desativado.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Permissão de localização negada.');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Permissão de localização negada permanentemente.');
    }

    return await Geolocator.getCurrentPosition();
  }

  /// Starts a cloud timer by calling POST /api/timer/start.
  ///
  /// Automatically fetches the current GPS coordinates and sends them
  /// along with the user's phone number, context hint, and duration.
  ///
  /// Returns a Map with the server response (message, expires_at, etc.).
  Future<Map<String, dynamic>> startCloudTimer({
    required String telefone,
    required String dicaContexto,
    required int minutos,
  }) async {
    // Get current GPS position
    final position = await _getCurrentPosition();

    final uri = Uri.parse('$kBaseUrl/api/timer/start');
    final body = {
      'telefone': telefone,
      'dica_contexto': dicaContexto,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'duracao_minutos': minutos,
    };

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      final errorBody = jsonDecode(response.body);
      throw Exception(
        errorBody['detail'] ?? 'Erro ao iniciar timer (${response.statusCode})',
      );
    }
  }

  /// Sends a check-in request to POST /api/timer/checkin.
  ///
  /// The server validates the PIN:
  ///   - Real PIN → trip completed
  ///   - Coercion PIN → silent panic activated
  ///
  /// Returns a Map with the server response (message, status, is_panic).
  Future<Map<String, dynamic>> sendCheckIn({
    required String telefone,
    required String pin,
  }) async {
    final uri = Uri.parse('$kBaseUrl/api/timer/checkin');
    final body = {
      'telefone': telefone,
      'pin': pin,
    };

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      final errorBody = jsonDecode(response.body);
      throw Exception(
        errorBody['detail'] ?? 'Erro no check-in (${response.statusCode})',
      );
    }
  }

  /// Health check — verifies if the backend is reachable.
  Future<bool> healthCheck() async {
    try {
      final uri = Uri.parse('$kBaseUrl/');
      final response = await _client.get(uri);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}