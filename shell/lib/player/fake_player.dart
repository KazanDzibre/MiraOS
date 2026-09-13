import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'mira_player.dart';

/// A player that advances a clock and decodes nothing.
///
/// For laying out the player UI and for the VM target, where there is no
/// VideoCore and real playback would say nothing useful about the appliance.
/// It is not a stand-in for measurement: performance claims come from the Pi.
class FakeMiraPlayer implements MiraPlayer {
  FakeMiraPlayer({this.fakeDuration = const Duration(hours: 1, minutes: 58)});

  final Duration fakeDuration;

  final ValueNotifier<PlaybackStatus> _status =
      ValueNotifier<PlaybackStatus>(const PlaybackStatus());
  Timer? _ticker;

  @override
  ValueListenable<PlaybackStatus> get status => _status;

  @override
  Future<void> open(Uri source, {Duration startAt = Duration.zero}) async {
    _status.value = PlaybackStatus(
      state: PlaybackState.opening,
      position: startAt,
      duration: fakeDuration,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _status.value = _status.value.copyWith(state: PlaybackState.paused);
  }

  @override
  Future<void> play() async {
    if (_status.value.state == PlaybackState.idle) return;
    _status.value = _status.value.copyWith(state: PlaybackState.playing);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (Timer _) {
      final PlaybackStatus s = _status.value;
      final Duration next = s.position + const Duration(milliseconds: 250);
      if (next >= s.duration) {
        _ticker?.cancel();
        _status.value = s.copyWith(position: s.duration, state: PlaybackState.ended);
      } else {
        _status.value = s.copyWith(position: next, buffered: next + const Duration(minutes: 3));
      }
    });
  }

  @override
  Future<void> pause() async {
    _ticker?.cancel();
    _status.value = _status.value.copyWith(state: PlaybackState.paused);
  }

  @override
  Future<void> seek(Duration to) async {
    final PlaybackStatus s = _status.value;
    final Duration clamped = to < Duration.zero
        ? Duration.zero
        : (to > s.duration ? s.duration : to);
    _status.value = s.copyWith(position: clamped);
  }

  @override
  Future<void> stop() async {
    _ticker?.cancel();
    _status.value = const PlaybackStatus();
  }

  @override
  Widget buildView(BuildContext context) {
    // A dark field, not a fake frame: nothing is decoded here, and a picture
    // would suggest otherwise.
    return const ColoredBox(color: Color(0xFF050506), child: SizedBox.expand());
  }

  @override
  Future<void> dispose() async {
    _ticker?.cancel();
    _status.dispose();
  }
}
