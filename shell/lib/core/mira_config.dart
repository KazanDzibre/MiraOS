import 'dart:convert';
import 'dart:io';

/// Where Mira finds the server it belongs to.
///
/// Two locations, in order:
///
///  1. `/var/lib/mira/config.json` - the appliance. Its own partition, because
///     the root filesystem is read-only and the power gets pulled mid-write.
///  2. `~/.config/mira/dev-server.json` - a developer's machine, running the
///     shell against a real server without an image.
///
/// Absent config is not an error: the shell falls back to sample content, which
/// is how it runs before first-run enrolment exists.
class MiraConfig {
  const MiraConfig({
    required this.baseUrl,
    this.username,
    this.password,
    this.apiKey,
    this.overseerrUrl,
    this.overseerrApiKey,
  });

  final Uri baseUrl;
  final String? username;
  final String? password;

  /// The request server - Seerr, which keeps Overseerr's API - reached over the
  /// same tunnel. Optional: without it Discover says it is not connected and
  /// everything else works.
  final Uri? overseerrUrl;
  final String? overseerrApiKey;

  bool get hasOverseerr =>
      overseerrUrl != null && overseerrApiKey != null && overseerrApiKey!.isNotEmpty;

  /// Preferred over a password once first-run enrolment exists: an API key can
  /// be revoked without touching the account, which matters for a device that
  /// lives in a living room.
  final String? apiKey;

  bool get hasCredentials =>
      apiKey != null || (username != null && password != null);

  static final List<String> _searchPaths = <String>[
    '/var/lib/mira/config.json',
    '${Platform.environment['HOME'] ?? ''}/.config/mira/dev-server.json',
  ];

  /// Returns null when no config exists, or when it is unreadable - a corrupt
  /// file must not stop the box from booting into something diagnosable.
  static Future<MiraConfig?> load() async {
    for (final String path in _searchPaths) {
      if (path.isEmpty) continue;
      final File f = File(path);
      if (!f.existsSync()) continue;
      try {
        final Map<String, Object?> json =
            (jsonDecode(await f.readAsString()) as Map<Object?, Object?>)
                .cast<String, Object?>();
        final String? base = json['baseUrl'] as String?;
        if (base == null || base.isEmpty) continue;
        return MiraConfig(
          baseUrl: Uri.parse(base),
          username: json['username'] as String?,
          password: json['password'] as String?,
          apiKey: json['apiKey'] as String?,
          overseerrUrl: _uriOrNull(json['overseerrUrl'] as String?),
          overseerrApiKey: _keyOrNull(json['overseerrApiKey'] as String?),
        );
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static Uri? _uriOrNull(String? raw) =>
      raw == null || raw.trim().isEmpty ? null : Uri.tryParse(raw.trim());

  /// The dev config ships with a placeholder; treat it as no key rather than
  /// sending it and reporting a confusing 403.
  static String? _keyOrNull(String? raw) {
    final String? key = raw?.trim();
    if (key == null || key.isEmpty || key.startsWith('PASTE_')) return null;
    return key;
  }
}
