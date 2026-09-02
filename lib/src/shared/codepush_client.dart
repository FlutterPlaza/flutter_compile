import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';

/// Verdict of the cheap pre-flight session probe
/// ([CodePushClient.checkSession]).
enum SessionCheck {
  /// The server accepted the stored login.
  valid,

  /// The server rejected the login itself (401) — the operator must log
  /// in again, and logging in again is what fixes it.
  expired,

  /// The login was recognized but the account is not allowed to make the
  /// call (403) — a plan, quota, or permission limit. Deliberately NOT
  /// [expired]: this repo maps 401 to "session expired" and 403 to
  /// "plan/quota/permission" everywhere else (`_codepush_release.dart`,
  /// `_codepush_apps.dart`, `_codepush_patch.dart`), and telling an
  /// operator whose plan lapsed to log in again sends them at the one
  /// action that cannot help.
  denied,

  /// Nothing was learned (offline, timeout, a 5xx, an old server). This
  /// NEVER blocks a run: a probe that exists to save a wasted build must
  /// not become a second way for the build to be refused.
  unknown,
}

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
    // One connect deadline for EVERY call site: without it a stalled
    // connect can hang the 'Uploading patch' spinner forever AFTER
    // the whole build/sign pipeline (readTargetRelease's explicit
    // timeout becomes a backstop rather than the only deadline).
    // Connect-only, so a slow-but-progressing large upload is never
    // cut off.
    const connectDeadline = Duration(seconds: 30);
    if (pinnedCertificatePath == null) {
      return HttpClient()..connectionTimeout = connectDeadline;
    }
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificates(pinnedCertificatePath);
    return HttpClient(context: context)..connectionTimeout = connectDeadline;
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

  /// The config file name, shared by the machine-wide copy in `$HOME`
  /// and the per-project copy beside `pubspec.yaml`.
  static const String rcFileName = '.flutter_compilerc';

  /// The per-project config file for [from] (default: the process's
  /// current directory), or null when no project root is found.
  ///
  /// A project root is the nearest ancestor directory holding a
  /// `pubspec.yaml` — the same anchor `pubspec.lock` and `.dart_tool`
  /// use, so a command run from `lib/` or `test/` resolves the same
  /// file as one run from the project root. The file need not exist:
  /// callers read it defensively and [storeAppId] creates it.
  ///
  /// Never throws: a deleted current directory, an unreadable ancestor,
  /// or a pathological depth all degrade to null, which puts the caller
  /// back on the machine-wide file it used before per-project state
  /// existed.
  static File? projectRcFile({Directory? from}) {
    try {
      var dir = from ?? Directory.current;
      // Bounded so a symlink cycle or a degenerate path cannot spin a
      // CLI startup path; 64 is far past any real checkout depth.
      for (var depth = 0; depth < 64; depth++) {
        if (File('${dir.path}/pubspec.yaml').existsSync()) {
          return File('${dir.path}/$rcFileName');
        }
        final parent = dir.parent;
        if (parent.path == dir.path) return null;
        dir = parent;
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Read the app ID for the current project.
  ///
  /// Project-local `.flutter_compilerc` FIRST, then the machine-wide
  /// `~/.flutter_compilerc`. The home file is the LEGACY location: it
  /// holds exactly ONE id for the whole machine, so `fcp codepush init`
  /// in a second app used to repoint the first — silently, because
  /// every upload succeeds against the wrong app and only the devices
  /// running the right one notice (they never get the patch).
  ///
  /// The fallback is what keeps existing single-project setups working:
  /// nothing writes a project file until an id is stored for that
  /// project, so a machine set up before this split keeps resolving the
  /// id it always did.
  static Future<String?> getAppId({Directory? projectDir}) async {
    final projectRc = projectRcFile(from: projectDir);
    if (projectRc != null) {
      final local = await F.readValueForKeyFromRcConfig(
        projectRc,
        Constants.codePushAppIdKey,
      );
      // Present-but-blank reads as "not set here" and falls through: an
      // empty value is what a hand-edited or half-written file leaves,
      // and inheriting the machine-wide id is strictly better than
      // resolving to nothing.
      if (local != null && local.trim().isNotEmpty) return local;
    }
    return getMachineAppId();
  }

  /// Read the machine-wide (legacy) app ID from `~/.flutter_compilerc`,
  /// ignoring any project-local file. Separate from [getAppId] so the
  /// commands can SAY that a machine-wide id exists — the fact behind
  /// the two-projects-one-machine trap — without re-deriving where the
  /// value came from.
  static Future<String?> getMachineAppId() async {
    final home = F.homeDir();
    final rcFile = File('$home/$rcFileName');
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

  /// Store the app ID for the current project, returning the path
  /// written so the caller can name it instead of guessing.
  ///
  /// Writes the PROJECT-LOCAL `.flutter_compilerc` whenever a project
  /// root exists — that is the whole fix for the machine-wide id: a
  /// second app's `init` now writes its own file instead of overwriting
  /// the first app's. Outside a project there is no anchor to hang the
  /// value on, so the machine-wide file stays the target.
  static Future<String> storeAppId(String appId,
      {Directory? projectDir}) async {
    final projectTarget = projectRcFile(from: projectDir);
    final machineFile = File('${F.homeDir()}/$rcFileName');
    final target = projectTarget ?? machineFile;
    await F.writeKeyValueToRcConfig(target, Constants.codePushAppIdKey, appId);
    if (projectTarget != null) {
      // Mirror into the machine-wide file as a FALLBACK for callers
      // that resolve without a working directory — today the IDE
      // extensions and any daemon RPC not passing `directory`. For
      // those callers this is exactly the pre-project-file behavior
      // (last init wins), so nothing regresses while the project file
      // stays authoritative for every cwd-aware path; the shadowing
      // advisory names the machine value whenever it is overridden.
      // Follow-up to remove the need for this: thread cwd through the
      // IDE extensions' CLI invocations.
      await F.writeKeyValueToRcConfig(
          machineFile, Constants.codePushAppIdKey, appId);
    }
    return target.path;
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

  /// Read the stored Flutter engine version from ~/.flutter_compilerc.
  ///
  /// Written by `fcp codepush setup` when the user installs engine
  /// artifacts for a specific Flutter version. Used as a fallback for
  /// `codepush patch --build` / `codepush release --build` when
  /// `--flutter-version` isn't passed and `flutter --version` can't be
  /// resolved from PATH.
  static Future<String?> getStoredEngineFlutterVersion() async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    return F.readValueForKeyFromRcConfig(
      rcFile,
      Constants.codePushEngineVersionKey,
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

  /// Classifies an account-probe status code into a [SessionCheck].
  /// Static and public so the rule is testable without an HTTP seam
  /// (the [releaseFromListing] precedent): only an EXPLICIT rejection
  /// may read as [SessionCheck.expired] — a 5xx, a redirect, or a null
  /// (offline/timeout/parse surprise) is [SessionCheck.unknown],
  /// because refusing a build on a flaky network would be a worse
  /// failure than the one this prevents.
  ///
  /// 401 and 403 are kept apart on purpose. They are two different
  /// problems with two different fixes, and the rest of this CLI
  /// already splits them that way — folding 403 in here would answer a
  /// lapsed plan with "run `fcp codepush login`".
  static SessionCheck sessionCheckForStatus(int? statusCode) {
    if (statusCode == null) return SessionCheck.unknown;
    if (statusCode == 401) return SessionCheck.expired;
    if (statusCode == 403) return SessionCheck.denied;
    if (statusCode >= 200 && statusCode < 300) return SessionCheck.valid;
    return SessionCheck.unknown;
  }

  /// Cheap pre-flight: does the stored login still work?
  ///
  /// Callers run this BEFORE a build so a dead session costs a round
  /// trip instead of the whole build — the failure used to surface only
  /// at the upload, after several minutes of compiling. Best-effort by
  /// construction: any outcome that is not an explicit rejection is
  /// [SessionCheck.unknown] and the caller continues.
  Future<SessionCheck> checkSession({
    required String token,
    // Short on purpose: this is an optional saving, not a gate. The
    // client-wide connect deadline (30 s) is the backstop for a stalled
    // CONNECT; this one additionally bounds a server that accepts and
    // then stalls, and expires into "unknown" either way.
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final result = await getAccount(token).timeout(timeout);
      final status = result['status_code'];
      return sessionCheckForStatus(status is int ? status : null);
    } catch (_) {
      return SessionCheck.unknown;
    }
  }

  /// GET /api/v1/releases?app_id=...
  Future<Map<String, dynamic>> listReleases({
    required String token,
    required String appId,
  }) async {
    // Same encoding rule as releaseQueryPath — user-supplied ids
    // must never reshape the query.
    return _get(
      '/api/v1/releases?app_id=${Uri.encodeQueryComponent(appId)}',
      token: token,
    );
  }

  /// POST /api/v1/releases — upload a release baseline.
  ///
  /// Sends the raw baseline bytes as a gzipped `application/octet-stream`
  /// body with metadata in query parameters, matching the upload path
  /// [createPatch] uses. Requires a server that supports the
  /// octet-stream release handler; older servers only accept the legacy
  /// JSON body path.
  ///
  /// [flutterVersion] is the Flutter SDK version this release was built
  /// with — required for server-side patch compilation.
  /// [interfaceFreeze] / [extendableWidgets] attest whether the iOS
  /// baseline was built with the interface freeze / widget guarding.
  /// Null means unknown and is NOT sent — an old server ignores the
  /// params either way, and absent must never read as "off".
  Future<Map<String, dynamic>> createRelease({
    required String token,
    required String appId,
    required String version,
    required List<int> snapshotData,
    String? flutterVersion,
    String? baselineId,
    bool? interfaceFreeze,
    bool? extendableWidgets,
  }) async {
    return _postBinary(
      '/api/v1/releases',
      token: token,
      bytes: snapshotData,
      queryParams: releaseQueryParams(
        appId: appId,
        version: version,
        flutterVersion: flutterVersion,
        baselineId: baselineId,
        interfaceFreeze: interfaceFreeze,
        extendableWidgets: extendableWidgets,
      ),
    );
  }

  /// The query params [createRelease] sends. Extracted (and static)
  /// so the null-is-ABSENT contract is testable without an HTTP seam:
  /// a null must drop the key entirely — serializing it would send the
  /// literal string "null", which the server's tri-state parse reads
  /// as a definite value, the exact shape unknown-is-not-false exists
  /// to prevent.
  static Map<String, String> releaseQueryParams({
    required String appId,
    required String version,
    String? flutterVersion,
    String? baselineId,
    bool? interfaceFreeze,
    bool? extendableWidgets,
  }) {
    return {
      'app_id': appId,
      'version': version,
      if (flutterVersion != null) 'flutter_version': flutterVersion,
      if (baselineId != null) 'baseline_id': baselineId,
      if (interfaceFreeze != null)
        'interface_freeze': interfaceFreeze.toString(),
      if (extendableWidgets != null)
        'extendable_widgets': extendableWidgets.toString(),
    };
  }

  /// Get a release's JSON by id, or null when it does not exist or
  /// the server is unreachable — best-effort by design, so callers
  /// (the patch flow) degrade to their local fallbacks instead of
  /// failing the command on a metadata read.
  Future<Map<String, dynamic>?> getRelease({
    required String token,
    required String releaseId,
  }) async {
    try {
      final info = await _get(
        releaseQueryPath(releaseId),
        token: token,
      );
      return releaseFromListing(info, releaseId);
    } catch (_) {
      return null;
    }
  }

  /// The GET path for a single-release lookup. Encoded: a space/&/#
  /// in a mistyped id must surface as release-not-found, not as a
  /// malformed URI that the caller's warn misreads as a session or
  /// connectivity problem. Extracted (and static) so the encoding
  /// cannot silently vanish — the POST side's releaseQueryParams
  /// precedent. Public for tests.
  static String releaseQueryPath(String releaseId) =>
      '/api/v1/releases?release_id=${Uri.encodeQueryComponent(releaseId)}';

  /// Picks the requested release out of a listing response, or null.
  /// SEARCHES the whole list rather than trusting index 0: every
  /// hardened read the caller makes on this map (guarding verdicts,
  /// the stored baseline hash) presumes the map IS the release the
  /// user named, and a server that ignored the `release_id` filter —
  /// an unparseable id treated as an absent optional, a filter
  /// regression, a cached list — most plausibly answers with the
  /// app's FULL release list, wanted record included. A positional
  /// match is just the special case of an id match. Assumes the
  /// record's id key is `id` (the server's Release JSON; also what
  /// the status and release commands read). Shape-tolerant on every
  /// step — this helper is public precisely so callers without an
  /// HTTP seam can use it, so it must not inherit-a-throw from a
  /// surprise shape. Static so the filtering is testable directly.
  static Map<String, dynamic>? releaseFromListing(
    Map<String, dynamic> info,
    String releaseId,
  ) {
    // UUIDs are case-insensitive identifiers: an upcased or padded
    // --release-id must not turn a correct answer into "no release"
    // (which would silence the guard warning AND drop the stored
    // baseline hash) when a server matches it anyway.
    final wanted = releaseId.trim().toLowerCase();
    final releases = info['releases'];
    if (releases is! List) return null;
    for (final release in releases) {
      if (release is Map<String, dynamic> &&
          release['id']?.toString().trim().toLowerCase() == wanted) {
        return release;
      }
    }
    return null;
  }

  /// GET /api/v1/patches?release_id=...
  Future<Map<String, dynamic>> listPatches({
    required String token,
    required String releaseId,
  }) async {
    // Same encoding rule as releaseQueryPath — the same
    // user-supplied id flows here from the status command.
    return _get(
      '/api/v1/patches?release_id=${Uri.encodeQueryComponent(releaseId)}',
      token: token,
    );
  }

  /// POST /api/v1/patches — upload a patch.
  ///
  /// Sends the raw patch bytes as a gzipped `application/octet-stream`
  /// body with metadata in query parameters. This avoids the ~33 %
  /// base64 blow-up of the legacy JSON-body upload path, which was
  /// hitting Cloud Run's hard 32 MiB request body limit on any
  /// moderately-sized iOS patch (Dart kernel for a typical Flutter
  /// app is ~37 MiB uncompressed, but ~11 MiB gzipped). Requires
  /// code-push-server with the matching octet-stream handler; older
  /// servers (pre-2026-04-10) only accept the JSON body path.
  ///
  /// [signature] is the base64-encoded RSA-SHA256 signature over the raw
  /// patch bytes. Required if the app has a public key registered on the
  /// server; ignored for grandfathered apps (but still recommended so
  /// that enabling enforcement later is painless).
  ///
  /// [baselineHash] is the hex-encoded SHA-256 of the `App.framework/App`
  /// (iOS) or `libapp.so` (Android) file the patch was built against.
  /// The server records it per-patch and the SDK compares it against the
  /// running baseline's hash before loading, to reject patches whose
  /// package-level Dart class layout doesn't match. Optional: omitting
  /// it downgrades the SDK to its coarser engine-ABI check.
  Future<Map<String, dynamic>> createPatch({
    required String token,
    required String releaseId,
    required List<int> patchData,
    int rolloutPercentage = 100,
    String channel = 'production',
    String? signature,
    String? baselineHash,
  }) async {
    return _postBinary(
      '/api/v1/patches',
      token: token,
      bytes: patchData,
      queryParams: {
        'release_id': releaseId,
        'rollout_percentage': rolloutPercentage.toString(),
        'channel': channel,
        if (signature != null) 'signature': signature,
        if (baselineHash != null) 'baseline_hash': baselineHash,
      },
    );
  }

  /// POST /api/v1/apps — create a new app, optionally registering the
  /// RSA public key that future patches will be signed with.
  ///
  /// Passing [publicKeyPem] at create time enables server-side signature
  /// enforcement immediately. Omit it for manual registration via
  /// [registerAppPublicKey] later.
  Future<Map<String, dynamic>> createApp({
    required String token,
    required String name,
    String? platform,
    String? publicKeyPem,
  }) async {
    return _post(
      '/api/v1/apps',
      token: token,
      body: {
        'name': name,
        if (platform != null) 'platform': platform,
        if (publicKeyPem != null) 'public_key': publicKeyPem,
      },
    );
  }

  /// PATCH /api/v1/apps — register or rotate the RSA public key used to
  /// verify patch signatures for an existing (grandfathered) app.
  ///
  /// After this call succeeds, the server will reject any unsigned or
  /// invalid-signature patch for this app.
  Future<Map<String, dynamic>> registerAppPublicKey({
    required String token,
    required String appId,
    required String publicKeyPem,
  }) async {
    return _patch(
      '/api/v1/apps',
      token: token,
      body: {
        'app_id': appId,
        'public_key': publicKeyPem,
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
      final ivHex = iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

      // 2. Write source to temp file and encrypt with AES-256-CBC.
      final sourceFile = File('${tempDir.path}/source.dart');
      sourceFile.writeAsStringSync(source);
      final encryptedFile = '${tempDir.path}/source.enc';

      final aesResult = Process.runSync('openssl', [
        'enc',
        '-aes-256-cbc',
        '-in',
        sourceFile.path,
        '-out',
        encryptedFile,
        '-K',
        aesKeyHex,
        '-iv',
        ivHex,
      ]);
      if (aesResult.exitCode != 0) return null;

      // 3. Encrypt the AES key with the server's RSA public key.
      final pubKeyFile = File('${tempDir.path}/server_pub.pem');
      pubKeyFile.writeAsStringSync(serverPublicKeyPem);

      final aesKeyFile = File('${tempDir.path}/aes_key.bin');
      aesKeyFile.writeAsBytesSync(aesKey);
      final encryptedKeyFile = '${tempDir.path}/aes_key.enc';

      final rsaResult = Process.runSync('openssl', [
        'pkeyutl',
        '-encrypt',
        '-pubin',
        '-inkey',
        pubKeyFile.path,
        '-in',
        aesKeyFile.path,
        '-out',
        encryptedKeyFile,
      ]);
      if (rsaResult.exitCode != 0) return null;

      // 4. Base64-encode everything.
      return {
        'encrypted_source': base64Encode(File(encryptedFile).readAsBytesSync()),
        'encrypted_key': base64Encode(File(encryptedKeyFile).readAsBytesSync()),
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

  Future<Map<String, dynamic>> _patch(
    String path, {
    String? token,
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$_serverUrl$path');
    final request = await _http.openUrl('PATCH', uri);
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

  /// POST a binary body (no base64, no JSON envelope) with query
  /// parameters for metadata. Gzips the body on the wire via
  /// `Content-Encoding: gzip` so large payloads (e.g. iOS Dart
  /// kernel files) fit under the upstream frontend's request body
  /// limit — Cloud Run caps request bodies at 32 MiB, and a typical
  /// Flutter app's `.dill` is around 37 MiB uncompressed but
  /// ~11 MiB gzipped.
  Future<Map<String, dynamic>> _postBinary(
    String path, {
    String? token,
    required List<int> bytes,
    Map<String, String>? queryParams,
  }) async {
    final qs = (queryParams == null || queryParams.isEmpty)
        ? ''
        : '?${queryParams.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
    final uri = Uri.parse('$_serverUrl$path$qs');
    final request = await _http.postUrl(uri);
    if (token != null) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    request.headers.set('Content-Type', 'application/octet-stream');
    request.headers.set('Content-Encoding', 'gzip');
    request.headers.set('Accept', 'application/json');
    final gzipped = gzip.encode(bytes);
    request.headers.contentLength = gzipped.length;
    request.add(gzipped);
    final response = await request.close();
    return _parseResponse(response);
  }

  Future<Map<String, dynamic>> _parseResponse(
      HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    return parseResponseBody(
      response.statusCode,
      body,
      contentType: response.headers.contentType?.mimeType ?? '',
    );
  }

  /// The pure body→map step of response parsing. Public for tests:
  /// the invariants here — every branch carries the real int HTTP
  /// status, and a body's own status_code key can never override it
  /// — are what let every caller read status_code `as int`.
  static Map<String, dynamic> parseResponseBody(
    int statusCode,
    String body, {
    String contentType = '',
  }) {
    if (body.isEmpty) {
      return {'status_code': statusCode};
    }

    // Check Content-Type before trying to decode as JSON. Upstream
    // HTTP errors (Cloud Run 413 "Request Entity Too Large", nginx
    // 502, Google Frontend 500) return HTML or text bodies; calling
    // json.decode on them throws FormatException and surfaces a
    // cryptic `Unexpected character (at line 2, character 1)` to
    // the user instead of the actual HTTP status. Fall back to a
    // readable excerpt of the raw body when the response isn't JSON.
    final looksLikeJson = contentType.toLowerCase().contains('json') ||
        body.trimLeft().startsWith('{');
    if (!looksLikeJson) {
      // Trim and excerpt so a 60 KB HTML page doesn't drown the
      // user's terminal.
      final trimmed = body.trim();
      final excerpt = trimmed.length > 200
          ? '${trimmed.substring(0, 200).replaceAll(RegExp(r'\s+'), ' ')}…'
          : trimmed.replaceAll(RegExp(r'\s+'), ' ');
      return {
        'status_code': statusCode,
        'error': 'HTTP $statusCode (non-JSON response)',
        'message': excerpt,
      };
    }

    try {
      final parsed = json.decode(body);
      if (parsed is Map<String, dynamic>) {
        // Spread FIRST: every caller trusts status_code to be the
        // real HTTP status (and reads it `as int`), so a body that
        // carries its own status_code key — an ordinary REST
        // envelope shape — must never override it.
        return {...parsed, 'status_code': statusCode};
      }
      return {'status_code': statusCode, 'data': parsed};
    } on FormatException catch (e) {
      // Defensive: content-type said JSON but the body wasn't valid.
      final excerpt = body.length > 200 ? '${body.substring(0, 200)}…' : body;
      return {
        'status_code': statusCode,
        'error': 'HTTP $statusCode (malformed JSON)',
        'message': '${e.message}: $excerpt',
      };
    }
  }

  /// The post-201 shape rule as a function: a response value that is
  /// not a JSON object reads as null, so callers degrade to their
  /// visible skipped-record paths instead of throwing after the
  /// server row exists. Public for tests.
  static Map<String, dynamic>? asJsonMap(Object? value) =>
      value is Map<String, dynamic> ? value : null;

  void close({bool force = false}) => _http.close(force: force);
}
