/// The Jellyfin DeviceProfile for a Raspberry Pi 4.
///
/// **This is the Jellyfin integration.** Most of the box's perceived quality
/// lives here. Declare the envelope correctly and the server direct-plays what
/// the VideoCore VI can decode and transcodes what it cannot. Declare it wrong
/// and Mira receives something it cannot decode smoothly, which looks exactly
/// like a player bug while being nothing of the kind.
///
/// ## H.264 only, deliberately (2026-10-05)
///
/// The profile declares a *narrower* envelope than the hardware can in
/// principle handle, and that is the point. What the Pi 4 can do on paper:
///
/// | Codec            | Pi 4 hardware                  | Declared as    |
/// |------------------|--------------------------------|----------------|
/// | H.264 to 1080p60 | yes - bcm2835-codec, V4L2 M2M  | **direct play**|
/// | HEVC to 4K60     | yes *on paper* - rpivid        | **transcode**  |
/// | H.264 at 4K      | no - software only             | transcode      |
/// | VP9 / AV1        | no - software only             | transcode      |
/// | MPEG-2 / VC-1    | no                             | transcode      |
///
/// HEVC is declared *unsupported* even though the silicon has a decoder for
/// it, because on this image the decoder is unreachable: the `v4l2codecs`
/// plugin registers zero features, since the stateless decoder's media
/// controller nodes live under `/sys/bus/media` and the plugin enumerates
/// `/sys/class/media`. Measured on the box, not inferred. The result was that
/// HEVC titles - **82% of this library** - did not play at all, while H.264
/// played at 12% of one core through `v4l2h264dec`.
///
/// So the box asks for exactly one video codec and lets the server produce it.
/// That is the Chromium-kiosk arrangement this appliance replaced, minus the
/// browser, and it is the configuration the user chose on 2026-10-05: "then we
/// know everything is going to work on pie".
///
/// The cost is server CPU, and it is not small - see the transcoding notes in
/// CLAUDE.md. Re-widening this profile to include HEVC is the single highest
/// value change available once the `v4l2codecs` enumeration bug is fixed; the
/// HEVC block is kept below, commented, so that is a two-line change.
///
/// ## Audio is AAC only, also deliberately
///
/// AC3, E-AC3 and DTS are *not* declared, even though a TV would happily
/// decode them, because nothing on this box can pass them through: vc4-hdmi
/// via ALSA's `default` device accepts 48 kHz S16LE stereo and refuses
/// everything else with -EINVAL, so the shell's pipeline downmixes to stereo
/// anyway. Declaring them would mean shipping AC3/DTS decoders and parsers to
/// produce a stereo mix the server can make for free - and the server's
/// downmix is the better one, because it folds the centre channel in with
/// proper gains. A film with AC3 audio and H.264 video is remuxed rather than
/// re-encoded: the server copies the video stream and only converts the audio,
/// which is cheap. Real HDMI passthrough would need the IEC958 device and is a
/// deliberate later feature.
library;

import 'dart:io';

abstract final class JellyfinDeviceProfile {
  /// What the box can actually decode and play out, and nothing more.
  ///
  /// Everything absent from this list is the server's job. See the library
  /// docs above for why AC3/DTS are not here.
  ///
  /// AAC alone, not AAC and MP3, for a smaller reason: it means the shell's
  /// pipeline has exactly one audio parser to plug (`aacparse ! avdec_aac`)
  /// rather than a parser chosen per track, and this library has 298 AAC
  /// tracks and no MP3 ones at all. A film with MP3 audio would be remuxed
  /// with its video copied, which costs the server almost nothing.
  static const String _directPlayAudio = 'aac';

  /// Builds the profile.
  ///
  /// [maxStreamingBitrate] is the one value here that is about the *network*
  /// rather than the hardware. Mira reaches the server over a NetBird tunnel,
  /// so when the box is remote this is what should come down - not the codec
  /// declarations. Leave the envelope alone and change this.
  ///
  /// The default is 20 Mbps rather than a LAN-speed number because it is also
  /// the *transcode target*: Jellyfin encodes at `min(source, this)`, and
  /// asking for 120 Mbps made the server aim at 119 Mbps of H.264 for a 1080p
  /// film (seen in the generated playlist). That is pure cost - more server
  /// CPU and more bytes for no visible difference at 1080p.
  /// 20 Mbps: transparent at 1080p H.264, and the transcode target too.
  static const int defaultMaxStreamingBitrate = 20000000;

  /// What to ask the server to produce for one title, in bits per second.
  ///
  /// **Jellyfin treats `MaxStreamingBitrate` as a target, not a ceiling.** Sent
  /// a flat 20 Mbps it encoded a 5.5 Mbps HEVC film at 19.6 Mbps - measured on
  /// the real server, 2026-10-06, from the `VideoBitrate` in the generated HLS
  /// playlist. Across this library that is wild: the median source is
  /// **2.0 Mbps** and only 4% of titles pass 12 Mbps, so a fixed cap had the
  /// server encoding about ten times the bits the original had, pushing them
  /// over the network, and making the Pi decode them - for detail that was
  /// never in the file. The Pi's CPU showed it: 8.3 Mbps cost 8% of a core,
  /// 19.6 Mbps cost 16%.
  ///
  /// So the box asks for a bitrate derived from the source:
  ///
  ///  * **Transcoding** - [_transcodeFactor] times the source, because H.264
  ///    needs roughly 1.5-2x what HEVC uses for the same picture, clamped to
  ///    [_minTranscodeBitrate]..[_maxTranscodeBitrate]. A 5.5 Mbps HEVC film
  ///    becomes ~8.8 Mbps of H.264 instead of 19.6.
  ///  * **Direct play** - never below the file's own bitrate. This is the trap
  ///    in the other direction: `MaxStreamingBitrate` also *gates* direct
  ///    play, so a 25 Mbps H.264 file under a 12 Mbps cap would be transcoded -
  ///    the box would re-encode a film it can already decode untouched.
  ///  * **Unknown bitrate** - [defaultMaxStreamingBitrate], the old behaviour,
  ///    since there is nothing to size against.
  static int streamingBitrateFor({
    int? sourceBitrate,
    required bool directPlayLikely,
  }) {
    if (sourceBitrate == null || sourceBitrate <= 0) {
      return defaultMaxStreamingBitrate;
    }
    if (directPlayLikely) {
      // Headroom over the file itself: a muxed stream carries more than the
      // video track's own bitrate, and a cap equal to it can tip the server
      // into transcoding.
      final int withHeadroom = (sourceBitrate * 1.5).round();
      return withHeadroom < defaultMaxStreamingBitrate
          ? defaultMaxStreamingBitrate
          : withHeadroom;
    }
    final int target = (sourceBitrate * _transcodeFactor).round();
    if (target < _minTranscodeBitrate) return _minTranscodeBitrate;
    if (target > _maxTranscodeBitrate) return _maxTranscodeBitrate;
    return target;
  }

  /// H.264 needs about this much more than HEVC for the same picture.
  static const double _transcodeFactor = 1.6;

  /// Below this, a busy 1080p scene starts to show it.
  static const int _minTranscodeBitrate = 3000000;

  /// Above this, 1080p H.264 is transparent and the extra bits only cost
  /// server CPU, bandwidth and decode work on the Pi.
  static const int _maxTranscodeBitrate = 12000000;

  /// HEVC direct play is on, and the bit depth it is trusted to.
  ///
  /// Both are proven on the box (2026-10-08). *Hair*, 8-bit, and *Dune*,
  /// HEVC Main 10 at 1920x800, each direct-played with a correct picture -
  /// Jellyfin reporting PlayMethod DirectPlay and no transcode, the decoder
  /// on /dev/video19, no dropped frames, and the server doing nothing at all.
  /// 10-bit matters most: it is 70% of this library, and transcoding it to
  /// 8-bit H.264 was the visible quality gap against a player that direct
  /// plays.
  ///
  /// `MIRA_HEVC=8` holds it to 8-bit, `=0` turns HEVC direct play off and
  /// goes back to letting the server transcode.
  static int get hevcMaxBitDepth {
    final String? setting = Platform.environment['MIRA_HEVC'];
    if (setting == null || setting.isEmpty) return 10;
    if (setting == '0') return 0;
    return int.tryParse(setting) == 8 ? 8 : 10;
  }

  static bool get hevcDirectPlay => hevcMaxBitDepth > 0;

  static Map<String, Object?> build({
    int maxStreamingBitrate = defaultMaxStreamingBitrate,
    bool? hevc,
    int? hevcBitDepth,
  }) {
    final int hevcDepth = hevcBitDepth ?? hevcMaxBitDepth;
    final bool withHevc = hevc ?? (hevcDepth > 0);
    return <String, Object?>{
      'Name': 'Mira (Raspberry Pi 4)',
      'MaxStreamingBitrate': maxStreamingBitrate,
      'MaxStaticBitrate': maxStreamingBitrate,
      'MusicStreamingTranscodingBitrate': 384000,

      'DirectPlayProfiles': <Map<String, Object?>>[
        // One video entry, one codec. The containers are the two the shell
        // can demux with a pinned hardware decoder - see
        // `GstreamerMiraPlayer.pipelineFor`, which builds qtdemux for mp4 and
        // matroskademux for mkv. Adding a container here without adding it
        // there yields a stream the box cannot open.
        <String, Object?>{
          'Type': 'Video',
          'Container': 'mp4,m4v,mov,mkv',
          'VideoCodec': withHevc ? 'h264,hevc' : 'h264',
          'AudioCodec': _directPlayAudio,
        },
        <String, Object?>{
          'Type': 'Audio',
          'Container': 'mp3,flac,aac,m4a,ogg,opus,wav',
        },
      ],

      'TranscodingProfiles': <Map<String, Object?>>[
        <String, Object?>{
          'Type': 'Video',
          'Container': 'ts',
          'Protocol': 'hls',
          'Context': 'Streaming',
          'VideoCodec': 'h264',
          'AudioCodec': 'aac',
          // Two channels, so the *server* does the downmix. The HDMI path is
          // stereo regardless; doing it server-side means a proper centre-fold
          // instead of ALSA's channel-drop, and less work for the Pi.
          'MaxAudioChannels': '2',
          // One segment of lead-in: playback starts sooner, and the shell
          // shows a spinner meanwhile.
          'MinSegments': 1,
          'BreakOnNonKeyFrames': true,
        },
        <String, Object?>{
          'Type': 'Audio',
          'Container': 'mp3',
          'AudioCodec': 'mp3',
          'Context': 'Streaming',
          'Protocol': 'http',
          'MaxAudioChannels': '2',
        },
      ],

      'CodecProfiles': <Map<String, Object?>>[
        // H.264: hardware to 1080p60 and no further. Level 42 is 1080p60.
        // These conditions also clamp the *transcode*, which is why the
        // width/height limits matter even though everything is H.264 now.
        <String, Object?>{
          'Type': 'Video',
          'Codec': 'h264',
          'Conditions': <Map<String, Object?>>[
            _cond('LessThanEqual', 'Width', '1920'),
            _cond('LessThanEqual', 'Height', '1080'),
            _cond('LessThanEqual', 'VideoLevel', '42'),
            _cond('LessThanEqual', 'VideoBitDepth', '8'),
            _cond('EqualsAny', 'VideoProfile',
                'baseline|constrained baseline|main|high'),
            _cond('NotEquals', 'IsAnamorphic', 'true'),
          ],
        },
        // HEVC, when asked for. The decoder is rpivid on /dev/video19, which
        // does Main and Main 10 to 4K - but the UI plane is 1080p and the
        // library has nothing above it, so the envelope stays at 1080p until
        // there is a reason to widen it.
        if (withHevc)
          <String, Object?>{
            'Type': 'Video',
            'Codec': 'hevc',
            'Conditions': <Map<String, Object?>>[
              _cond('LessThanEqual', 'Width', '1920'),
              _cond('LessThanEqual', 'Height', '1080'),
              _cond('LessThanEqual', 'VideoBitDepth', '$hevcDepth'),
              _cond('EqualsAny', 'VideoProfile',
                  hevcDepth >= 10 ? 'main|main 10' : 'main'),
              _cond('NotEquals', 'IsAnamorphic', 'true'),
            ],
          },
      ],

      'SubtitleProfiles': <Map<String, Object?>>[
        // Text formats are fetched alongside and drawn by the shell, which
        // keeps them out of the decode path entirely.
        <String, Object?>{'Format': 'srt', 'Method': 'External'},
        <String, Object?>{'Format': 'subrip', 'Method': 'External'},
        <String, Object?>{'Format': 'vtt', 'Method': 'External'},
        <String, Object?>{'Format': 'webvtt', 'Method': 'External'},
        // Bitmap and styled formats have to be burned in by the server; the Pi
        // has no cycles to spare rendering them alongside a decode.
        <String, Object?>{'Format': 'ass', 'Method': 'Encode'},
        <String, Object?>{'Format': 'ssa', 'Method': 'Encode'},
        <String, Object?>{'Format': 'pgssub', 'Method': 'Encode'},
        <String, Object?>{'Format': 'dvdsub', 'Method': 'Encode'},
      ],
    };
  }

  static Map<String, Object?> _cond(
    String condition,
    String property,
    String value, {
    bool isRequired = false,
  }) {
    return <String, Object?>{
      'Condition': condition,
      'Property': property,
      'Value': value,
      'IsRequired': isRequired,
    };
  }
}
