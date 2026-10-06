import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/frame_watch.dart';

void main() {
  // It must cost nothing when it is off: this runs on every frame of every
  // film, on a box with four cores and a job to do.
  test('it is off unless MIRA_FRAME_LOG says otherwise', () {
    expect(FrameWatch.enabled, isFalse,
        reason: 'the environment does not set MIRA_FRAME_LOG in tests');
  });

  test('starting while off registers nothing and does not throw', () {
    expect(FrameWatch.start, returnsNormally);
  });
}
