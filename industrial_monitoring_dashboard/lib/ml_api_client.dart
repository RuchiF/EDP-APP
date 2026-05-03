import 'dart:convert';

import 'package:http/http.dart' as http;

/// Response from GET `/`
class MlHealthResponse {
  const MlHealthResponse({
    required this.status,
    required this.modelLoaded,
    required this.firestoreConnected,
    this.timestamp,
  });

  final String status;
  final bool modelLoaded;
  final bool firestoreConnected;
  final String? timestamp;

  factory MlHealthResponse.fromJson(Map<String, dynamic> json) {
    return MlHealthResponse(
      status: json['status']?.toString() ?? 'unknown',
      modelLoaded: json['model_loaded'] == true,
      firestoreConnected: json['firestore_connected'] == true,
      timestamp: json['timestamp']?.toString(),
    );
  }
}

/// Response from GET `/model/info`
class MlModelInfoResponse {
  const MlModelInfoResponse({
    required this.modelName,
    required this.balancedAccuracy,
    required this.f1Score,
    required this.nFeatures,
    required this.windowHours,
    required this.classes,
    this.trainingDate,
  });

  final String modelName;
  final double balancedAccuracy;
  final double f1Score;
  final int nFeatures;
  final int windowHours;
  final List<String> classes;
  final String? trainingDate;

  factory MlModelInfoResponse.fromJson(Map<String, dynamic> json) {
    final rawClasses = json['classes'];
    final classesList = rawClasses is List
        ? rawClasses.map((e) => e.toString()).toList(growable: false)
        : const <String>[];

    int? window = json['window_hours'] is int
        ? json['window_hours'] as int
        : int.tryParse(json['window_hours']?.toString() ?? '');
    window ??= 0;

    return MlModelInfoResponse(
      modelName: json['model_name']?.toString() ?? '—',
      balancedAccuracy: _toDouble(json['balanced_accuracy']) ?? 0,
      f1Score: _toDouble(json['f1_score']) ?? 0,
      nFeatures: json['n_features'] is int
          ? json['n_features'] as int
          : int.tryParse(json['n_features']?.toString() ?? '') ?? 0,
      windowHours: window,
      classes: classesList,
      trainingDate: json['training_date']?.toString(),
    );
  }
}

/// Response from GET/POST `/predict`
class MlPredictResponse {
  const MlPredictResponse({
    required this.prediction,
    required this.confidence,
    required this.probabilities,
    required this.windowHoursUsed,
    required this.rawReadingsFetched,
    this.timestamp,
  });

  final String prediction;
  final double confidence;
  final Map<String, double> probabilities;
  final int windowHoursUsed;
  final int rawReadingsFetched;
  final String? timestamp;

  factory MlPredictResponse.fromJson(Map<String, dynamic> json) {
    final rawProba = json['probabilities'];
    final map = <String, double>{};
    if (rawProba is Map) {
      for (final entry in rawProba.entries) {
        map[entry.key.toString()] = _toDouble(entry.value) ?? 0;
      }
    }
    return MlPredictResponse(
      prediction: json['prediction']?.toString() ?? 'UNKNOWN',
      confidence: _toDouble(json['confidence']) ?? 0,
      probabilities: map,
      windowHoursUsed: json['window_hours_used'] is int
          ? json['window_hours_used'] as int
          : int.tryParse(json['window_hours_used']?.toString() ?? '') ?? 0,
      rawReadingsFetched: json['raw_readings_fetched'] is int
          ? json['raw_readings_fetched'] as int
          : int.tryParse(json['raw_readings_fetched']?.toString() ?? '') ?? 0,
      timestamp: json['timestamp']?.toString(),
    );
  }
}

double? _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

String _normalizeBase(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return 'https://bearing-fault-predictor.onrender.com';
  return t.endsWith('/') ? t.substring(0, t.length - 1) : t;
}

Uri _uri(String base, String path, [Map<String, String>? query]) {
  final root = Uri.parse(_normalizeBase(base));
  final rel = path.startsWith('/') ? path : '/$path';
  final merged = root.resolve(rel);
  if (query == null || query.isEmpty) return merged;
  return merged.replace(queryParameters: query);
}

class MlApiException implements Exception {
  MlApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode != null ? 'MlApiException ($statusCode): $message' : 'MlApiException: $message';
}

class MlApiClient {
  MlApiClient({http.Client? httpClient}) : _client = httpClient ?? http.Client();

  final http.Client _client;

  void close() => _client.close();

  Future<MlHealthResponse> health(String baseUrl) async {
    final res = await _client.get(_uri(baseUrl, '/'));
    return _decodeJson(res, MlHealthResponse.fromJson);
  }

  Future<MlModelInfoResponse> modelInfo(String baseUrl) async {
    final res = await _client.get(_uri(baseUrl, '/model/info'));
    return _decodeJson(res, MlModelInfoResponse.fromJson);
  }

  Future<MlPredictResponse> predict(String baseUrl, {String? machineId}) async {
    final q = machineId != null && machineId.isNotEmpty
        ? <String, String>{'machine_id': machineId}
        : null;
    final res = await _client.get(_uri(baseUrl, '/predict', q));
    return _decodeJson(res, MlPredictResponse.fromJson);
  }

  Future<T> _decodeJson<T>(
    http.Response response,
    T Function(Map<String, dynamic> json) fromJson,
  ) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return Future.value(fromJson(decoded));
      }
      throw MlApiException('Unexpected JSON shape', statusCode: response.statusCode);
    }
    final detail = response.body.isNotEmpty ? response.body : 'Request failed';
    throw MlApiException(detail, statusCode: response.statusCode);
  }
}
