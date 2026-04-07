import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';

/// HTTP client for the FlutterPlaza Code Push server.
///
/// When [pinnedCertificatePath] is provided, TLS certificate pinning is
/// enabled. Only connections to servers presenting a certificate that chains
/// to the pinned certificate will be trusted. This prevents MITM attacks
/// even if a rogue CA issues a certificate for the server domain.
class CodePushClient {
  CodePushClient({String? serverUrl, String? pinnedCertificatePath})
      : _serverUrl = serverUrl ?? Constants.codePushDefaultServer,
        _http = _createHttpClient(pinnedCertificatePath);

  final String _serverUrl;
  final HttpClient _http;

  /// Creates an [HttpClient] with optional certificate pinning.
  static HttpClient _createHttpClient(String? pinnedCertificatePath) {
    if (pinnedCertificatePath == null) {
      return HttpClient();
    }
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificates(pinnedCertificatePath);
    return HttpClient(context: context);
  }

  /// Read the stored pinned certificate path from ~/.flutter_compilerc.
  static Future<String?> getPinnedCertificatePath() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    return F.readValueForKeyFromRcConfig(
      rcFile,
      Constants.codePushPinnedCertKey,
    );
  }

  /// Store pinned certificate path in ~/.flutter_compilerc.
  static Future<void> storePinnedCertificatePath(String path) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcFile,
      Constants.codePushPinnedCertKey,
      path,
    );
  }

  /// Read the stored auth token from ~/.flutter_compilerc.
  static Future<String?> getStoredToken() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    return F.readValueForKeyFromRcConfig(rcFile, Constants.codePushTokenKey);
  }

  /// Read the stored server URL from ~/.flutter_compilerc (or use default).
  static Future<String> getServerUrl() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    final url = await F.readValueForKeyFromRcConfig(
      rcFile,
      Constants.codePushServerKey,
    );
    return url ?? Constants.codePushDefaultServer;
  }

  /// Read the stored app ID from ~/.flutter_compilerc.
  static Future<String?> getAppId() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    return F.readValueForKeyFromRcConfig(rcFile, Constants.codePushAppIdKey);
  }

  /// Store auth token in ~/.flutter_compilerc.
  static Future<void> storeToken(String token) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(rcFile, Constants.codePushTokenKey, token);
  }

  /// Store server URL in ~/.flutter_compilerc.
  static Future<void> storeServerUrl(String url) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(rcFile, Constants.codePushServerKey, url);
  }

  /// Store app ID in ~/.flutter_compilerc.
  static Future<void> storeAppId(String appId) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(rcFile, Constants.codePushAppIdKey, appId);
  }

  static Future<void> storeSigningKey(String path) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcFile,
      Constants.codePushSigningKeyKey,
      path,
    );
  }

  static Future<String?> getStoredSigningKey() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    return F.readValueForKeyFromRcConfig(
      rcFile,
      Constants.codePushSigningKeyKey,
    );
  }

  /// Clear stored credentials.
  static Future<void> clearCredentials() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(rcFile, Constants.codePushTokenKey, '');
  }

  /// POST /api/v1/auth/login — exchange API key for JWT.
  Future<Map<String, dynamic>> login(String apiKey) async {
    return _post('/api/v1/auth/login', body: {'api_key': apiKey});
  }

  /// POST /api/v1/auth/register — create a new account.
  Future<Map<String, dynamic>> register({
    required String email,
    String? name,
  }) async {
    return _post('/api/v1/auth/register', body: {
      'email': email,
      if (name != null) 'name': name,
    });
  }

  /// GET /api/v1/account — get user profile and subscription status.
  Future<Map<String, dynamic>> getAccount(String token) async {
    return _get('/api/v1/account', token: token);
  }

  /// GET /api/v1/releases?app_id=...
  Future<Map<String, dynamic>> listReleases({
    required String token,
    required String appId,
  }) async {
    return _get('/api/v1/releases?app_id=$appId', token: token);
  }

  /// POST /api/v1/releases — create a release (upload baseline).
  Future<Map<String, dynamic>> createRelease({
    required String token,
    required String appId,
    required String version,
    required List<int> snapshotData,
  }) async {
    return _post(
      '/api/v1/releases',
      token: token,
      body: {
        'app_id': appId,
        'version': version,
        'snapshot': base64Encode(snapshotData),
      },
    );
  }

  /// GET /api/v1/patches?release_id=...
  Future<Map<String, dynamic>> listPatches({
    required String token,
    required String releaseId,
  }) async {
    return _get('/api/v1/patches?release_id=$releaseId', token: token);
  }

  /// POST /api/v1/patches — upload a patch.
  Future<Map<String, dynamic>> createPatch({
    required String token,
    required String releaseId,
    required List<int> patchData,
    int rolloutPercentage = 100,
    String channel = 'production',
  }) async {
    return _post(
      '/api/v1/patches',
      token: token,
      body: {
        'release_id': releaseId,
        'patch': base64Encode(patchData),
        'rollout_percentage': rolloutPercentage,
        'channel': channel,
      },
    );
  }

  /// POST /api/v1/patches/rollback — deactivate a patch.
  Future<Map<String, dynamic>> rollbackPatch({
    required String token,
    required String patchId,
  }) async {
    return _post(
      '/api/v1/patches/rollback',
      token: token,
      body: {'patch_id': patchId},
    );
  }

  /// GET /api/v1/releases/{id}/snapshot -- download the baseline snapshot.
  Future<List<int>?> downloadBaseline({
    required String token,
    required String releaseId,
  }) async {
    // First get the release info to find the snapshot URL.
    final info =
        await _get('/api/v1/releases?release_id=$releaseId', token: token);
    final releases = info['releases'] as List?;
    if (releases == null || releases.isEmpty) return null;

    final release = releases.first as Map<String, dynamic>;
    final snapshotUrl = release['snapshot_url'] as String?;
    if (snapshotUrl == null) return null;

    // Download the snapshot bytes.
    final uri = Uri.parse(snapshotUrl);
    final request = await _http.getUrl(uri);
    if (token.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    final response = await request.close();
    if (response.statusCode != 200) return null;

    final chunks = <List<int>>[];
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return chunks.expand((c) => c).toList();
  }

  /// Fetch the server's encryption public key (cached in .flutter_compilerc).
  Future<String?> getServerPublicKey({required String token}) async {
    // Check cache first.
    final cached = await _getCachedServerKey();
    if (cached != null) return cached;

    final result = await _get('/api/v1/encryption/public-key', token: token);
    final key = result['public_key'] as String?;
    if (key != null && key.isNotEmpty) {
      await _cacheServerKey(key);
    }
    return key;
  }

  /// POST /api/v1/compile — compile Dart source to a patch.
  ///
  /// If the server's encryption key is available, source is encrypted
  /// in transit using RSA+AES hybrid encryption.
  Future<Map<String, dynamic>> compile({
    required String token,
    required String releaseId,
    required String source,
    required String platform,
    bool validateOnly = false,
  }) async {
    // Try to encrypt the source before sending.
    final serverKey = await getServerPublicKey(token: token);

    if (serverKey != null) {
      final encrypted = await _encryptSource(source, serverKey);
      if (encrypted != null) {
        return _post(
          '/api/v1/compile',
          token: token,
          body: {
            'release_id': releaseId,
            'platform': platform,
            'validate_only': validateOnly,
            ...encrypted,
          },
        );
      }
    }

    // Fallback: send plaintext (server may not support encryption).
    return _post(
      '/api/v1/compile',
      token: token,
      body: {
        'release_id': releaseId,
        'source': source,
        'platform': platform,
        'validate_only': validateOnly,
      },
    );
  }

  /// Encrypt source code with AES-256-CBC, then wrap the AES key with RSA.
  ///
  /// Returns a map with `encrypted_source`, `encrypted_key`, and `iv`,
  /// all base64-encoded. Returns null if encryption fails (openssl missing).
  Future<Map<String, String>?> _encryptSource(
    String source,
    String serverPublicKeyPem,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync('fcp_encrypt_');
    try {
      // 1. Generate random AES-256 key (32 bytes) and IV (16 bytes).
      final random = Random.secure();
      final aesKey =
          Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
      final iv =
          Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));

      final aesKeyHex =
          aesKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final ivHex =
          iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // 2. Write source to temp file and encrypt with AES-256-CBC.
      final sourceFile = File('${tempDir.path}/source.dart');
      sourceFile.writeAsStringSync(source);
      final encryptedFile = '${tempDir.path}/source.enc';

      final aesResult = Process.runSync('openssl', [
        'enc', '-aes-256-cbc',
        '-in', sourceFile.path,
        '-out', encryptedFile,
        '-K', aesKeyHex,
        '-iv', ivHex,
      ]);
      if (aesResult.exitCode != 0) return null;

      // 3. Encrypt the AES key with the server's RSA public key.
      final pubKeyFile = File('${tempDir.path}/server_pub.pem');
      pubKeyFile.writeAsStringSync(serverPublicKeyPem);

      final aesKeyFile = File('${tempDir.path}/aes_key.bin');
      aesKeyFile.writeAsBytesSync(aesKey);
      final encryptedKeyFile = '${tempDir.path}/aes_key.enc';

      final rsaResult = Process.runSync('openssl', [
        'pkeyutl', '-encrypt',
        '-pubin',
        '-inkey', pubKeyFile.path,
        '-in', aesKeyFile.path,
        '-out', encryptedKeyFile,
      ]);
      if (rsaResult.exitCode != 0) return null;

      // 4. Base64-encode everything.
      return {
        'encrypted_source':
            base64Encode(File(encryptedFile).readAsBytesSync()),
        'encrypted_key':
            base64Encode(File(encryptedKeyFile).readAsBytesSync()),
        'iv': base64Encode(iv),
      };
    } catch (_) {
      return null;
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }

  /// Read the cached server public key from .flutter_compilerc.
  /// The PEM key is stored as base64 to avoid multi-line issues in the
  /// line-based config format.
  static Future<String?> _getCachedServerKey() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    final encoded = await F.readValueForKeyFromRcConfig(
      rcFile,
      Constants.codePushServerPublicKeyKey,
    );
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return utf8.decode(base64Decode(encoded));
    } catch (_) {
      return null; // Corrupted cache — will re-fetch.
    }
  }

  /// Cache the server public key as base64 in .flutter_compilerc.
  static Future<void> _cacheServerKey(String key) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    final encoded = base64Encode(utf8.encode(key));
    await F.writeKeyValueToRcConfig(
      rcFile,
      Constants.codePushServerPublicKeyKey,
      encoded,
    );
  }

  // --- HTTP helpers ---

  Future<Map<String, dynamic>> _get(
    String path, {
    String? token,
  }) async {
    final uri = Uri.parse('$_serverUrl$path');
    final request = await _http.getUrl(uri);
    if (token != null) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    request.headers.set('Accept', 'application/json');
    final response = await request.close();
    return _parseResponse(response);
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_serverUrl$path');
    final request = await _http.postUrl(uri);
    if (token != null) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Accept', 'application/json');
    if (body != null) {
      request.write(json.encode(body));
    }
    final response = await request.close();
    return _parseResponse(response);
  }

  Future<Map<String, dynamic>> _parseResponse(
      HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    if (body.isEmpty) {
      return {'status_code': response.statusCode};
    }
    final parsed = json.decode(body);
    if (parsed is Map<String, dynamic>) {
      return {'status_code': response.statusCode, ...parsed};
    }
    return {'status_code': response.statusCode, 'data': parsed};
  }

  void close() => _http.close();
}
