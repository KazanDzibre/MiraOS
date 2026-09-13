// Tests the DeviceProfile where it can actually be wrong: the edges.
//
// Direct-playing 1080p HEVC proves nothing - the envelope's risky claims are
// that H.264 above 1080p must transcode and that VP9/AV1 are never direct.
// This finds the most demanding files in the real library and checks the
// server's decision against ours on those.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/jellyfin/jellyfin_client.dart';
import 'package:mira_shell/jellyfin/models.dart';

Future<void> main() async {
  final Map<String, Object?> cfg = (jsonDecode(
    File('${Platform.environment['HOME']}/.config/mira/dev-server.json')
        .readAsStringSync(),
  ) as Map<Object?, Object?>)
      .cast<String, Object?>();

  final JellyfinClient client = JellyfinClient(
    baseUrl: Uri.parse(cfg['baseUrl']! as String),
    deviceId: 'mira-dev-probe',
  );

  try {
    await client.authenticate(
      username: cfg['username']! as String,
      password: cfg['password']! as String,
    );

    final List<MediaItem> all = await client.latest(limit: 400);
    stdout.writeln('scanned:  ${all.length} titles');

    final Map<String, int> byCodec = <String, int>{};
    final List<MediaItem> above1080 = <MediaItem>[];
    for (final MediaItem i in all) {
      final String key = (i.videoCodec ?? 'unknown').toLowerCase();
      byCodec[key] = (byCodec[key] ?? 0) + 1;
      if ((i.height ?? 0) > 1080 || (i.width ?? 0) > 1920) above1080.add(i);
    }
    stdout.writeln('codecs:   ${byCodec.entries.map((MapEntry<String, int> e) => '${e.key}=${e.value}').join('  ')}');
    stdout.writeln('above 1080p: ${above1080.length}');

    // The interesting ones: anything beyond 1080p, and anything in a codec the
    // Pi has no hardware for.
    final List<MediaItem> risky = <MediaItem>[
      ...above1080,
      ...all.where((MediaItem i) {
        final String c = (i.videoCodec ?? '').toLowerCase();
        return c == 'vp9' || c == 'av1' || c == 'mpeg2video' || c == 'vc1';
      }),
    ].toSet().toList();

    if (risky.isEmpty) {
      stdout.writeln('');
      stdout.writeln('No files beyond 1080p and none in VP9/AV1/MPEG-2/VC-1.');
      stdout.writeln('So this library cannot exercise the envelope edges, and');
      stdout.writeln('agreement here is NOT evidence the ceiling is right.');
      return;
    }

    stdout.writeln('');
    stdout.writeln('checking ${risky.length} demanding title(s) against the server:');
    int agree = 0, disagree = 0;
    for (final MediaItem i in risky.take(8)) {
      try {
        final PlaybackPlan plan = await client.planPlayback(i);
        final bool ours = i.likelyDirectPlay;
        final bool theirs = plan.isDirectPlay;
        final bool ok = ours == theirs;
        ok ? agree++ : disagree++;
        stdout.writeln('  ${ok ? 'agree   ' : 'DISAGREE'}  '
            '${i.videoCodec} ${i.width}x${i.height}  "${i.name}"');
        stdout.writeln('      server=${theirs ? 'DIRECT' : 'TRANSCODE'}  '
            'ours=${ours ? 'DIRECT' : 'TRANSCODE'}'
            '${plan.transcodeReasons.isEmpty ? '' : '  reasons=${plan.transcodeReasons.join(',')}'}');
      } on JellyfinException catch (e) {
        stdout.writeln('  error on "${i.name}": $e');
      }
    }
    stdout.writeln('');
    stdout.writeln('result:   $agree agree, $disagree disagree');
  } on JellyfinException catch (e) {
    stderr.writeln('jellyfin: $e');
    exit(1);
  } finally {
    client.close();
  }
}
