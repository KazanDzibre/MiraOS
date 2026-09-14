// Checks that the server keeps Mira's per-film track choice.
//
// Writes "default audio, subtitles off" - what a film with nothing saved plays
// with anyway - for the first film in the library, then reads it back:
//
//   .toolchain/flutter/bin/dart run tool/probe_track_prefs.dart
//
// Credentials come from ~/.config/mira/dev-server.json and are never printed.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/core/track_choice.dart';
import 'package:mira_shell/jellyfin/jellyfin_client.dart';
import 'package:mira_shell/jellyfin/models.dart';

Future<void> main() async {
  final File cfgFile = File('${Platform.environment['HOME']}/.config/mira/dev-server.json');
  final Map<String, Object?> cfg =
      (jsonDecode(cfgFile.readAsStringSync()) as Map<Object?, Object?>).cast<String, Object?>();
  final JellyfinClient client = JellyfinClient(
    baseUrl: Uri.parse(cfg['baseUrl']! as String),
    deviceId: 'mira-dev-probe',
  );
  try {
    await client.authenticate(username: cfg['username']! as String, password: cfg['password']! as String);
    final MediaItem film = await client.item((await client.movies(limit: 1)).first.id);
    stdout.writeln('film:    ${film.name}');
    stdout.writeln('before:  ${await client.itemPrefs(film)}');

    await client.setItemPrefs(film, const TrackChoice().toPrefs());
    final Map<String, String> after = await client.itemPrefs(film);
    stdout.writeln('after:   $after');

    final TrackChoice back = TrackChoice.fromPrefs(after, film);
    final bool ok = after['audio'] == 'default' && after['subtitle'] == 'off' &&
        back.audio == null && back.subtitle == null;
    stdout.writeln(ok ? 'result:  stored and read back' : 'result:  NOT stored');
    exitCode = ok ? 0 : 1;
  } on JellyfinException catch (e) {
    stdout.writeln('failed:  ${e.message}');
    exitCode = 1;
  } finally {
    client.close();
  }
}
