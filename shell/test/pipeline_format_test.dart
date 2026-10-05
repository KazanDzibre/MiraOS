import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/player/gstreamer_player.dart';
void main() {
  test('pipeline names the requested format', () {
    final String p = GstreamerMiraPlayer.pipelineFor(Uri.parse('http://x/y.mkv'), format: 'NV12');
    expect(p, contains('video/x-raw,format=NV12 ! appsink'));
    expect(GstreamerMiraPlayer.pipelineFor(Uri.parse('http://x/y.mkv')), contains('format=BGRA'));
  });
}
