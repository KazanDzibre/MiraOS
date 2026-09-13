import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/library_source.dart';
import 'package:mira_shell/jellyfin/jellyfin_client.dart';

/// A stand-in Jellyfin that behaves like the real one where it matters here:
/// signing in again with the same device replaces the session, so any token
/// but the newest is refused with a 401.
class _FakeJellyfin {
  late final HttpServer _server;
  int signIns = 0;
  String? _validToken;

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((HttpRequest request) async {
      await utf8.decoder.bind(request).join();
      final HttpResponse response = request.response;
      response.headers.contentType = ContentType.json;

      if (request.uri.path == '/Users/AuthenticateByName') {
        signIns++;
        _validToken = 'token-$signIns';
        // Slow enough that two callers overlap, as they do over a tunnel.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        response.write(jsonEncode(<String, Object?>{
          'AccessToken': _validToken,
          'User': <String, Object?>{'Id': 'user-1'},
        }));
      } else {
        final String auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
        if (_validToken == null || !auth.contains('Token="$_validToken"')) {
          response.statusCode = HttpStatus.unauthorized;
        } else {
          response.write(jsonEncode(<String, Object?>{'Items': <Object?>[]}));
        }
      }
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  test('parallel Home loads share one sign-in', () async {
    final _FakeJellyfin server = _FakeJellyfin();
    await server.start();
    addTearDown(server.stop);

    final JellyfinLibrarySource source = JellyfinLibrarySource(
      JellyfinClient(baseUrl: server.baseUrl, deviceId: 'mira-test'),
      username: 'someone',
      password: 'secret',
    );

    // Exactly what _Root does on boot: both rails at once, before any sign-in.
    // Before the fix this signed in twice, the second sign-in revoked the
    // first token, and one rail failed with "Your sign-in is no longer valid".
    final Future<List<Object?>> both = Future.wait<Object?>(<Future<Object?>>[
      source.continueWatching(),
      source.recentlyAdded(),
    ]);
    await expectLater(both, completes);
    expect(server.signIns, 1, reason: 'concurrent callers each signed in');
  });
}
