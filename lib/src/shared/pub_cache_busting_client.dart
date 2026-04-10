import 'package:http/http.dart' as http;

/// HTTP client that appends a cache-busting query parameter and no-cache
/// headers to every request, so pub.dev CDN edges cannot serve a stale
/// package-metadata response immediately after a publish.
///
/// Background: `pub_updater` calls `GET https://pub.dev/api/packages/<name>`
/// to look up the latest version. That endpoint is fronted by Google Cloud
/// CDN with a short but non-zero TTL. Right after publishing, two
/// back-to-back CLI invocations can get different answers — the first
/// hitting a stale edge node (reporting the *previous* latest) and the
/// second hitting a freshly-invalidated one. Users saw
/// `flutter_compile update` report "already at latest version" while the
/// very next command's banner said "Update available!".
///
/// This client fixes that by:
///   1. Appending `_cb=<microsecond-timestamp>` to the URL — Cloud CDN keys
///      its cache on the full URL including query, so every request is a
///      miss.
///   2. Setting `Cache-Control: no-cache, no-store, max-age=0` and
///      `Pragma: no-cache` — a belt-and-suspenders hint for any other
///      intermediate cache.
///
/// The client is a thin wrapper: pass an instance to `PubUpdater()` and
/// everything else works unchanged.
class PubCacheBustingClient extends http.BaseClient {
  PubCacheBustingClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final bustedUri = request.url.replace(
      queryParameters: {
        ...request.url.queryParameters,
        '_cb': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );
    final bustedRequest = _cloneRequest(request, bustedUri);
    return _inner.send(bustedRequest);
  }

  http.BaseRequest _cloneRequest(http.BaseRequest original, Uri newUrl) {
    final req = http.Request(original.method, newUrl)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;
    req.headers.addAll(original.headers);
    req.headers['cache-control'] = 'no-cache, no-store, max-age=0';
    req.headers['pragma'] = 'no-cache';
    if (original is http.Request) {
      req.bodyBytes = original.bodyBytes;
    }
    return req;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
