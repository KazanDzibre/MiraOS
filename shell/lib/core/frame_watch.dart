import 'dart:io';

import 'package:flutter/scheduler.dart';

/// Reports frames the app took too long to produce, with a timestamp.
///
/// This exists because "the picture hitches now and then" has at least three
/// causes that look identical from the sofa, and the box can tell them apart
/// only if each is measured separately:
///
///  * **Frames dropped in the pipeline** - GStreamer says so itself, as
///    "Dropping frame due to QoS" in the shell log.
///  * **Frames the app was late producing** - this. Flutter times every frame;
///    anything past a vsync interval is a jank the viewer sees, and the build
///    and raster halves say whether it was Dart work or the GPU.
///  * **Neither** - the frames are all produced and all delivered, and the
///    unevenness is in how they are paced onto a display whose refresh does
///    not divide the film's frame rate. Ruling the first two out is what
///    makes that conclusion safe rather than a guess.
///
/// Off unless `MIRA_FRAME_LOG` is set, because it prints to the console the TV
/// never shows and the serial line does.
abstract final class FrameWatch {
  /// A frame slower than this is one a viewer can see. 60 Hz leaves 16.7 ms;
  /// anything past 32 ms has certainly missed a vsync, whatever the mode.
  static const Duration _slow = Duration(milliseconds: 32);

  static bool get enabled {
    final String? on = Platform.environment['MIRA_FRAME_LOG'];
    return on != null && on.isNotEmpty && on != '0';
  }

  static int _frames = 0;
  static int _janks = 0;
  static DateTime _since = DateTime.now();

  static void start() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    stdout.writeln('mira frames: watching (slow frame = over ${_slow.inMilliseconds} ms)');
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _frames++;
      final Duration total = t.totalSpan;
      if (total < _slow) continue;
      _janks++;
      // Build is Dart work, raster is the GPU. Saying which rules out half the
      // possible causes at a glance.
      stdout.writeln(
        'mira frames: slow frame ${total.inMilliseconds} ms '
        '(build ${t.buildDuration.inMilliseconds} ms, '
        'raster ${t.rasterDuration.inMilliseconds} ms) '
        'at ${DateTime.now().toIso8601String()}',
      );
    }
    final DateTime now = DateTime.now();
    if (now.difference(_since) >= const Duration(seconds: 60)) {
      stdout.writeln(
        'mira frames: $_janks slow of $_frames in the last minute '
        'at ${now.toIso8601String()}',
      );
      _frames = 0;
      _janks = 0;
      _since = now;
    }
  }
}
