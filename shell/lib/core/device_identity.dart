import 'dart:io';
import 'dart:math';

/// Who this box says it is when it signs in to Jellyfin.
///
/// This matters more than it looks. **Jellyfin replaces a device's session on
/// every sign-in**, keyed by DeviceId - so two boxes sharing one id do not
/// coexist, they revoke each other: each sign-in invalidates the other's
/// token, the loser's next request fails with "Your sign-in is no longer
/// valid", it signs in again, and round it goes. Found on 2026-10-06 with the
/// Pi running in the living room and the VM running on the bench, both
/// hard-coded as `mira-shell`: the VM's serial console filled with that error
/// on every rail.
///
/// The id therefore has to be stable for a box and different between boxes,
/// without first-run enrolment having been built yet. In order:
///
///  1. `/var/lib/mira/device-id`, if something wrote one. That is the
///     authority, and it survives a reflash because the state partition does.
///  2. The first real network interface's MAC, which is stable across reboots
///     and genuinely distinct per machine - including between a Pi and a VM on
///     the same bench.
///  3. A random id, so a box with neither still works rather than sharing
///     `mira-shell` with every other box.
///
/// It is written back to (1) whenever that is possible, so a box keeps the
/// same identity even if its network card changes later.
class DeviceIdentity {
  const DeviceIdentity({required this.id, required this.name});

  final String id;

  /// What Jellyfin's dashboard and "now playing" lists call this box.
  final String name;

  static const String _statePath = '/var/lib/mira/device-id';

  /// Interfaces that are never the box's own: loopback, and the tunnels and
  /// bridges that come and go. Netbird's interface in particular would make
  /// the id depend on whether the tunnel happened to be up first.
  static const List<String> _ignoredPrefixes = <String>[
    'lo', 'wg', 'netbird', 'docker', 'veth', 'br-', 'virbr', 'tun', 'tap',
  ];

  static Future<DeviceIdentity> resolve() async {
    return DeviceIdentity(id: _resolveId(), name: _resolveName());
  }

  static String _resolveId() {
    final String? stored = _readStored();
    if (stored != null) return stored;

    final String id = _fromMac() ?? _random();
    _store(id);
    return id;
  }

  static String? _readStored() {
    try {
      final File f = File(_statePath);
      if (!f.existsSync()) return null;
      final String s = f.readAsStringSync().trim();
      return s.isEmpty ? null : s;
    } on FileSystemException {
      return null;
    }
  }

  static void _store(String id) {
    try {
      final File f = File(_statePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('$id\n');
    } on FileSystemException {
      // A read-only root, or no state partition yet. The MAC-derived id is
      // stable on its own, so this is a nicety rather than a requirement.
    }
  }

  /// The first usable MAC on the box, as `mira-0123456789ab`.
  static String? _fromMac() {
    try {
      final Directory net = Directory('/sys/class/net');
      if (!net.existsSync()) return null;
      final List<String> names = net
          .listSync()
          .map((FileSystemEntity e) => e.path.split('/').last)
          .where(isUsableInterface)
          .toList()
        ..sort();
      for (final String name in names) {
        final File address = File('/sys/class/net/$name/address');
        if (!address.existsSync()) continue;
        final String? mac = normaliseMac(address.readAsStringSync());
        if (mac != null) return 'mira-$mac';
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  /// Whether an interface is one of the box's own, rather than a tunnel or a
  /// bridge that may or may not exist at any given boot.
  static bool isUsableInterface(String name) =>
      !_ignoredPrefixes.any((String p) => name == p || name.startsWith(p));

  /// `00:11:22:33:44:55` to `001122334455`, rejecting the all-zero address
  /// that virtual interfaces report.
  static String? normaliseMac(String raw) {
    final String mac = raw.trim().toLowerCase().replaceAll(':', '');
    if (mac.length != 12) return null;
    if (!RegExp(r'^[0-9a-f]{12}$').hasMatch(mac)) return null;
    if (mac == '000000000000') return null;
    return mac;
  }

  static String _random() {
    final Random r = Random.secure();
    final String hex = List<String>.generate(
        12, (int _) => r.nextInt(16).toRadixString(16)).join();
    return 'mira-$hex';
  }

  /// A name a person can recognise in Jellyfin's dashboard.
  ///
  /// The Pi names itself in the device tree, which is far more use than the
  /// hostname - every Mira box is called `mira`, so "Mira" twice over tells
  /// nobody which room is watching.
  static String _resolveName() {
    final String? model = _readModel();
    if (model != null) return 'Mira ($model)';
    return 'Mira';
  }

  static String? _readModel() {
    try {
      final File f = File('/proc/device-tree/model');
      if (!f.existsSync()) return null;
      // The device tree pads with NULs.
      final String model = f.readAsStringSync().replaceAll('\u0000', '').trim();
      return model.isEmpty ? null : model;
    } on FileSystemException {
      return null;
    }
  }
}
