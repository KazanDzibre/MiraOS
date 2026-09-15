// Lists the user's Jellyfin libraries and what is in them - read-only.
//
//   .toolchain/flutter/bin/dart run tool/probe_libraries.dart
//
// Credentials come from ~/.config/mira/dev-server.json and are never printed.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final Map<String, Object?> cfg = (jsonDecode(
          File('${Platform.environment['HOME']}/.config/mira/dev-server.json').readAsStringSync())
      as Map<Object?, Object?>)
      .cast<String, Object?>();
  final Uri base = Uri.parse(cfg['baseUrl']! as String);
  final HttpClient http = HttpClient();
  const String auth = 'MediaBrowser Client="Mira", Device="probe", DeviceId="mira-dev-probe", Version="0.1.0"';

  Future<Object?> send(String method, Uri uri, {Object? body, String? token}) async {
    final HttpClientRequest r = await http.openUrl(method, uri);
    r.headers.set('Authorization', token == null ? auth : '$auth, Token="$token"');
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    final HttpClientResponse res = await r.close();
    final String text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw 'HTTP ${res.statusCode} for ${uri.path}';
    return text.isEmpty ? null : jsonDecode(text);
  }

  final Map<String, Object?> login = (await send('POST', base.replace(path: '/Users/AuthenticateByName'),
          body: <String, Object?>{'Username': cfg['username'], 'Pw': cfg['password']}) as Map)
      .cast<String, Object?>();
  final String token = login['AccessToken']! as String;
  final String user = ((login['User']! as Map)['Id'])! as String;

  final Map<Object?, Object?> views =
      await send('GET', base.replace(path: '/Users/$user/Views'), token: token) as Map<Object?, Object?>;
  for (final Object? v in views['Items']! as List<Object?>) {
    final Map<Object?, Object?> m = v! as Map<Object?, Object?>;
    stdout.writeln('library: ${m['Name']}  type=${m['CollectionType']}  id=${m['Id']}');
    for (final String type in <String>['Movie', 'Series', 'Season', 'Episode']) {
      final Map<Object?, Object?> r = await send(
          'GET',
          base.replace(path: '/Users/$user/Items', queryParameters: <String, String>{
            'ParentId': m['Id']! as String,
            'IncludeItemTypes': type,
            'Recursive': 'true',
            'Limit': '2',
            'Fields': 'MediaSources',
          }),
          token: token) as Map<Object?, Object?>;
      final int n = r['TotalRecordCount']! as int;
      if (n == 0) continue;
      final List<Object?> items = r['Items']! as List<Object?>;
      final String sample = items
          .map((Object? i) {
            final Map<Object?, Object?> x = i! as Map<Object?, Object?>;
            return type == 'Episode'
                ? '${x['SeriesName']} S${x['ParentIndexNumber']}E${x['IndexNumber']}'
                : '${x['Name']}';
          })
          .join(' | ');
      stdout.writeln('  $type: $n   e.g. $sample');
    }
  }
  // Sign out this probe's session so it does not linger on the server.
  await send('POST', base.replace(path: '/Sessions/Logout'), token: token);
  http.close();
}
