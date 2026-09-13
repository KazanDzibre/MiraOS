/// The Jellyfin DeviceProfile for a Raspberry Pi 4.
///
/// **This is the Jellyfin integration.** Most of the box's perceived quality
/// lives here. Declare the envelope correctly and the server direct-plays what
/// the VideoCore VI can decode and transcodes what it cannot. Declare it wrong
/// and Mira receives 4K H.264, which stutters - and looks exactly like a player
/// bug while being nothing of the kind.
///
/// The envelope, from the hardware rather than from the codec spec:
///
/// | Codec            | Pi 4 hardware                  | Declared as    |
/// |------------------|--------------------------------|----------------|
/// | HEVC to 4K60     | yes - rpivid, V4L2 stateless   | direct play    |
/// | H.264 to 1080p60 | yes - bcm2835-codec, V4L2 M2M  | direct play    |
/// | H.264 at 4K      | **no** - software only         | transcode      |
/// | VP9 / AV1        | **no** - software only         | transcode      |
/// | MPEG-2 / VC-1    | no                             | transcode      |
///
/// Note the H.264 ceiling is **1080p, not 4K**. That single line is the one
/// most likely to be got wrong, and it is why the width/height conditions
/// below are per-codec rather than global.
///
/// Nothing outside this table is declared for direct play. Codecs the A72
/// could in principle limp through in software are deliberately left out: a
/// stuttering direct play is worse than a clean transcode.
library;

abstract final class JellyfinDeviceProfile {
  /// Audio the TV decodes itself, passed through untouched over HDMI.
  ///
  /// TrueHD and DTS-HD are deliberately absent: they are left for the server to
  /// convert down to AC3 rather than relying on the Pi's HDMI passthrough for
  /// the lossless formats.
  static const String _passthroughAudio =
      'aac,mp3,ac3,eac3,dts,flac,opus,vorbis,pcm';

  /// Builds the profile.
  ///
  /// [maxStreamingBitrate] is the one value here that is about the *network*
  /// rather than the hardware. Mira reaches the server over a NetBird tunnel,
  /// so when the box is remote this is what should come down - not the codec
  /// declarations. Leave the envelope alone and change this.
  static Map<String, Object?> build({
    int maxStreamingBitrate = 120000000, // 120 Mbps: a LAN-speed tunnel
  }) {
    return <String, Object?>{
      'Name': 'Mira (Raspberry Pi 4)',
      'MaxStreamingBitrate': maxStreamingBitrate,
      'MaxStaticBitrate': maxStreamingBitrate,
      'MusicStreamingTranscodingBitrate': 384000,

      'DirectPlayProfiles': <Map<String, Object?>>[
        <String, Object?>{
          'Type': 'Video',
          'Container': 'mp4,m4v,mkv,webm,mov,ts,mpegts',
          'VideoCodec': 'h264,hevc',
          'AudioCodec': _passthroughAudio,
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
          // Transcode target is H.264 at 1080p, which the Pi decodes in
          // hardware with room to spare. Asking for HEVC would make the server
          // work harder for no gain on this box.
          'VideoCodec': 'h264',
          'AudioCodec': 'aac,ac3',
          'MaxAudioChannels': '6',
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
        // HEVC: hardware to 4K60 via rpivid. Level 153 is 5.1.
        <String, Object?>{
          'Type': 'Video',
          'Codec': 'hevc',
          'Conditions': <Map<String, Object?>>[
            _cond('LessThanEqual', 'Width', '3840'),
            _cond('LessThanEqual', 'Height', '2160'),
            _cond('LessThanEqual', 'VideoLevel', '153'),
            _cond('LessThanEqual', 'VideoBitDepth', '10'),
            _cond('EqualsAny', 'VideoProfile', 'main|main 10'),
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
        // has no cycles to spare rendering them alongside a 4K decode.
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
