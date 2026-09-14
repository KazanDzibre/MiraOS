import 'dart:io';

import 'package:flutter/widgets.dart';

import 'core/library_source.dart';
import 'core/mira_app.dart';
import 'core/mira_config.dart';
import 'jellyfin/jellyfin_client.dart';
import 'network/netbird_cli.dart';
import 'overseerr/discover_source.dart';
import 'overseerr/overseerr_client.dart';
import 'player/player_factory.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerPlaybackBackend();

  // With a server configured, use it. Without one, fall back to sample titles
  // so the shell still renders something diagnosable - first-run enrolment,
  // which is what will normally write this config, is designed but not built.
  final MiraConfig? config = await MiraConfig.load();

  final LibrarySource source;
  if (config != null && config.hasCredentials) {
    source = JellyfinLibrarySource(
      JellyfinClient(
        baseUrl: config.baseUrl,
        deviceId: 'mira-shell',
      ),
      username: config.username,
      password: config.password,
    );
  } else {
    source = const DemoLibrarySource();
  }

  // Seerr is optional and independent of Jellyfin: a box that can play but not
  // request is still a working box.
  final DiscoverSource? discover = config != null && config.hasOverseerr
      ? OverseerrDiscoverSource(
          OverseerrClient(baseUrl: config.overseerrUrl!, apiKey: config.overseerrApiKey!),
        )
      : null;

  // The box's own tunnel. A developer desktop has no netbird of Mira's to
  // manage, so there the top bar's address stays a plain label.
  final CliNetbird netbird = CliNetbird();
  final bool hasNetbird = File(netbird.executable).existsSync();

  runApp(MiraApp(source: source, discover: discover, netbird: hasNetbird ? netbird : null));
}
