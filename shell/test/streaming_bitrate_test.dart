import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/jellyfin/device_profile.dart';

/// Jellyfin treats MaxStreamingBitrate as a *target*, so this number decides
/// what the server actually encodes - and what the Pi then has to decode.
void main() {
  int sized({int? source, bool direct = false}) =>
      JellyfinDeviceProfile.streamingBitrateFor(
          sourceBitrate: source, directPlayLikely: direct);

  group('what to ask the server for', () {
    test('a transcode is sized from the source, not from a fixed cap', () {
      // The Imitation Game: 5.5 Mbps HEVC. It was being encoded at 19.6 Mbps.
      expect(sized(source: 5500000), 8800000);
    });

    test('the library median gets a sane number rather than ten times itself', () {
      // Median source here is 2.0 Mbps, so the box asks for 3.2 - not 19.6.
      expect(sized(source: 2000000), 3200000);
    });

    test('a very low bitrate source still gets a floor', () {
      // 1.6x of a 700 kbps file would be too mean for a busy 1080p scene.
      expect(sized(source: 700000), 3000000);
    });

    test('it never asks for more than 1080p H.264 can use', () {
      expect(sized(source: 30000000), 12000000);
    });

    test('an unknown bitrate falls back to the old fixed cap', () {
      expect(sized(), JellyfinDeviceProfile.defaultMaxStreamingBitrate);
      expect(sized(source: 0), JellyfinDeviceProfile.defaultMaxStreamingBitrate);
    });

    // The trap in the other direction: MaxStreamingBitrate also *gates* direct
    // play, so a cap below the file's own bitrate makes the server re-encode a
    // film the box can already decode untouched.
    test('direct play is never capped below the file itself', () {
      expect(sized(source: 25000000, direct: true), greaterThan(25000000));
      expect(sized(source: 35000000, direct: true), greaterThan(35000000));
    });

    test('a small direct-play file still gets the normal allowance', () {
      expect(sized(source: 2000000, direct: true),
          JellyfinDeviceProfile.defaultMaxStreamingBitrate);
    });

    test('the profile carries the chosen number through', () {
      final Map<String, Object?> p =
          JellyfinDeviceProfile.build(maxStreamingBitrate: 8800000);
      expect(p['MaxStreamingBitrate'], 8800000);
      expect(p['MaxStaticBitrate'], 8800000);
    });
  });
}
