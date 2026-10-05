import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/player/gstreamer_player.dart';

void main() {
  // The software pipeline, which is what the VM runs: no V4L2 decoder, so
  // uridecodebin and an RGB format flutter-pi's copy path can allocate.
  group('software pipeline', () {
    test('autoplugs and converts to BGRA', () {
      final String p = GstreamerMiraPlayer.pipelineFor(
          Uri.parse('http://x/y.mkv'), hardware: false);
      expect(p, contains('uridecodebin'));
      expect(p, contains('videoconvert'));
      expect(p, contains('format=BGRA'));
      expect(p, isNot(contains('v4l2h264dec')));
    });

    test('honours an explicit format', () {
      expect(
          GstreamerMiraPlayer.pipelineFor(Uri.parse('http://x/y.mkv'),
              format: 'NV12', hardware: false),
          contains('format=NV12'));
    });
  });

  // The Pi's pipelines. Every one of these assertions is a bug that was
  // actually hit on the box.
  group('hardware pipeline', () {
    String pipe(String url) => GstreamerMiraPlayer.pipelineFor(Uri.parse(url),
        hardware: true);

    test('picks qtdemux for mp4 and its aliases', () {
      for (final String u in <String>[
        'http://s/Videos/1/stream.mp4?static=true',
        'http://s/Videos/1/stream.m4v?static=true',
        'http://s/Videos/1/stream.mov?static=true',
      ]) {
        expect(pipe(u), contains('qtdemux name=d'), reason: u);
      }
    });

    test('picks matroskademux for mkv', () {
      expect(pipe('http://s/Videos/1/stream.mkv?static=true'),
          contains('matroskademux name=d'));
    });

    test('picks hlsdemux and tsdemux for a transcode', () {
      final String p = pipe('http://s/videos/1/master.m3u8?VideoCodec=h264');
      expect(p, contains('hlsdemux ! tsdemux name=d'));
    });

    test('pins the hardware decoder and asks it for dmabufs', () {
      // capture-io-mode=dmabuf is the whole reason the pipeline is explicit:
      // without it the decoder hands over MMAP buffers and flutter-pi copies
      // every frame (31% of a core instead of 12%).
      final String p = pipe('http://s/Videos/1/stream.mp4');
      expect(p, contains('v4l2h264dec capture-io-mode=dmabuf'));
      expect(p, contains('h264parse'));
      expect(p, contains('format=NV12'));
      expect(p, isNot(contains('uridecodebin')));
      expect(p, isNot(contains('videoconvert')));
    });

    test('names the appsink, which is how flutter-pi finds it', () {
      expect(pipe('http://s/Videos/1/stream.mp4'),
          contains('appsink sync=true name="sink"'));
    });

    test('queues both branches, or the pipeline deadlocks', () {
      // A demuxer pushes every branch from one streaming thread: without a
      // queue per branch the first sink blocks waiting to preroll while the
      // other is never fed, and initialize() hangs with no error at all.
      // Measured on the box against a real transcode.
      final String p = pipe('http://s/videos/1/master.m3u8');
      final int queues = 'queue max-size-buffers=0'.allMatches(p).length;
      expect(queues, 2, reason: 'one queue per branch: $p');
    });

    test('parses and decodes AAC audio, downmixed to stereo 48k S16LE', () {
      final String p = pipe('http://s/Videos/1/stream.mkv');
      expect(p, contains('aacparse ! avdec_aac'));
      // All three are load-bearing: vc4-hdmi refuses anything else outright,
      // and without channels=2 ALSA drops the centre channel and the dialogue
      // with it.
      expect(p, contains('audio/x-raw,format=S16LE,channels=2,rate=48000'));
    });

    test('falls back to software for a container it cannot demux', () {
      // Should not happen - the DeviceProfile only permits mp4/mkv/HLS - but
      // playing badly beats not playing.
      final String p = pipe('http://s/Videos/1/stream.avi');
      expect(p, contains('uridecodebin'));
    });
  });
}
