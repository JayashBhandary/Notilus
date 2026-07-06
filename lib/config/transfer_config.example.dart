// Template for the P2P transfer backend config.
//
// SETUP: copy this file to `transfer_config.dart` (same folder) and fill in the
// two values from your Firebase project. `transfer_config.dart` is git-ignored;
// these secrets will move to GitHub secrets for CI later.
//
//   cp lib/config/transfer_config.example.dart lib/config/transfer_config.dart
//
// Where to find the values in the Firebase console:
//   * rtdbUrl → Realtime Database → the URL at the top of the Data tab.
//   * apiKey  → Project settings → General → "Web API Key".
class TransferConfig {
  /// Realtime Database URL,
  /// e.g. https://your-project-default-rtdb.firebaseio.com
  static const String rtdbUrl =
      'https://YOUR_PROJECT-default-rtdb.firebaseio.com';

  /// Firebase Web API key — used for anonymous sign-in via the Identity
  /// Toolkit REST endpoint (so RTDB security rules can scope by auth.uid).
  static const String apiKey = 'YOUR_WEB_API_KEY';

  /// True once real values have been filled in.
  static bool get isConfigured =>
      !rtdbUrl.contains('YOUR_PROJECT') && !apiKey.startsWith('YOUR_');
}
