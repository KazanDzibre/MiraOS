import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'netbird.dart';

/// The box's NetBird daemon, driven through its CLI over
/// `/var/run/netbird.sock`. Contract from the netbird 0.78.2 source: see
/// CLAUDE.md, *NetBird*.
class CliNetbird implements NetbirdControl {
  CliNetbird({this.executable = '/usr/bin/netbird'});

  final String executable;

  /// Without a graphical session variable netbird uses the device-code flow
  /// instead of trying to open a browser. And the CLI writes its own config
  /// under XDG_CONFIG_HOME on every call, which must be writable.
  static Map<String, String> get _environment => <String, String>{
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/root',
        'XDG_CONFIG_HOME': '/tmp',
      };

  @override
  Future<NetbirdStatus> status() async {
    final ProcessResult r;
    try {
      r = await Process.run(executable, const <String>['status', '--json'],
              environment: _environment, includeParentEnvironment: false)
          // No daemon takes ten seconds to say so.
          .timeout(const Duration(seconds: 15));
    } on ProcessException {
      throw const NetbirdException('NetBird is not installed on this box.');
    } on TimeoutException {
      throw const NetbirdException('NetBird did not answer in time.');
    }
    if (r.exitCode != 0) {
      throw const NetbirdException('The NetBird service is not answering.');
    }
    return parseStatus(r.stdout as String);
  }

  /// `netbird status --json`, in every daemon state.
  static NetbirdStatus parseStatus(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      throw const NetbirdException('NetBird sent something unreadable.');
    }
    if (decoded is! Map) throw const NetbirdException('NetBird sent something unreadable.');
    final Map<String, Object?> m = decoded.cast<String, Object?>();
    Map<String, Object?> sub(String key) =>
        m[key] is Map ? (m[key]! as Map<Object?, Object?>).cast<String, Object?>() : const <String, Object?>{};
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;

    final Map<String, Object?> management = sub('management');
    final Map<String, Object?> peers = sub('peers');
    final NetbirdState state = switch (m['daemonStatus']) {
      'Connected' => NetbirdState.connected,
      'Connecting' => NetbirdState.connecting,
      'NeedsLogin' || 'LoginFailed' || 'SessionExpired' => NetbirdState.signedOut,
      // Idle: signed in but down - `up` reconnects without a new login.
      _ => NetbirdState.stopped,
    };
    return NetbirdStatus(
      state,
      // Reported as CIDR, 100.x.y.z/16.
      ip: text(m['netbirdIp'])?.split('/').first,
      fqdn: text(m['fqdn']),
      managementUrl: text(management['url']),
      peersConnected: peers['connected'] is int ? peers['connected']! as int : 0,
      peersTotal: peers['total'] is int ? peers['total']! as int : 0,
      detail: management['connected'] == true ? null : text(management['error']),
    );
  }

  /// `netbird up --no-browser`: prints the sign-in URL, blocks until the
  /// viewer signs in, then prints "Connected" and exits 0. Killing it cancels,
  /// and the daemon drops the pending code.
  @override
  Stream<LoginStep> signIn() {
    Process? process;
    late final StreamController<LoginStep> out;
    out = StreamController<LoginStep>(
      onListen: () async {
        try {
          process = await Process.start(executable, const <String>['up', '--no-browser'],
              environment: _environment, includeParentEnvironment: false);
        } on ProcessException {
          out.addError(const NetbirdException('NetBird is not installed on this box.'));
          await out.close();
          return;
        }
        final Process p = process!;
        bool urlNext = false;
        bool codeShown = false;
        final List<String> tail = <String>[];
        void line(String l) {
          final String s = l.trim();
          if (s.isEmpty) return;
          tail
            ..add(s)
            ..removeRange(0, tail.length > 3 ? tail.length - 3 : 0);
          if (s.startsWith('Use this URL to log in')) {
            urlNext = true;
          } else if (urlNext) {
            urlNext = false;
            final LoginCode? code = parseLoginLine(s);
            if (code != null && !out.isClosed) {
              codeShown = true;
              out.add(code);
            }
          }
        }

        final Future<void> stdoutDone = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
        final Future<void> stderrDone = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
        final int exit = await p.exitCode;
        await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
        if (out.isClosed) return;
        if (exit == 0) {
          out.add(const LoginDone());
        } else {
          stderr.writeln('mira netbird: up exited $exit: ${tail.join(' | ')}');
          out.addError(NetbirdException(codeShown
              ? 'The sign-in code expired or was refused. Get a new code to try again.'
              : 'NetBird could not reach its sign-in service. Check the internet connection and try again.'));
        }
        await out.close();
      },
      onCancel: () {
        process?.kill();
      },
    );
    return out.stream;
  }

  /// The line after "Use this URL to log in:" -
  /// `<url> [and enter the code XXXX to authenticate.]`. Without the clause
  /// the URL already carries the code, as `user_code`.
  static LoginCode? parseLoginLine(String line) {
    final List<String> words = line.trim().split(RegExp(r'\s+'));
    final Uri? uri = words.isEmpty ? null : Uri.tryParse(words.first);
    if (uri == null || !uri.hasScheme) return null;
    final int enter = line.indexOf('enter the code ');
    if (enter >= 0) {
      final String code = line.substring(enter + 'enter the code '.length).split(RegExp(r'\s+')).first;
      return LoginCode(url: uri, code: code);
    }
    final String? code = uri.queryParameters['user_code'];
    return LoginCode(
      // Built afresh: replace(query: null) keeps the query.
      url: Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path),
      code: code ?? '',
      completeUrl: code == null ? null : uri,
    );
  }
}
