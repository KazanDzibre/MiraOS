import 'dart:async';

import 'package:flutter/widgets.dart';

/// Where this box's NetBird peer stands.
enum NetbirdState {
  /// No NetBird on this machine - a developer desktop borrowing the host's
  /// tunnel. Says nothing about whether the server is reachable.
  unavailable,

  /// Installed, but the daemon is not answering.
  stopped,

  /// The daemon runs but this peer has no login, or it expired.
  signedOut,

  connecting,
  connected,
}

class NetbirdStatus {
  const NetbirdStatus(
    this.state, {
    this.ip,
    this.fqdn,
    this.managementUrl,
    this.peersConnected = 0,
    this.peersTotal = 0,
    this.detail,
  });

  final NetbirdState state;

  /// This peer's tunnel address, e.g. 100.92.14.7.
  final String? ip;
  final String? fqdn;
  final String? managementUrl;
  final int peersConnected;
  final int peersTotal;

  /// One technical line for the bottom of a screen, in the daemon's words.
  final String? detail;

  bool get isUp => state == NetbirdState.connected;
}

/// A failure with a sentence fit for a television.
class NetbirdException implements Exception {
  const NetbirdException(this.message);

  final String message;

  @override
  String toString() => message;
}

sealed class LoginStep {
  const LoginStep();
}

/// Show this, then wait: the viewer signs in on their phone.
class LoginCode extends LoginStep {
  const LoginCode({required this.url, required this.code, this.completeUrl});

  /// Where to sign in, typed by hand.
  final Uri url;
  final String code;

  /// [url] with the code already filled in - what the QR code carries.
  final Uri? completeUrl;
}

/// Signed in, and the tunnel is coming up.
class LoginDone extends LoginStep {
  const LoginDone();
}

/// The box's NetBird, behind an interface so the screens can be tested and
/// rendered without a daemon.
abstract interface class NetbirdControl {
  Future<NetbirdStatus> status();

  /// NetBird's device-code sign-in: emits a [LoginCode] to show, then
  /// [LoginDone]. Errors are [NetbirdException]s. Cancelling the subscription
  /// abandons the attempt.
  Stream<LoginStep> signIn();
}

/// The latest status, for the top bar and the connection screens.
class NetbirdMonitor extends ValueNotifier<NetbirdStatus?> {
  NetbirdMonitor(this.control, {this.every = const Duration(seconds: 15)}) : super(null);

  final NetbirdControl control;
  final Duration every;
  Timer? _timer;
  bool _disposed = false;

  void start() {
    refresh();
    _timer ??= Timer.periodic(every, (_) => refresh());
  }

  Future<NetbirdStatus> refresh() async {
    NetbirdStatus s;
    try {
      s = await control.status();
    } on NetbirdException catch (e) {
      s = NetbirdStatus(NetbirdState.stopped, detail: e.message);
    }
    if (!_disposed) value = s;
    return s;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Makes the top bar's network badge a way into the connection screen, and
/// gives it the live tunnel state.
class NetworkScope extends InheritedNotifier<NetbirdMonitor> {
  const NetworkScope({
    super.key,
    required NetbirdMonitor monitor,
    required this.onOpen,
    required super.child,
  }) : super(notifier: monitor);

  /// Opens the connection screen; [signIn] goes on to NetBird sign-in.
  final void Function({bool signIn}) onOpen;

  static NetworkScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NetworkScope>();
}

/// A NetBird that signs in after a short wait. Clearly invented addresses, so
/// it is obvious at a glance when nothing real is connected.
class FakeNetbird implements NetbirdControl {
  FakeNetbird({
    NetbirdState state = NetbirdState.signedOut,
    this.signInDelay = const Duration(seconds: 3),
  }) : _state = state;

  NetbirdState _state;
  final Duration signInDelay;

  @override
  Future<NetbirdStatus> status() async => _state == NetbirdState.connected
      ? const NetbirdStatus(
          NetbirdState.connected,
          ip: '100.64.0.7',
          fqdn: 'mira.netbird.example',
          managementUrl: 'https://netbird.example',
          peersConnected: 3,
          peersTotal: 4,
        )
      : NetbirdStatus(_state, managementUrl: 'https://netbird.example');

  @override
  Stream<LoginStep> signIn() async* {
    yield LoginCode(
      url: Uri.parse('https://netbird.example/device'),
      code: 'KXQM-2PLD',
      completeUrl: Uri.parse('https://netbird.example/device?user_code=KXQM-2PLD'),
    );
    await Future<void>.delayed(signInDelay);
    _state = NetbirdState.connected;
    yield const LoginDone();
  }
}
