/// Deployed Bearing Fault Prediction API base URL (no trailing slash).
///
/// Build/run with:
/// `flutter run --dart-define=ML_API_BASE_URL=https://your-host.example.com`
///
/// Default points to the Render deployment. For local dev, override with:
/// `flutter run --dart-define=ML_API_BASE_URL=http://10.0.2.2:8000`  (Android emulator)
/// `flutter run --dart-define=ML_API_BASE_URL=http://127.0.0.1:8000`  (desktop/web)
class MlApiConfig {
  MlApiConfig._();

  static const String embeddedBaseUrl = String.fromEnvironment(
    'ML_API_BASE_URL',
    defaultValue: 'https://bearing-fault-predictor.onrender.com',
  );
}
