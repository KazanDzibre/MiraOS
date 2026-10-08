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

    // Each of these is a film the server used to re-encode in full - video
    // and all - purely because of its audio track.
    test('picks the decoder for each audio codec the box has', () {
      // No parsers but AAC's: ac3parse in front of avdec_eac3 makes the
      // branch refuse to negotiate, measured on the box against a real file.
      const Map<String, String> expected = <String, String>{
        'ac3': 'audio/x-ac3 ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000 ! avdec_ac3',
        'eac3': 'audio/x-eac3 ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000 ! avdec_eac3',
        'dts': 'audio/x-dts ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000 ! avdec_dca',
      };
      expected.forEach((String codec, String chain) {
        final String p = GstreamerMiraPlayer.pipelineFor(
            Uri.parse('http://s/Videos/1/stream.mkv'),
            hardware: true,
            videoCodec: 'hevc',
            audioCodec: codec);
        expect(p, contains(chain), reason: codec);
        // Whatever the codec, it still arrives as 48 kHz stereo: vc4-hdmi
        // takes nothing else.
        expect(p, contains('audio/x-raw,format=S16LE,channels=2,rate=48000'),
            reason: codec);
      });
    });

    test('AAC keeps its parser, because a transcode arrives as ADTS in TS', () {
      final String p = GstreamerMiraPlayer.pipelineFor(
          Uri.parse('http://s/videos/1/master.m3u8'),
          hardware: true,
          audioCodec: 'aac');
      expect(p, contains('aacparse ! avdec_aac'));
    });

    test('HEVC uses the stateless decoder and names no output format', () {
      // Its only output is Broadcom SAND; naming a linear format would fail
      // to link.
      final String p = GstreamerMiraPlayer.pipelineFor(
          Uri.parse('http://s/Videos/1/stream.mkv'),
          hardware: true,
          videoCodec: 'hevc',
          audioCodec: 'aac');
      expect(p, contains('h265parse ! v4l2slh265dec'));
      expect(p, isNot(contains('v4l2h264dec')));
    });

    test('an audio codec the box cannot decode falls back to software', () {
      final String p = GstreamerMiraPlayer.pipelineFor(
          Uri.parse('http://s/Videos/1/stream.mkv'),
          hardware: true,
          audioCodec: 'flac');
      expect(p, contains('uridecodebin'),
          reason: 'better to play it badly than to build a pipeline that cannot link');
    });

    test('falls back to software for a container it cannot demux', () {
      // Should not happen - the DeviceProfile only permits mp4/mkv/HLS - but
      // playing badly beats not playing.
      final String p = pipe('http://s/Videos/1/stream.avi');
      expect(p, contains('uridecodebin'));
    });
  });
}
