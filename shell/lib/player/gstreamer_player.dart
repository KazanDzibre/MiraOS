import 'dart:async';
import 'dart:io';

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

  /// The frame format asked of the appsink.
  ///
  /// NV12 wherever a V4L2 decoder exists, because that is what the Pi's
  /// hardware decoder emits and it arrives as a dmabuf flutter-pi can import
  /// without a copy. BGRA otherwise, because a *software* decoder's frames are
  /// ordinary memory and flutter-pi's copy path can only build a GBM buffer
  /// out of an RGB format - with NV12 there, vc4's GBM refuses the allocation
  /// and every frame is dropped, which looks like a black picture with working
  /// sound (found on the box, 2026-10-05).
  ///
  /// MIRA_VIDEO_FORMAT overrides, for measuring on the box.
  static String get videoFormat {
    final String? chosen = Platform.environment['MIRA_VIDEO_FORMAT'];
    if (chosen != null && chosen.isNotEmpty) return chosen;
    return hasV4l2Decoder ? 'NV12' : 'BGRA';
  }

  /// Whether this box has the Pi's V4L2 M2M H.264 decoder.
  ///
  /// `/dev/video10` is bcm2835-codec's decode node. Testing for the device
  /// rather than for "am I a Pi" keeps the two targets running the same code:
  /// the VM has no such node and falls back to the software pipeline, which is
  /// what it should do. MIRA_HWDEC forces it either way for experiments.
  static bool get hasV4l2Decoder {
    final String? forced = Platform.environment['MIRA_HWDEC'];
    if (forced != null && forced.isNotEmpty) return forced != '0';
    return File('/dev/video10').existsSync();
  }

  /// A whole pipeline, for bring-up experiments on the real box.
  ///
  /// `{uri}` and `{format}` are substituted. Trying a pipeline over ssh beats
  /// rebuilding the bundle for each one.
  static String? get pipelineOverride {
    final String? template = Platform.environment['MIRA_PIPELINE'];
    return template == null || template.isEmpty ? null : template;
  }

  /// The demuxer chain for a stream, by container, ending in the element the
  /// branches below link to (`name=d`).
  ///
  /// Only three containers can arrive, and that is the DeviceProfile's doing:
  /// it direct-plays H.264 in mp4 and mkv and takes everything else as an HLS
  /// transcode. Adding a container to the profile without adding it here
  /// yields a stream the box cannot open, which is why both carry a comment
  /// pointing at the other.
  static String? _demuxFor(Uri source) {
    final String path = source.path.toLowerCase();
    if (path.endsWith('.m3u8')) {
      // Jellyfin's transcode. hlsdemux fetches the segments; they are MPEG-TS
      // because the profile asks for SegmentContainer=ts.
      return 'hlsdemux ! tsdemux name=d';
    }
    if (path.endsWith('.mkv') || path.endsWith('.webm')) {
      return 'matroskademux name=d';
    }
    if (path.endsWith('.mp4') || path.endsWith('.m4v') || path.endsWith('.mov')) {
      return 'qtdemux name=d';
    }
    if (path.endsWith('.ts') || path.endsWith('.mpegts')) {
      return 'tsdemux name=d';
    }
    return null;
  }

  /// The GStreamer pipeline for a stream.
  ///
  /// Two shapes, chosen by whether a hardware decoder exists.
  ///
  /// **The Pi: explicit, hardware, zero-copy.** `v4l2h264dec` is named rather
  /// than auto-plugged, which is the trap in CLAUDE.md (flutter-pi #224, #230)
  /// and also a hard requirement rather than a preference: the decoder hands
  /// over MMAP buffers unless told `capture-io-mode=dmabuf`, and a property
  /// cannot be set on an element `uridecodebin` auto-plugged. Measured on the
  /// box, 2026-10-05, all three on the same film: software decode 89% of a
  /// core, auto-plugged hardware decode with the frame copy 31%, this pipeline
  /// 12% with two dropped frames. A server-transcoded HLS stream through the
  /// same pipeline: 10% and no drops.
  ///
  /// **A queue per branch, and they are load-bearing.** A demuxer pushes every
  /// branch from one streaming thread, so without them the first sink blocks
  /// its thread waiting to preroll while the other branch is never fed, and
  /// the pipeline deadlocks: both pads negotiate caps, "Pipeline is
  /// PREROLLING" is the last thing printed, and `initialize()` hangs until the
  /// 30 s timeout with no error anywhere. Found exactly that way on the box
  /// against a real transcode.
  ///
  /// **The VM: `uridecodebin`, software, BGRA.** Acceptable only because there
  /// is no hardware decoder to fall away from; see `videoFormat` and the
  /// `videoconvert` note below for why the format is named.
  ///
  /// Both shapes end their audio branch the same way, and all three caps there
  /// are load-bearing:
  ///
  ///  * **channels=2** - without it a 5.1 or 7.1 film reaches ALSA with every
  ///    channel, and the `default` device's plug plugin converts to stereo with
  ///    its COPY route policy: front left to left, front right to right, every
  ///    other channel dropped (alsa-lib pcm_plug.c). Dialogue lives in the
  ///    centre channel, so films played their music and effects with no
  ///    voices. audioconvert's downmix folds the centre and surrounds in.
  ///    Found 2026-09-14; nearly every film in the library is 5.1 or 7.1.
  ///  * **format=S16LE, rate=48000** - the Pi's HDMI audio is an IEC958
  ///    device: it takes 48 kHz 16-bit stereo and refuses anything else
  ///    outright (ALSA -524, ENOTSUPP), which surfaced only as "Could not open
  ///    audio device for playback" and a film that played in silence. Whether
  ///    it happened depended on the film's own sample rate, which is why it
  ///    worked on one title and not the next (found on the box, 2026-10-05).
  ///
  /// The URI is embedded because flutter-pi only injects one into its own
  /// default pipeline, never into a custom one.
  /// [hardware] overrides the `/dev/video10` probe, so tests can exercise the
  /// Pi's pipelines on a machine that has no V4L2 decoder.
  /// The decoder element and parser for a codec, or null when the box has no
  /// hardware path for it.
  ///
  /// HEVC goes through `v4l2slh265dec`, the stateless decoder on
  /// `/dev/video19`, which decodes 1080p at 3% of a core - against 89% in
  /// software. It only became reachable once GStreamer was taught the Pi's
  /// SAND capture formats; see the patch under buildroot-external/patches.
  static ({String parse, String dec})? _decoderFor(String? videoCodec) {
    switch (videoCodec?.toLowerCase()) {
      case 'h264':
      case 'avc':
        return (parse: 'h264parse', dec: 'v4l2h264dec capture-io-mode=dmabuf');
      case 'hevc':
      case 'h265':
        return (parse: 'h265parse', dec: 'v4l2slh265dec');
      default:
        return null;
    }
  }

  static String pipelineFor(Uri source, {String? format, bool? hardware, String? videoCodec}) {
    final String uri = source.toString().replaceAll('"', '%22');
    final bool useHardware = hardware ?? hasV4l2Decoder;
    final String chosenFormat =
        format ?? (hardware == null ? videoFormat : (useHardware ? 'NV12' : 'BGRA'));
    final String? override = pipelineOverride;
    if (override != null) {
      return override
          .replaceAll('{uri}', uri)
          .replaceAll('{format}', chosenFormat);
    }

    final String? demux = useHardware ? _demuxFor(source) : null;
    // H.264 unless told otherwise: a transcode is always H.264, and that is
    // what the DeviceProfile asks for when it cannot direct-play.
    final ({String parse, String dec})? decoder =
        _decoderFor(videoCodec ?? 'h264');
    if (demux == null || decoder == null) {
      // No hardware decoder, or a container this pipeline does not know. The
      // software path plays it rather than failing outright.
      return 'uridecodebin uri="$uri" name="src" '
          'src. ! video/x-raw ! queue ! videoconvert ! video/x-raw,format=$chosenFormat ! appsink sync=true name="sink" '
          'src. ! audio/x-raw ! queue ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,channels=2,rate=48000 ! autoaudiosink';
    }

    // Two seconds of each stream, counted in time rather than buffers so a
    // high-bitrate film does not quietly get a shorter queue than a low one.
    const String queue =
        'queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000';
    final bool hevc = decoder.parse == 'h265parse';
    // The decoder's own output format is left to negotiation for HEVC: it
    // only ever produces Broadcom's SAND layout, and naming a linear format
    // here would simply fail to link.
    final String videoCaps = hevc ? '' : 'video/x-raw,format=$chosenFormat ! ';
    return 'souphttpsrc location="$uri" retries=3 timeout=15 ! $demux '
        'd. ! video/x-${hevc ? 'h265' : 'h264'} ! $queue ! ${decoder.parse} ! '
        '${decoder.dec} ! '
        '$videoCaps' 'appsink sync=true name="sink" '
        'd. ! audio/mpeg ! $queue ! aacparse ! avdec_aac ! '
        'audioconvert ! audioresample ! '
        'audio/x-raw,format=S16LE,channels=2,rate=48000 ! autoaudiosink';
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
  Future<void> open(Uri source, {Duration startAt = Duration.zero, String? videoCodec}) async {
    await _release();
    _status.value = PlaybackStatus(state: PlaybackState.opening, position: startAt);

    final VideoPlayerController controller =
        FlutterpiVideoPlayerController.withGstreamerPipeline(
            pipelineFor(source, videoCodec: videoCodec));
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
