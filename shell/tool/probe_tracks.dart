// Exercises the library, genre and subtitle calls against the real server.
// Read-only: it never downloads a subtitle, which would spend the account's
// daily OpenSubtitles quota.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/jellyfin/jellyfin_client.dart';
import 'package:mira_shell/jellyfin/models.dart';

Future<void> main() async {
  final Map<String, Object?> cfg = (jsonDecode(
    File('${Platform.environment['HOME']}/.config/mira/dev-server.json').readAsStringSync(),
  ) as Map<Object?, Object?>)
      .cast<String, Object?>();
  final JellyfinClient c = JellyfinClient(
    baseUrl: Uri.parse(cfg['baseUrl']! as String),
    deviceId: 'mira-dev-probe',
  );
  try {
    await c.authenticate(username: cfg['username']! as String, password: cfg['password']! as String);
    stdout.writeln('movies:     ${await c.movieCount()}');
    final List<MediaItem> page = await c.movies(limit: 10);
    stdout.writeln('first page: ${page.map((MediaItem m) => m.name).take(4).join(' | ')}');
    final List<GenreCount> genres = await c.movieGenres();
    stdout.writeln('genres:     ${genres.length} -> ${genres.take(4).map((GenreCount g) => '${g.name} ${g.count}').join(', ')}');
    stdout.writeln('drama:      ${await c.movieCount(genre: 'Drama')} (by count)');

    final List<MediaItem> all = await c.movies(limit: 500);
    final MediaItem lotr = await c.item(all.firstWhere((MediaItem m) => m.name.contains('Fellowship')).id);
    stdout.writeln('item:       ${lotr.name}');
    stdout.writeln('  source:   ${lotr.mediaSourceId == null ? 'MISSING' : 'ok'}; providers ${lotr.providerIds.keys.join(',')}');
    stdout.writeln('  audio:    ${lotr.audioTracks.length}  subtitles: ${lotr.subtitleTracks.length} '
        '(${lotr.subtitleTracks.where((MediaTrack t) => t.isTextBased).length} text, '
        '${lotr.subtitleTracks.where((MediaTrack t) => !t.isTextBased).length} bitmap)');

    final List<RemoteSubtitle> srp = await c.searchSubtitles(lotr, 'srp');
    stdout.writeln('remote srp: ${srp.length}; best: ${srp.isEmpty ? '-' : '${srp.first.name.substring(0, 40)}… (${srp.first.downloads} dl)'}');

    final MediaTrack text = lotr.subtitleTracks.firstWhere((MediaTrack t) => t.isTextBased);
    final String vtt = await c.subtitleText(lotr, text);
    stdout.writeln('vtt:        ${vtt.length} bytes, header ok: ${vtt.replaceFirst('﻿', '').startsWith('WEBVTT')}');

    final MediaTrack commentary = lotr.audioTracks.firstWhere((MediaTrack t) => !t.isDefault);
    final PlaybackPlan plain = await c.planPlayback(lotr);
    final PlaybackPlan withCommentary = await c.planPlayback(lotr, audioStreamIndex: commentary.index);
    stdout.writeln('plan:       default audio -> ${plain.isDirectPlay ? 'DIRECT PLAY' : 'TRANSCODE/REMUX'}');
    stdout.writeln('plan:       audio #${commentary.index} -> ${withCommentary.isDirectPlay ? 'DIRECT PLAY (track choice ignored!)' : 'REMUX'}; '
        'url ${withCommentary.streamUrl.path} (query hidden)');
  } on JellyfinException catch (e) {
    stderr.writeln('jellyfin: $e');
    exit(1);
  } finally {
    c.close();
  }
}
