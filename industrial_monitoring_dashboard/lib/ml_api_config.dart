/// Deployed Bearing Fault Prediction API base URL (no trailing slash).
///
/// Build/run with:
/// `flutter run --dart-define=ML_API_BASE_URL=https://your-host.example.com`
///
/// Android emulator talking to FastAPI on the dev machine often needs:
/// `http://10.0.2.2:8000` (or your PC's LAN IP) instead of `127.0.0.1`.
class MlApiConfig {
  MlApiConfig._();

  static const String embeddedBaseUrl = String.fromEnvironment(
    'ML_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
}
