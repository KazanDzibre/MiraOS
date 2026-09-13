import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterpi_gstreamer_video_player/flutterpi_gstreamer_video_player.dart';
import 'package:video_player/video_player.dart';

import 'mira_player.dart';

/// Playback inside the flutter-pi process: GStreamer decodes, frames arrive in
/// Flutter as a texture. This is DRM-master option 1 in CLAUDE.md - correct for
/// v1 precisely because there is exactly one graphical app.
///
/// Nothing outside lib/player/ may import video_player or flutter-pi's package;
/// swapping this backend must touch this directory and nothing else.
class GstreamerMiraPlayer implements MiraPlayer {
  final ValueNotifier<PlaybackStatus> _status =
      ValueNotifier<PlaybackStatus>(const PlaybackStatus());
  VideoPlayerController? _controller;

  /// Long enough for a server to start a transcode over the tunnel.
  static const Duration _openTimeout = Duration(seconds: 30);

  @override
  ValueListenable<PlaybackStatus> get status => _status;

  /// The GStreamer pipeline for a stream.
  ///
  /// Two deliberate departures from flutter-pi's default
  /// (`uridecodebin ! video/x-raw ! appsink`):
  ///
  ///  * **An audio branch.** The default has none and flutter-pi's volume call
  ///    is a stub, so without this every film plays in silence.
  ///  * **The URI is embedded.** flutter-pi only injects a URI into its default
  ///    pipeline, never into a custom one.
  ///
  /// `uridecodebin` autoplugs decoders. That is acceptable only in the VM, which
  /// has no hardware decoder to fall away from. On the Pi it is exactly the trap
  /// in CLAUDE.md (flutter-pi #224, #230): the rpi4 target must build explicit
  /// `v4l2slh265dec` / `v4l2h264dec` pipelines from the item's codec instead.
  /// That change belongs here and nowhere else.
  ///
  ///  * **A `videoconvert` before the appsink.** flutter-pi restricts the
  ///    appsink's caps to the formats EGL can import as DMA-BUF. A software
  ///    decoder outputs I420, and when that is not in the list the video pad
  ///    cannot link at all: GStreamer warns "delayed linking failed", the
  ///    pipeline never prerolls, and initialize() hangs with no error. Found in
  ///    the VM (H.264 High yuv420p, software decoded). On the Pi's V4L2 path
  ///    the decoder already emits an importable format and this is passthrough.
  static String pipelineFor(Uri source) {
    final String uri = source.toString().replaceAll('"', '%22');
    return 'uridecodebin uri="$uri" name="src" '
        'src. ! video/x-raw ! queue ! videoconvert ! appsink sync=true name="sink" '
        'src. ! audio/x-raw ! queue ! audioconvert ! audioresample ! autoaudiosink';
  }

  void _fail(String message, [Object? detail]) {
    // The raw reason goes to the console, where mirad's log makes it
    // diagnosable; the screen only ever gets a sentence.
    if (detail != null) debugPrint('mira player: $detail');
    _status.value = _status.value.copyWith(
      state: PlaybackState.failed,
      failure: message,
    );
  }

  void _onValue() {
    final VideoPlayerController? c = _controller;
    if (c == null) return;
    final VideoPlayerValue v = c.value;

    if (v.hasError) {
      _fail('This film stopped because the stream could not be decoded.',
          v.errorDescription);
      return;
    }

    final PlaybackState state;
    if (!v.isInitialized) {
      state = PlaybackState.opening;
    } else if (v.isCompleted) {
      state = PlaybackState.ended;
    } else if (v.isBuffering) {
      state = PlaybackState.buffering;
    } else if (v.isPlaying) {
      state = PlaybackState.playing;
    } else {
      state = PlaybackState.paused;
    }

    Duration buffered = Duration.zero;
    for (final DurationRange r in v.buffered) {
      if (r.end > buffered) buffered = r.end;
    }

    _status.value = PlaybackStatus(
      state: state,
      position: v.position,
      duration: v.duration,
      buffered: buffered,
    );
  }

  Future<void> _release() async {
    final VideoPlayerController? c = _controller;
    _controller = null;
    if (c == null) return;
    c.removeListener(_onValue);
    await c.dispose();
  }

  @override
  Future<void> open(Uri source, {Duration startAt = Duration.zero}) async {
    await _release();
    _status.value = PlaybackStatus(state: PlaybackState.opening, position: startAt);

    final VideoPlayerController controller =
        FlutterpiVideoPlayerController.withGstreamerPipeline(pipelineFor(source));
    _controller = controller;
    controller.addListener(_onValue);

    try {
      // A pipeline that never negotiates does not error - initialize simply
      // never returns, and the screen would wait forever. Found in the VM.
      await controller.initialize().timeout(_openTimeout);
      // Seek before the first play, so resuming never flashes the opening shot.
      if (startAt > Duration.zero) await controller.seekTo(startAt);
    } on TimeoutException {
      _fail('The stream did not start within ${_openTimeout.inSeconds} seconds.',
          'initialize() timed out; see GStreamer output on the serial console');
    } catch (e) {
      _fail('This film could not be opened.', e);
    }
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> seek(Duration to) async {
    final VideoPlayerController? c = _controller;
    if (c == null) return;
    final Duration max = c.value.duration;
    await c.seekTo(to < Duration.zero ? Duration.zero : (max > Duration.zero && to > max ? max : to));
  }

  @override
  Future<void> stop() async {
    await _release();
    _status.value = const PlaybackStatus();
  }

  @override
  Future<void> dispose() async {
    await _release();
    _status.dispose();
  }

  @override
  Widget buildView(BuildContext context) {
    final VideoPlayerController? c = _controller;
    if (c == null) return const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand());
    return ColoredBox(
      color: const Color(0xFF000000),
      child: Center(
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (BuildContext context, VideoPlayerValue v, Widget? _) {
            if (!v.isInitialized || v.aspectRatio <= 0) return const SizedBox.shrink();
            return AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(c));
          },
        ),
      ),
    );
  }
}
