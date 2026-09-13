import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../overseerr/discover_source.dart';
import '../overseerr/overseerr_client.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

/// One title from Discover: what it is, whether it is here, and the request.
///
/// After a request this same screen becomes the confirmation from
/// design/OverseerrRequest.dc.html - "Request sent" and the path from
/// requested to in your library - rather than pushing another screen, so Back
/// always returns to the grid in one press.
class DiscoverTitleScreen extends StatefulWidget {
  const DiscoverTitleScreen({
    super.key,
    required this.source,
    required this.title,
    this.onChanged,
  });

  final DiscoverSource source;
  final DiscoverTitle title;

  /// Told about every change, so the grid's badge is right on return.
  final ValueChanged<DiscoverTitle>? onChanged;

  @override
  State<DiscoverTitleScreen> createState() => _DiscoverTitleScreenState();
}

class _DiscoverTitleScreenState extends State<DiscoverTitleScreen> {
  late DiscoverTitle _title = widget.title;
  bool _busy = false;
  bool _justRequested = false;
  String? _notice;

  /// The main action. Focus returns here when the button that had it goes away
  /// - Request becomes Keep browsing - so the remote is never left stranded.
  final FocusNode _primaryNode = FocusNode(debugLabel: 'discover:primary');

  @override
  void initState() {
    super.initState();
    _load();
    debugAssertReachableAfterFrame(context, screen: 'DiscoverTitleScreen');
  }

  @override
  void dispose() {
    _primaryNode.dispose();
    super.dispose();
  }

  /// List results carry only a status; details add runtime, genres and the
  /// request id that Cancel needs.
  Future<void> _load() async {
    try {
      final DiscoverTitle full = await widget.source.details(widget.title);
      if (!mounted) return;
      setState(() => _title = full);
      widget.onChanged?.call(full);
    } on OverseerrException catch (e) {
      if (!mounted) return;
      setState(() => _notice = e.message);
    }
  }

  Future<void> _run(Future<DiscoverTitle> Function(DiscoverTitle) action, {required bool requesting}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final DiscoverTitle updated = await action(_title);
      if (!mounted) return;
      setState(() {
        _title = updated;
        _justRequested = requesting;
        if (!requesting) _notice = 'Request cancelled.';
      });
      widget.onChanged?.call(updated);
    } on OverseerrException catch (e) {
      if (!mounted) return;
      setState(() => _notice = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _primaryNode.requestFocus();
    });
  }

  void _request() => _run(widget.source.request, requesting: true);
  void _cancel() => _run(widget.source.cancelRequest, requesting: false);
  void _back() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final Uri? backdrop = widget.source.backdropFor(_title);
    return MiraBackdrop(
      tint: placeholderArt('${_title.mediaType}${_title.tmdbId}').colors.first,
      art: backdrop == null
          ? null
          : Positioned.fill(
              child: Image.network(
                backdrop.toString(),
                fit: BoxFit.cover,
                cacheHeight: 1080,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, MiraMetrics.safeV),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Discover', style: MiraType.nav.copyWith(color: MiraColors.textSecondary)),
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: _content(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) get _label {
    if (_justRequested && (_title.isRequested || _title.inLibrary)) {
      return ('REQUEST SENT', MiraColors.positive);
    }
    if (_title.inLibrary) return ('IN YOUR LIBRARY', MiraColors.positive);
    if (_title.requestState == RequestState.pendingApproval) {
      return ('WAITING FOR APPROVAL', MiraColors.textSecondary);
    }
    if (_title.isRequested) return ('REQUESTED', MiraColors.textSecondary);
    return (_title.isMovie ? 'FILM' : 'SERIES', MiraColors.accent);
  }

  Widget _content() {
    final DiscoverTitle t = _title;
    final (String label, Color labelColor) = _label;
    final List<String> meta = <String>[
      if (t.year != null) '${t.year}',
      if (t.runtime != null) _runtime(t.runtime!),
      if (t.genres.isNotEmpty) t.genres.first,
      t.isMovie ? 'Film' : 'Series',
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: MiraType.sectionLabel.copyWith(color: labelColor)),
        const SizedBox(height: 20),
        Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MiraType.hero.copyWith(fontSize: 76)),
        const SizedBox(height: 20),
        Text(meta.join('   ·   '), style: MiraType.meta),
        if (t.overview != null) ...<Widget>[
          const SizedBox(height: 20),
          Text(t.overview!, maxLines: 3, overflow: TextOverflow.ellipsis, style: MiraType.body),
        ],
        const SizedBox(height: 32),
        Wrap(spacing: 18, runSpacing: 18, children: _actions(t)),
        if (_notice != null) ...<Widget>[
          const SizedBox(height: 16),
          Text(_notice!, style: MiraType.meta),
        ],
        if (t.isRequested || t.inLibrary) ...<Widget>[
          const SizedBox(height: 56),
          _Timeline(title: t),
        ],
      ],
    );
  }

  List<Widget> _actions(DiscoverTitle t) {
    if (t.inLibrary) {
      return <Widget>[
        MiraButton(
          label: 'Back to Discover',
          kind: MiraButtonKind.primary,
          autofocus: true,
          focusNode: _primaryNode,
          onSelect: _back,
        ),
      ];
    }
    if (t.isRequested) {
      return <Widget>[
        MiraButton(
          label: 'Keep browsing',
          kind: MiraButtonKind.primary,
          autofocus: true,
          focusNode: _primaryNode,
          onSelect: _back,
        ),
        if (t.requestId != null)
          MiraButton(label: 'Cancel request', onSelect: _busy ? null : _cancel),
      ];
    }
    return <Widget>[
      MiraButton(
        label: _busy ? 'Requesting…' : (t.isMovie ? 'Request' : 'Request all seasons'),
        kind: MiraButtonKind.primary,
        autofocus: true,
        focusNode: _primaryNode,
        onSelect: _busy ? null : _request,
      ),
    ];
  }

  static String _runtime(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes.remainder(60);
    return h > 0 ? '$h h $m m' : '$m m';
  }
}

enum _StepState { done, current, todo }

/// Requested, approved, downloading, in your library - the one question a
/// request raises is "when can I watch it", and this answers it at a glance.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.title});

  final DiscoverTitle title;

  @override
  Widget build(BuildContext context) {
    final DiscoverTitle t = title;
    final bool approved = t.inLibrary ||
        t.requestState == RequestState.approved ||
        t.availability == Availability.processing;
    final List<(String, bool)> steps = <(String, bool)>[
      ('Requested', true),
      ('Approved', approved),
      ('Downloading', t.inLibrary),
      ('In your library', t.inLibrary),
    ];
    final int firstOpen = steps.indexWhere(((String, bool) s) => !s.$2);

    _StepState stateOf(int i) => steps[i].$2
        ? _StepState.done
        : (i == firstOpen ? _StepState.current : _StepState.todo);

    final List<Widget> children = <Widget>[];
    for (int i = 0; i < steps.length; i++) {
      if (i > 0) {
        children.add(Expanded(
          child: Container(
            height: 3,
            margin: const EdgeInsets.only(top: 27),
            color: steps[i].$2 ? MiraColors.positive : MiraColors.surfaceBorder,
          ),
        ));
      }
      children.add(_Step(label: steps[i].$1, state: stateOf(i)));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final bool done = state == _StepState.done;
    final bool current = state == _StepState.current;
    return SizedBox(
      width: 200,
      child: Column(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? MiraColors.positive : null,
              border: done
                  ? null
                  : Border.all(
                      color: current ? MiraColors.textPrimary : MiraColors.surfaceBorder,
                      width: current ? 3 : 2,
                    ),
            ),
            child: done ? CustomPaint(painter: _CheckPainter()) : null,
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: MiraType.control.copyWith(
              fontSize: 21,
              color: state == _StepState.todo ? MiraColors.textTertiary : MiraColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    canvas.drawPath(
      Path()
        ..moveTo(7.4 * s, 12.4 * s)
        ..lineTo(10.6 * s, 15.6 * s)
        ..lineTo(16.8 * s, 9 * s),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = MiraColors.background,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => false;
}
