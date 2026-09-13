// Parses the real server's subtitle output with the shell's own WebVTT reader.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/jellyfin/jellyfin_client.dart';
import 'package:mira_shell/jellyfin/models.dart';
import 'package:mira_shell/player/webvtt.dart';

Future<void> main() async {
  final Map<String, Object?> cfg = (jsonDecode(
    File('${Platform.environment['HOME']}/.config/mira/dev-server.json').readAsStringSync(),
  ) as Map<Object?, Object?>)
      .cast<String, Object?>();
  final JellyfinClient c = JellyfinClient(baseUrl: Uri.parse(cfg['baseUrl']! as String), deviceId: 'mira-dev-probe');
  try {
    await c.authenticate(username: cfg['username']! as String, password: cfg['password']! as String);
    final List<MediaItem> all = await c.movies(limit: 500);
    for (final String title in <String>['Fellowship', 'Hair']) {
      final MediaItem item = await c.item(all.firstWhere((MediaItem m) => m.name.contains(title)).id);
      final MediaTrack track = item.subtitleTracks.firstWhere((MediaTrack t) => t.isTextBased);
      final Subtitles subs = Subtitles.parseWebVtt(await c.subtitleText(item, track));
      final Duration probe = item.resumePosition > Duration.zero ? item.resumePosition : const Duration(minutes: 10);
      stdout.writeln('${item.name}');
      stdout.writeln('  track:  #${track.index} ${track.codec} (${track.language})');
      stdout.writeln('  cues:   ${subs.cues.length}; first at ${subs.cues.first.start}: "${subs.cues.first.text.replaceAll('\n', ' / ')}"');
      int shown = 0;
      for (int s = 0; s < 120; s += 2) {
        if (subs.textAt(probe + Duration(seconds: s)) != null) shown++;
      }
      stdout.writeln('  around ${probe.inMinutes}m: text on screen in $shown of 60 samples');
    }
  } on JellyfinException catch (e) {
    stderr.writeln('jellyfin: $e');
    exit(1);
  } finally {
    c.close();
  }
}
