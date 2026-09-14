import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

import '../core/tokens.dart';
import '../network/netbird.dart';
import 'state_screen.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';

/// Every hop between this box and your server: the NetBird tunnel, this
/// peer's address on it, and whether the media server answers at the end.
///
/// Reached from the address in the top bar, and from the failure screen when
/// the server does not answer.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({
    super.key,
    required this.monitor,
    required this.serverLabel,
    required this.checkServer,
    this.signInFirst = false,
  });

  final NetbirdMonitor monitor;
  final String serverLabel;

  /// Resolves true when the media server answers.
  final Future<bool> Function() checkServer;

  /// Open NetBird sign-in straight away - from "Not on your network", where
  /// signing in is the only thing to do.
  final bool signInFirst;

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  /// One node for whichever action comes first, so focus stays put when the
  /// tunnel comes up and "Sign in" turns into "Check again".
  final FocusNode _primaryNode = FocusNode(debugLabel: 'network:primary');
  bool? _serverUp;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (widget.signInFirst) {
      // After the first frame: this route must be on the navigator before
      // another can go on top of it.
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _signIn();
      });
    } else {
      _check();
    }
  }

  @override
  void dispose() {
    _primaryNode.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _serverUp = null;
    });
    final Future<NetbirdStatus> tunnel = widget.monitor.refresh();
    final bool server = await widget.checkServer().catchError((Object _) => false);
    await tunnel;
    if (!mounted) return;
    setState(() {
      _serverUp = server;
      _checking = false;
    });
  }

  Future<void> _signIn() async {
    await Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) =>
          NetbirdSignInScreen(control: widget.monitor.control),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
    if (mounted) unawaited(_check());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NetbirdStatus?>(
      valueListenable: widget.monitor,
      builder: (BuildContext context, NetbirdStatus? s, Widget? _) => _page(s),
    );
  }

  Widget _page(NetbirdStatus? s) {
    final NetbirdState? state = s?.state;
    final bool canSignIn = state == NetbirdState.signedOut || state == NetbirdState.stopped;
    final (String title, String body) = switch (state) {
      null => ('Checking your connection', 'Asking NetBird how the tunnel is doing.'),
      NetbirdState.connected => ('Connected to your network', 'The NetBird tunnel is up. This is how Mira reaches your server.'),
      NetbirdState.connecting => ('Connecting to your network', 'NetBird is bringing the tunnel up. This usually takes a few seconds.'),
      NetbirdState.signedOut => ('Not signed in to NetBird', 'This box needs to join your NetBird network before it can reach your server. Sign in once and it stays connected.'),
      NetbirdState.stopped => ('NetBird is not running', 'The tunnel service on this box is not answering. Signing in starts it again.'),
      NetbirdState.unavailable => ('NetBird is not on this box', 'This machine reaches your server over its own network, so there is no tunnel to manage here.'),
    };

    final List<String> technical = <String>[
      if (s?.managementUrl != null) s!.managementUrl!,
      if (s?.fqdn != null) s!.fqdn!,
      if (s?.detail != null) s!.detail!,
    ];

    return ColoredBox(
      color: MiraColors.background,
      child: SafeAreaPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _Wordmark(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('CONNECTION', style: MiraType.sectionLabel),
                    const SizedBox(height: 20),
                    Text(title, textAlign: TextAlign.center, style: MiraType.screenTitle.copyWith(fontSize: 62)),
                    const SizedBox(height: 20),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 780),
                      child: Text(body, textAlign: TextAlign.center, style: MiraType.body.copyWith(fontSize: 24)),
                    ),
                    const SizedBox(height: 34),
                    StatusCard(rows: <StatusRow>[
                      _tunnelRow(s),
                      StatusRow(
                        label: 'This box',
                        value: s?.ip ?? (state == NetbirdState.unavailable ? 'uses this machine\'s network' : 'no tunnel address yet'),
                        tone: s?.ip != null ? StatusTone.good : StatusTone.neutral,
                      ),
                      StatusRow(
                        label: 'Server',
                        value: switch (_serverUp) {
                          null => '${widget.serverLabel} · checking',
                          true => '${widget.serverLabel} · answering',
                          false => '${widget.serverLabel} · not answering',
                        },
                        tone: switch (_serverUp) {
                          null => StatusTone.neutral,
                          true => StatusTone.good,
                          false => StatusTone.bad,
                        },
                      ),
                    ]),
                    const SizedBox(height: 42),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        MiraButton(
                          label: canSignIn ? 'Sign in to NetBird' : 'Check again',
                          kind: MiraButtonKind.primary,
                          autofocus: true,
                          focusNode: _primaryNode,
                          onSelect: canSignIn ? _signIn : (_checking ? null : _check),
                        ),
                        if (canSignIn) ...<Widget>[
                          const SizedBox(width: 18),
                          MiraButton(label: 'Check again', onSelect: _checking ? null : _check),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (technical.isNotEmpty)
              Center(
                child: Text(
                  technical.join('  ·  '),
                  style: MiraType.status.copyWith(fontSize: 17, color: MiraColors.textFaint, letterSpacing: 1.0),
                ),
              ),
          ],
        ),
      ),
    );
  }

  StatusRow _tunnelRow(NetbirdStatus? s) {
    return switch (s?.state) {
      null => const StatusRow(label: 'NetBird', value: 'checking'),
      NetbirdState.connected => StatusRow(
          label: 'NetBird',
          value: s!.peersTotal > 0 ? 'connected · ${s.peersConnected} of ${s.peersTotal} peers' : 'connected',
          tone: StatusTone.good,
        ),
      NetbirdState.connecting => const StatusRow(label: 'NetBird', value: 'connecting'),
      NetbirdState.signedOut => const StatusRow(label: 'NetBird', value: 'signed out', tone: StatusTone.bad),
      NetbirdState.stopped => const StatusRow(label: 'NetBird', value: 'not running', tone: StatusTone.bad),
      NetbirdState.unavailable => const StatusRow(label: 'NetBird', value: 'not installed on this machine'),
    };
  }
}

/// NetBird's device sign-in, from the couch: a QR code for the phone, and the
/// address and code spelled out for anyone typing them by hand.
///
/// NetBird signs a peer in through your identity provider in a browser, never
/// with a password typed into the peer - so the password goes into the phone,
/// which already has a keyboard.
class NetbirdSignInScreen extends StatefulWidget {
  const NetbirdSignInScreen({super.key, required this.control});

  final NetbirdControl control;

  @override
  State<NetbirdSignInScreen> createState() => _NetbirdSignInScreenState();
}

class _NetbirdSignInScreenState extends State<NetbirdSignInScreen> {
  StreamSubscription<LoginStep>? _sub;
  LoginCode? _code;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void dispose() {
    // Leaving the screen abandons the attempt; NetBird stops waiting for it.
    _sub?.cancel();
    super.dispose();
  }

  void _restart() {
    setState(() {
      _code = null;
      _error = null;
    });
    _listen();
  }

  void _listen() {
    _sub?.cancel();
    _sub = widget.control.signIn().listen(
      (LoginStep step) {
        if (!mounted) return;
        switch (step) {
          case final LoginCode code:
            setState(() => _code = code);
          case LoginDone():
            setState(() => _done = true);
            // Long enough to read "Signed in", then back to the connection
            // screen, which shows the tunnel coming up.
            Future<void>.delayed(const Duration(milliseconds: 1200), () {
              if (mounted) Navigator.of(context).maybePop();
            });
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = e is NetbirdException ? e.message : 'NetBird did not finish signing in.');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final LoginCode? code = _code;
    return ColoredBox(
      color: MiraColors.background,
      child: SafeAreaPadding(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _Wordmark(),
            Expanded(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('NETBIRD SIGN-IN', style: MiraType.sectionLabel),
                        const SizedBox(height: 26),
                        Text('Join your network', style: MiraType.screenTitle.copyWith(fontSize: 72)),
                        const SizedBox(height: 26),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Text(
                            'Mira reaches your server over a private NetBird tunnel. '
                            'Sign in once from your phone and this box stays connected.',
                            style: MiraType.body.copyWith(fontSize: 24),
                          ),
                        ),
                        const SizedBox(height: 40),
                        if (_error != null)
                          Text(_error!, style: MiraType.body.copyWith(fontSize: 24, color: MiraColors.danger))
                        else if (code == null)
                          Text('Asking NetBird for a sign-in code…', style: MiraType.meta.copyWith(fontSize: 21))
                        else ...<Widget>[
                          Text.rich(
                            TextSpan(children: <InlineSpan>[
                              const TextSpan(text: 'Or go to '),
                              TextSpan(
                                text: code.url.toString(),
                                style: const TextStyle(color: MiraColors.textPrimary),
                              ),
                              const TextSpan(text: ' and enter'),
                            ]),
                            style: MiraType.meta.copyWith(fontSize: 21),
                          ),
                          const SizedBox(height: 18),
                          _CodeTiles(code.code),
                        ],
                        const SizedBox(height: 44),
                        MiraButton(
                          label: 'New code',
                          kind: _error != null ? MiraButtonKind.primary : MiraButtonKind.secondary,
                          autofocus: true,
                          onSelect: _done ? null : _restart,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 110),
                  SizedBox(
                    width: 480,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 480,
                          height: 480,
                          padding: const EdgeInsets.all(36),
                          decoration: BoxDecoration(
                            color: code == null ? MiraColors.surface : MiraColors.textPrimary,
                            borderRadius: const BorderRadius.all(Radius.circular(12)),
                          ),
                          child: code == null
                              ? null
                              : CustomPaint(painter: _QrPainter((code.completeUrl ?? code.url).toString())),
                        ),
                        const SizedBox(height: 34),
                        const _Step(1, 'Scan the code with your phone'),
                        const _Step(2, 'Sign in to NetBird with your account'),
                        _Step(3, code?.completeUrl != null ? 'Check the code matches, then confirm' : 'Enter the code shown here'),
                        const SizedBox(height: 18),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _done ? MiraColors.positive : (_error != null ? MiraColors.danger : MiraColors.accent),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              _done
                                  ? 'Signed in. Bringing the tunnel up…'
                                  : _error != null
                                      ? 'Sign-in stopped'
                                      : 'Waiting for you to sign in',
                              style: MiraType.meta.copyWith(fontSize: 20, color: _done ? MiraColors.positive : MiraColors.textSecondary),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Text('BACK  Cancel', style: MiraType.status.copyWith(fontSize: 17, color: MiraColors.textFaint, letterSpacing: 1.0)),
          ],
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        MiraStar(),
        SizedBox(width: 14),
        Text(
          'MIRA',
          style: TextStyle(fontFamily: 'ArchivoBlack', fontSize: 22, letterSpacing: 7.5, color: MiraColors.textPrimary),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: MiraColors.outline),
            ),
            child: Text('$number', style: MiraType.meta.copyWith(fontSize: 19, color: MiraColors.textSecondary)),
          ),
          const SizedBox(width: 18),
          Expanded(child: Text(text, style: MiraType.meta.copyWith(fontSize: 21, color: MiraColors.textPrimary))),
        ],
      ),
    );
  }
}

/// The code as big separate characters, readable from the sofa. A dash in the
/// code becomes a gap rather than a tile.
class _CodeTiles extends StatelessWidget {
  const _CodeTiles(this.code);

  final String code;

  @override
  Widget build(BuildContext context) {
    final List<String> chars = code.split('');
    final int letters = chars.where((String c) => c != '-').length;
    final double tile = letters > 6 ? 78 : 104;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String c in chars)
          if (c == '-')
            const SizedBox(width: 28)
          else
            Container(
              width: tile,
              height: tile * 1.23,
              margin: const EdgeInsets.only(right: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: MiraColors.surface,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                border: Border.all(color: MiraColors.surfaceBorder),
              ),
              child: Text(c, style: MiraType.screenTitle.copyWith(fontSize: tile * 0.6)),
            ),
      ],
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
      : _image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final int n = _image.moduleCount;
    // Whole pixels per module: fractional ones leave hairline seams that some
    // phone cameras read as light modules.
    final double m = (size.shortestSide / n).floorToDouble();
    final Offset origin = Offset((size.width - m * n) / 2, (size.height - m * n) / 2);
    final Paint dark = Paint()..color = MiraColors.background;
    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        if (_image.isDark(y, x)) {
          canvas.drawRect(Rect.fromLTWH(origin.dx + x * m, origin.dy + y * m, m, m), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.data != data;
}
