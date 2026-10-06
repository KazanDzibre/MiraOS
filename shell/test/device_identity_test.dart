import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/device_identity.dart';

void main() {
  // Jellyfin replaces a device's session on every sign-in, so an id shared
  // between two boxes makes them revoke each other in a loop - which is what
  // the hard-coded 'mira-shell' did once the Pi and the VM ran at once.
  group('device id', () {
    test('a MAC becomes a stable id', () {
      expect(DeviceIdentity.normaliseMac('dc:a6:32:1b:2c:3d'), 'dca6321b2c3d');
      expect(DeviceIdentity.normaliseMac('  DC:A6:32:1B:2C:3D \n'), 'dca6321b2c3d');
    });

    test('the all-zero address virtual interfaces report is refused', () {
      expect(DeviceIdentity.normaliseMac('00:00:00:00:00:00'), isNull);
    });

    test('rubbish is refused rather than turned into an id', () {
      expect(DeviceIdentity.normaliseMac(''), isNull);
      expect(DeviceIdentity.normaliseMac('not-a-mac'), isNull);
      expect(DeviceIdentity.normaliseMac('dc:a6:32:1b:2c'), isNull);
    });

    test('tunnels and bridges are not the box', () {
      // Netbird's interface would otherwise make the id depend on whether the
      // tunnel happened to come up first.
      for (final String name in <String>['lo', 'wg0', 'netbird0', 'docker0', 'veth1a2b', 'br-abc']) {
        expect(DeviceIdentity.isUsableInterface(name), isFalse, reason: name);
      }
    });

    test('real interfaces are', () {
      for (final String name in <String>['eth0', 'end0', 'enp3s0', 'wlan0']) {
        expect(DeviceIdentity.isUsableInterface(name), isTrue, reason: name);
      }
    });

    test('resolving gives a non-empty id and a name', () async {
      final DeviceIdentity device = await DeviceIdentity.resolve();
      expect(device.id, isNotEmpty);
      expect(device.id, isNot('mira-shell'), reason: 'the shared id is the bug');
      expect(device.name, startsWith('Mira'));
    });
  });
}
