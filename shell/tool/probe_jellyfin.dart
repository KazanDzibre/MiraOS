// Exercises the real JellyfinClient against a real server.
//
// Runs as plain Dart - the client deliberately depends only on dart:io, so it
// can be validated without building or running the UI:
//
//   .toolchain/flutter/bin/dart run tool/probe_jellyfin.dart
//
// Credentials come from ~/.config/mira/dev-server.json and are never printed.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/jellyfin/device_profile.dart';
import 'package:mira_shell/jellyfin/jellyfin_client.dart';
import 'package:mira_shell/jellyfin/models.dart';

Future<void> main() async {
  final File cfgFile = File(
    '${Platform.environment['HOME']}/.config/mira/dev-server.json',
  );
  if (!cfgFile.existsSync()) {
    stderr.writeln('no config at ${cfgFile.path}');
    exit(2);
  }

  final Map<String, Object?> cfg =
      (jsonDecode(cfgFile.readAsStringSync()) as Map<Object?, Object?>)
          .cast<String, Object?>();
  final Uri baseUrl = Uri.parse(cfg['baseUrl']! as String);

  final JellyfinClient client = JellyfinClient(
    baseUrl: baseUrl,
    deviceId: 'mira-dev-probe',
  );

  try {
    stdout.writeln('server:     $baseUrl');
    await client.authenticate(
      username: cfg['username']! as String,
      password: cfg['password']! as String,
    );
    stdout.writeln('auth:       ok (userId ${client.userId?.substring(0, 8)}…)');

    final List<MediaItem> resume = await client.resume();
    stdout.writeln('resume:     ${resume.length} item(s)');
    for (final MediaItem i in resume.take(5)) {
      stdout.writeln('  - ${i.name} (${i.productionYear ?? '-'})  '
          '${i.videoCodec ?? '?'} ${i.width ?? 0}x${i.height ?? 0}  '
          'resume ${i.resumePosition.inMinutes}m  '
          '${i.likelyDirectPlay ? 'DIRECT' : 'TRANSCODE'}');
    }

    final List<MediaItem> latest = await client.latest(limit: 12);
    stdout.writeln('latest:     ${latest.length} item(s)');

    // The important bit: does the DeviceProfile make the right call on real
    // files? Anything the Pi cannot decode must come back as a transcode.
    int direct = 0, transcode = 0;
    final List<MediaItem> sample = <MediaItem>[...resume, ...latest];
    for (final MediaItem i in sample) {
      i.likelyDirectPlay ? direct++ : transcode++;
    }
    stdout.writeln('envelope:   $direct would direct-play, '
        '$transcode would transcode (by our own rules)');

    if (sample.isNotEmpty) {
      final MediaItem probe = sample.first;
      final PlaybackPlan plan = await client.planPlayback(probe);
      stdout.writeln('playbackinfo for "${probe.name}":');
      stdout.writeln('  server says: ${plan.isDirectPlay ? 'DIRECT PLAY' : 'TRANSCODE'}');
      if (plan.transcodeReasons.isNotEmpty) {
        stdout.writeln('  reasons:     ${plan.transcodeReasons.join(', ')}');
      }
      stdout.writeln('  our guess:   ${probe.likelyDirectPlay ? 'DIRECT PLAY' : 'TRANSCODE'}'
          '${plan.isDirectPlay == probe.likelyDirectPlay ? '  (agrees)' : '  (DISAGREES)'}');
      // Never print the URL: it carries an api_key.
      stdout.writeln('  stream url:  ${plan.streamUrl.path} (query hidden)');
    }

    final int profileBytes =
        jsonEncode(JellyfinDeviceProfile.build()).length;
    stdout.writeln('profile:    $profileBytes bytes sent to the server');
  } on JellyfinException catch (e) {
    stderr.writeln('jellyfin: $e');
    exit(1);
  } finally {
    client.close();
  }
}
