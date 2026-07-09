import 'package:flutter_dotenv/flutter_dotenv.dart';

// P2P transfer backend config, sourced at runtime from the bundled `.env`.
//
// Values live in a git-ignored `.env` at the repo root (copy `.env.example`)
// and are loaded once in `main()` via `dotenv.load()`. In CI the file is
// written from GitHub secrets before the build. This file holds no secrets, so
// it is safe to commit.
//
// Until real values are provided, TransferConfig.isConfigured stays false and
// the transfer feature shows a "set up Firebase" hint instead of connecting.
class TransferConfig {
  /// Realtime Database URL,
  /// e.g. https://your-project-default-rtdb.firebaseio.com
  static String get rtdbUrl => dotenv.maybeGet('TRANSFER_RTDB_URL') ?? '';

  /// Firebase Web API key — used for anonymous sign-in via the Identity
  /// Toolkit REST endpoint (so RTDB security rules can scope by auth.uid).
  static String get apiKey => dotenv.maybeGet('TRANSFER_API_KEY') ?? '';

  /// True once real values have been provided via the `.env` file.
  static bool get isConfigured =>
      rtdbUrl.isNotEmpty &&
      apiKey.isNotEmpty &&
      !rtdbUrl.contains('YOUR_PROJECT') &&
      !apiKey.startsWith('YOUR_');
}
