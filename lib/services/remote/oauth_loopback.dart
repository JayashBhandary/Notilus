import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'http_util.dart';
import 'remote_file_system.dart';

/// OAuth tokens for a remote source. The refresh token is the durable half and
/// is the only one that reaches the keychain; the access token lives in memory
/// for its hour.
class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 2)));
}

/// The desktop OAuth 2.0 flow, done the way Google (and everyone else) asks a
/// native app to do it: a loopback redirect plus PKCE.
///
/// The app opens the system browser at the provider's consent page with a
/// `http://127.0.0.1:<random port>` redirect, and holds a one-request HTTP
/// server on that port to catch the authorization code. Nothing is embedded,
/// nothing is proxied, and the code can't be intercepted by another local app
/// because it is worthless without the PKCE verifier this process generated.
class LoopbackOAuth {
  LoopbackOAuth({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret = '',
    this.scopes = const [],
    this.extraAuthParams = const {},
  });

  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String clientId;
  final String clientSecret;
  final List<String> scopes;
  final Map<String, String> extraAuthParams;

  /// How long the user gets to finish the consent screen before the loopback
  /// server gives up and stops holding a port open.
  static const Duration _timeout = Duration(minutes: 5);

  Future<OAuthTokens> authorize() async {
    if (clientId.isEmpty) {
      throw RemoteException('This source needs an OAuth client ID.');
    }
    final verifier = _randomUrlSafe(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');

    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    final redirectUri = 'http://127.0.0.1:${server.port}';

    final authUrl = Uri.parse(authorizationEndpoint).replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        ...extraAuthParams,
      },
    );

    final codeFuture = _waitForCode(server);
    final opened = await openInBrowser(authUrl);
    if (!opened) {
      unawaited(server.close(force: true));
      throw RemoteException(
        'Couldn\'t open a browser. Sign in manually at:\n$authUrl',
      );
    }

    final String code;
    try {
      code = await codeFuture.timeout(_timeout);
    } on TimeoutException {
      throw RemoteException('Sign-in timed out.');
    } finally {
      unawaited(server.close(force: true));
    }

    return _exchange({
      'client_id': clientId,
      if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
      'code': code,
      'code_verifier': verifier,
      'grant_type': 'authorization_code',
      'redirect_uri': redirectUri,
    });
  }

  Future<OAuthTokens> refresh(String refreshToken) => _exchange({
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      }, fallbackRefreshToken: refreshToken);

  Future<OAuthTokens> _exchange(
    Map<String, String> form, {
    String fallbackRefreshToken = '',
  }) async {
    final http = RemoteHttp();
    try {
      final body = utf8.encode(
        form.entries
            .map((e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&'),
      );
      final result = await http.sendText(
        'POST',
        Uri.parse(tokenEndpoint),
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        body: Stream.value(body),
        contentLength: body.length,
      );
      final json = result.body.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(result.body) as Map<String, dynamic>;
      if (result.status >= 300) {
        final description =
            json['error_description'] ?? json['error'] ?? 'HTTP ${result.status}';
        throw RemoteException('Sign-in failed: $description',
            statusCode: result.status);
      }
      final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
      return OAuthTokens(
        accessToken: '${json['access_token'] ?? ''}',
        refreshToken: '${json['refresh_token'] ?? fallbackRefreshToken}',
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      );
    } finally {
      http.close();
    }
  }

  Future<String> _waitForCode(HttpServer server) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;
      final code = params['code'];
      final error = params['error'];
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_resultPage(code != null));
      await request.response.close();
      if (error != null) {
        throw RemoteException('Sign-in was refused: $error');
      }
      if (code != null && code.isNotEmpty) return code;
    }
    throw RemoteException('Sign-in was cancelled.');
  }

  static String _resultPage(bool ok) => '''
<!doctype html><meta charset="utf-8">
<title>Notilus</title>
<style>
  body{font:15px -apple-system,Segoe UI,Roboto,sans-serif;display:grid;
       place-items:center;height:100vh;margin:0;color:#1c1c1e;background:#fff}
  @media (prefers-color-scheme:dark){body{background:#141416;color:#f2f2f7}}
  .card{text-align:center;max-width:22rem}
  h1{font-size:1.05rem;margin:0 0 .4rem}
  p{margin:0;opacity:.7}
</style>
<div class="card">
  <h1>${ok ? 'Connected to Notilus' : 'Sign-in didn’t complete'}</h1>
  <p>${ok ? 'You can close this tab and go back to the app.' : 'Close this tab and try again from Notilus.'}</p>
</div>
''';

  static String _randomUrlSafe(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}

/// Hands [url] to the system browser. Kept here rather than adding a plugin:
/// three one-line commands cover every desktop Notilus ships on.
Future<bool> openInBrowser(Uri url) async {
  try {
    if (Platform.isMacOS) {
      return (await Process.run('open', ['$url'])).exitCode == 0;
    }
    if (Platform.isWindows) {
      // `start` is a cmd builtin, and the empty string is the window title
      // argument — without it a quoted URL is taken as the title.
      return (await Process.run('cmd', ['/c', 'start', '', '$url'])).exitCode ==
          0;
    }
    if (Platform.isLinux) {
      return (await Process.run('xdg-open', ['$url'])).exitCode == 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
