import 'dart:io';

import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';

import 'fake_player.dart';
import 'gstreamer_player.dart';
import 'mira_player.dart';

/// The one place that knows which playback backend exists.
///
/// `MIRA_PLATFORM` is exported by the image's launcher
/// (buildroot-external/package/mira-shell/mira-shell.sh). A desktop run, a
/// widget test or a golden never sees it, so none of them tries to reach
/// GStreamer - there would be nothing on the far side of the channel.
bool get runningUnderFlutterPi =>
    Platform.environment['MIRA_PLATFORM'] == 'flutter-pi';

/// Call once in main, before runApp.
void registerPlaybackBackend() {
  if (runningUnderFlutterPi) FlutterpiVideoPlayer.registerWith();
}

MiraPlayer createPlayer() =>
    runningUnderFlutterPi ? GstreamerMiraPlayer() : FakeMiraPlayer();
