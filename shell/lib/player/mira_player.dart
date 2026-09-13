import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Where playback currently is. Deliberately coarse: the UI should never need
/// to know more than this, and every extra state is a chance for backend
/// detail to leak through.
enum PlaybackState {
  idle,
  opening,
  buffering,
  playing,
  paused,
  ended,

  /// Playback failed. [PlaybackStatus.failure] carries a sentence a person can
  /// read from the couch - never an exception string.
  failed,
}

@immutable
class PlaybackStatus {
  const PlaybackStatus({
    this.state = PlaybackState.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.failure,
  });

  final PlaybackState state;
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final String? failure;

  bool get isPlaying => state == PlaybackState.playing;
  bool get isActive =>
      state == PlaybackState.playing ||
      state == PlaybackState.paused ||
      state == PlaybackState.buffering;

  double get progress {
    final int total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  PlaybackStatus copyWith({
    PlaybackState? state,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    String? failure,
  }) {
    return PlaybackStatus(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      failure: failure ?? this.failure,
    );
  }
}

/// The playback firewall.
///
/// v1 decodes in-process: flutter-pi holds DRM master, so a separate player
/// process cannot have the screen, and GStreamer hands Flutter frames as a
/// zero-copy external texture instead. That is correct for v1 precisely
/// because there is exactly one graphical app.
///
/// The moment a second one exists, that stops working and the backend becomes
/// a compositor or a process hand-off. **Swapping it must touch one file, not
/// the UI** - so nothing about GStreamer, V4L2, DMA-BUF or DRM planes may
/// appear above this interface. If a widget ever needs to know which decoder
/// ran, the leak has already happened.
abstract interface class MiraPlayer {
  /// Current position and state. Widgets listen to this and nothing else.
  ValueListenable<PlaybackStatus> get status;

  /// Prepare [source] and seek to [startAt] before the first frame, so resuming
  /// never shows the opening shot first.
  Future<void> open(Uri source, {Duration startAt});

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> stop();
  Future<void> dispose();

  /// The picture. A widget rather than a texture id, because the backend
  /// decides how frames reach the screen - a GStreamer texture in v1, perhaps a
  /// DRM plane in v2 - and the UI must not know which.
  Widget buildView(BuildContext context);
}
