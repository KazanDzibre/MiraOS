// Shows the JSON shape of series, seasons, episodes and next-up - read-only.
//
//   .toolchain/flutter/bin/dart run tool/probe_shows.dart
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
  String? token;

  Future<Object?> send(String method, String path, [Map<String, String>? q, Object? body]) async {
    final HttpClientRequest r = await http.openUrl(method, base.replace(path: path, queryParameters: q));
    r.headers.set('Authorization', token == null ? auth : '$auth, Token="$token"');
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    final HttpClientResponse res = await r.close();
    final String text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw 'HTTP ${res.statusCode} for $path';
    return text.isEmpty ? null : jsonDecode(text);
  }

  // Only the keys a UI would read, so the output stays short and has no paths.
  const Set<String> keep = <String>{
    'Name', 'Id', 'Type', 'SeriesName', 'SeriesId', 'SeasonId', 'IndexNumber', 'ParentIndexNumber',
    'ProductionYear', 'OfficialRating', 'RunTimeTicks', 'ChildCount', 'RecursiveItemCount', 'ImageTags',
    'BackdropImageTags', 'ParentBackdropImageTags', 'ParentBackdropItemId', 'SeriesPrimaryImageTag',
    'ParentThumbImageTag', 'ParentThumbItemId', 'PremiereDate', 'Status', 'EndDate', 'UserData', 'Genres',
  };
  String brief(Object? item) {
    final Map<Object?, Object?> m = item! as Map<Object?, Object?>;
    return jsonEncode(<Object?, Object?>{for (final MapEntry<Object?, Object?> e in m.entries) if (keep.contains(e.key)) e.key: e.value});
  }

  final Map<Object?, Object?> login = await send('POST', '/Users/AuthenticateByName', null,
      <String, Object?>{'Username': cfg['username'], 'Pw': cfg['password']}) as Map<Object?, Object?>;
  token = login['AccessToken']! as String;
  final String user = (login['User']! as Map<Object?, Object?>)['Id']! as String;
  try {
    const String anime = '0c41907140d802bb58430fed7e2cd79e';
    final Map<Object?, Object?> series = await send('GET', '/Users/$user/Items', <String, String>{
      'ParentId': anime, 'IncludeItemTypes': 'Series', 'Recursive': 'true', 'Limit': '1',
      'Fields': 'Overview,Genres,ChildCount,RecursiveItemCount',
    }) as Map<Object?, Object?>;
    final Object? s = (series['Items']! as List<Object?>).first;
    stdout.writeln('SERIES  ${brief(s)}');
    final String id = (s! as Map<Object?, Object?>)['Id']! as String;

    final Map<Object?, Object?> seasons = await send('GET', '/Shows/$id/Seasons',
        <String, String>{'userId': user, 'Fields': 'ChildCount'}) as Map<Object?, Object?>;
    for (final Object? x in seasons['Items']! as List<Object?>) {
      stdout.writeln('SEASON  ${brief(x)}');
    }
    final String firstSeason = ((seasons['Items']! as List<Object?>).first! as Map<Object?, Object?>)['Id']! as String;
    final Map<Object?, Object?> eps = await send('GET', '/Shows/$id/Episodes', <String, String>{
      'userId': user, 'seasonId': firstSeason, 'Fields': 'Overview', 'Limit': '2',
    }) as Map<Object?, Object?>;
    for (final Object? x in eps['Items']! as List<Object?>) {
      stdout.writeln('EPISODE ${brief(x)}');
    }
    final Map<Object?, Object?> next = await send('GET', '/Shows/NextUp',
        <String, String>{'userId': user, 'seriesId': id, 'Limit': '1'}) as Map<Object?, Object?>;
    stdout.writeln('NEXTUP  ${(next['Items']! as List<Object?>).map(brief).join(' ')}');
    final Map<Object?, Object?> resume = await send('GET', '/Users/$user/Items/Resume',
        <String, String>{'MediaTypes': 'Video', 'Limit': '20'}) as Map<Object?, Object?>;
    stdout.writeln('RESUME types: ${(resume['Items']! as List<Object?>).map((Object? i) => (i! as Map<Object?, Object?>)['Type']).toList()}');
  } finally {
    await send('POST', '/Sessions/Logout');
    http.close();
  }
}
