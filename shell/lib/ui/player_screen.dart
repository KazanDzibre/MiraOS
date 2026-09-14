import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../core/track_choice.dart';
import '../input/mira_focusable.dart';
import '../input/remote.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import '../player/mira_player.dart';
import '../player/player_factory.dart';
import '../player/webvtt.dart';
import 'state_screen.dart';
import 'tracks_sheet.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';

/// A film, playing.
///
/// The screen knows nothing about how frames are decoded: it asks the
/// [MiraPlayer] for a view and a status, and draws subtitles itself from the
/// reported position, so they survive any change of backend.
///
/// Remote model: the overlay hides after a few seconds of playback. While it is
/// hidden, the first key only brings it back - nobody should seek by accident
/// while reaching for the remote - except Back, which always stops. With the
/// overlay up, focus starts on the scrub bar: left/right seek, OK pauses.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.source,
    required this.item,
    required this.fromStart,
    this.choice,
    this.playerFactory = createPlayer,
  });

  final LibrarySource source;
  final MediaItem item;
  final bool fromStart;

  /// Null plays with the tracks saved for the film - Resume on Home goes
  /// straight here, without the film page that would otherwise load them.
  final TrackChoice? choice;

  /// Tests inject a fake; the app uses whichever backend the platform has.
  final MiraPlayer Function() playerFactory;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const Duration _hideAfter = Duration(seconds: 5);
  static const Duration _reportEvery = Duration(seconds: 10);
  static const Duration _seekSettle = Duration(milliseconds: 450);

  late final MiraPlayer _player = widget.playerFactory();
  late MediaItem _item = widget.item;
  late TrackChoice _choice = widget.choice ?? const TrackChoice();
  late bool _tracksResolved = widget.choice != null;

  PlaybackPlan? _plan;
  Subtitles? _subtitles;
  String? _failure;
  bool _stopped = false;
  bool _sheetOpen = false;

  bool _overlay = true;
  Timer? _hideTimer;
  Timer? _reportTimer;

  /// Where a run of left/right presses is heading. The seek itself waits until
  /// the presses stop, so holding the button does not fire a request per repeat
  /// at a server that may be transcoding.
  Duration? _pendingSeek;
  Timer? _seekTimer;

  final FocusNode _scrubNode = FocusNode(debugLabel: 'player:scrub');
  final FocusNode _wakeNode = FocusNode(debugLabel: 'player:wake');
  final FocusNode _playNode = FocusNode(debugLabel: 'player:play');

  @override
  void initState() {
    super.initState();
    _player.status.addListener(_onStatus);
    _start(widget.fromStart ? Duration.zero : widget.item.resumePosition);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _reportTimer?.cancel();
    _seekTimer?.cancel();
    _player.status.removeListener(_onStatus);
    if (!_stopped) {
      // Popped from outside (the app's Back, say): still tell the server where
      // we got to, or the resume position is lost.
      _stopped = true;
      _reportStopped(_player.status.value.position);
    }
    _player.dispose();
    _scrubNode.dispose();
    _wakeNode.dispose();
    _playNode.dispose();
    super.dispose();
  }

  // --- playback -------------------------------------------------------------

  Future<void> _start(Duration at) async {
    setState(() => _failure = null);
    if (!_tracksResolved) {
      _tracksResolved = true;
      try {
        final MediaItem full = await widget.source.item(_item.id);
        final TrackChoice saved = await widget.source.savedTracks(full);
        if (!mounted) return;
        setState(() {
          _item = full;
          _choice = saved;
        });
      } on JellyfinException {
        // Play with the file's defaults rather than not at all.
      }
    }
    try {
      final MediaTrack? audio = _choice.audio;
      final PlaybackPlan plan = await widget.source.planPlayback(
        _item,
        audioStreamIndex: audio != null && !audio.isDefault ? audio.index : null,
        // Text subtitles are drawn here; only a bitmap one needs the server.
        subtitleStreamIndex: _choice.burnsInSubtitle ? _choice.subtitle!.index : null,
      );
      if (!mounted) return;
      // setState, not a bare assignment: the header's "Direct play" line reads it.
      setState(() => _plan = plan);
      await _player.open(plan.streamUrl, startAt: at);
      if (!mounted) return;
      await _player.play();
      // Also after a restart for a new audio track: the server treats each
      // stream as its own session, and progress without a start is orphaned.
      widget.source
          .reportStart(_item, position: at, plan: plan)
          .catchError((Object _) {});
      _reportTimer?.cancel();
      _reportTimer = Timer.periodic(_reportEvery, (_) => _reportProgress());
      _scheduleHide();
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() => _failure = e.message);
    }
    unawaited(_loadSubtitles());
  }

  Future<void> _loadSubtitles() async {
    final MediaTrack? track = _choice.subtitle;
    if (track == null || !track.isTextBased) {
      if (mounted) setState(() => _subtitles = null);
      return;
    }
    try {
      final String text = await widget.source.subtitleText(_item, track);
      if (!mounted || _choice.subtitle?.index != track.index) return;
      setState(() => _subtitles = Subtitles.parseWebVtt(text));
    } on JellyfinException {
      // Playback without subtitles beats no playback. The sheet will show the
      // track as chosen, so a missing line is noticeable and retryable.
      if (mounted) setState(() => _subtitles = null);
    }
  }

  void _onStatus() {
    final PlaybackStatus s = _player.status.value;
    if (s.state == PlaybackState.failed && _failure == null) {
      setState(() => _failure = s.failure ?? 'The film stopped playing.');
    } else if (s.state == PlaybackState.ended) {
      _exit();
    }
  }

  Future<void> _togglePlay() async {
    final PlaybackStatus s = _player.status.value;
    if (s.isPlaying) {
      await _player.pause();
      _reportProgress();
      _showOverlay(autoHide: false);
    } else {
      await _player.play();
      _scheduleHide();
    }
  }

  void _nudge(int direction, {required bool repeat}) {
    final PlaybackStatus s = _player.status.value;
    if (s.duration <= Duration.zero) return;
    // Held down, the step grows: tapping is for "what did she say", holding is
    // for getting past the credits.
    final Duration step = repeat ? const Duration(seconds: 30) : const Duration(seconds: 10);
    Duration target = (_pendingSeek ?? s.position) + step * direction;
    if (target < Duration.zero) target = Duration.zero;
    if (target > s.duration) target = s.duration;
    setState(() => _pendingSeek = target);
    _seekTimer?.cancel();
    _seekTimer = Timer(_seekSettle, () async {
      final Duration? to = _pendingSeek;
      if (to == null) return;
      await _player.seek(to);
      if (mounted) setState(() => _pendingSeek = null);
    });
    _showOverlay();
  }

  void _reportProgress() {
    final PlaybackStatus s = _player.status.value;
    if (!s.isActive) return;
    widget.source
        .reportProgress(_item, position: s.position, isPaused: !s.isPlaying, playSessionId: _plan?.playSessionId)
        .catchError((Object _) {});
  }

  void _reportStopped(Duration position) {
    widget.source
        .reportStopped(_item, position: position, playSessionId: _plan?.playSessionId)
        .catchError((Object _) {});
  }

  void _exit() {
    if (_stopped) return;
    _stopped = true;
    _reportTimer?.cancel();
    _reportStopped(_player.status.value.position);
    _player.stop();
    Navigator.of(context).maybePop();
  }

  // --- overlay --------------------------------------------------------------

  void _showOverlay({bool autoHide = true}) {
    if (!_overlay) {
      setState(() => _overlay = true);
      // The scrub bar is still inside ExcludeFocus until the rebuild, and a
      // request made before then is silently dropped.
      _focusAfterFrame(_scrubNode);
    }
    if (autoHide) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideAfter, () {
      if (!mounted || _sheetOpen || _failure != null) return;
      if (!_player.status.value.isPlaying || _pendingSeek != null) return;
      setState(() => _overlay = false);
      _focusAfterFrame(_wakeNode);
    });
  }

  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  /// Any key on a visible overlay keeps it up.
  KeyEventResult _onOverlayKey(FocusNode _, KeyEvent event) {
    if (_overlay && event is! KeyUpEvent) _scheduleHide();
    return KeyEventResult.ignored;
  }

  KeyEventResult _onWakeKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_isBack(event.logicalKey)) return KeyEventResult.ignored;
    _showOverlay();
    return KeyEventResult.handled;
  }

  KeyEventResult _onScrubKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final bool repeat = event is KeyRepeatEvent;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _nudge(-1, repeat: repeat);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _nudge(1, repeat: repeat);
      return KeyEventResult.handled;
    }
    // Explicit, not the directional policy: the bar spans the screen, so the
    // policy picked the button nearest its centre - Stop - found in the VM.
    // Down lands on Play/Pause, the control you most likely wanted.
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && event is KeyDownEvent) {
      _playNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _isBack(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.goBack ||
      key == LogicalKeyboardKey.browserBack ||
      key == LogicalKeyboardKey.gameButtonB;

  Future<void> _openTracks() async {
    final TrackChoice before = _choice;
    _hideTimer?.cancel();
    setState(() => _sheetOpen = true);
    await Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => TracksSheet(
        source: widget.source,
        item: _item,
        initial: _choice,
        onChanged: (TrackChoice choice, MediaItem item) {
          final bool subtitleChanged = choice.subtitle?.index != _choice.subtitle?.index;
          setState(() {
            _choice = choice;
            _item = item;
          });
          // Text subtitles switch live, under the sheet, with no restart.
          if (subtitleChanged && !choice.burnsInSubtitle) _loadSubtitles();
        },
      ),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
    if (!mounted) return;
    setState(() => _sheetOpen = false);
    _scrubNode.requestFocus();

    // A different audio track, or a subtitle painted into the picture, is a
    // different stream from the server. Restart where we were - once, after
    // the sheet closes, rather than on every row the viewer tried.
    final bool audioChanged = before.audio?.index != _choice.audio?.index;
    final bool burnChanged = (before.burnsInSubtitle || _choice.burnsInSubtitle) &&
        before.subtitle?.index != _choice.subtitle?.index;
    if (audioChanged || burnChanged) {
      final Duration at = _player.status.value.position;
      await _player.stop();
      if (mounted) await _start(at);
    } else {
      _scheduleHide();
    }
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_failure != null) {
      return MiraStateScreen(
        glyph: MiraGlyph.serverDown,
        title: 'This film will not play',
        body: 'Mira reached your server, but the stream did not start. The file '
            'may be unreadable, or the server may have stopped transcoding.',
        primaryAction: 'Try again',
        onPrimary: () => _start(_player.status.value.position > Duration.zero
            ? _player.status.value.position
            : (widget.fromStart ? Duration.zero : widget.item.resumePosition)),
        secondaryAction: 'Back',
        onSecondary: _exit,
        technical: _failure,
      );
    }

    return Actions(
      actions: <Type, Action<Intent>>{
        BackIntent: CallbackAction<BackIntent>(onInvoke: (BackIntent _) {
          _exit();
          return null;
        }),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onOverlayKey,
        child: ColoredBox(
          color: MiraColors.background,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Center(child: _player.buildView(context)),
              ValueListenableBuilder<PlaybackStatus>(
                valueListenable: _player.status,
                builder: (BuildContext context, PlaybackStatus s, Widget? _) {
                  final bool waiting = s.state == PlaybackState.opening ||
                      s.state == PlaybackState.buffering ||
                      s.state == PlaybackState.idle;
                  return waiting ? const Center(child: MiraStar(size: 44)) : const SizedBox.shrink();
                },
              ),
              _subtitleLayer(),
              // Holds focus while the overlay is hidden, so the first key can be
              // spent on waking it. It paints nothing; the overlay appearing is
              // its focus treatment.
              Offstage(
                offstage: _overlay,
                // Out of traversal while the overlay is up, or the d-pad could
                // land on an invisible full-screen control.
                child: ExcludeFocus(
                  excluding: _overlay,
                  child: MiraFocusable(
                    focusNode: _wakeNode,
                    showRing: false,
                    onSelect: _showOverlay,
                    onKey: _onWakeKey,
                    debugLabel: 'player:wake',
                    builder: (BuildContext context, bool focused) => const SizedBox.expand(),
                  ),
                ),
              ),
              IgnorePointer(
                ignoring: !_overlay,
                child: AnimatedOpacity(
                  opacity: _overlay ? 1 : 0,
                  duration: MiraMotion.screen,
                  child: ExcludeFocus(excluding: !_overlay, child: _overlayLayer()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitleLayer() {
    final Subtitles? subs = _subtitles;
    if (subs == null) return const SizedBox.shrink();
    return AnimatedPadding(
      duration: MiraMotion.screen,
      curve: Curves.easeOut,
      // Clear of the transport while it is up; low on the frame while it is not.
      padding: EdgeInsets.fromLTRB(MiraMetrics.safeH * 2, 0, MiraMetrics.safeH * 2,
          _overlay ? 300 : MiraMetrics.safeV),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ValueListenableBuilder<PlaybackStatus>(
          valueListenable: _player.status,
          builder: (BuildContext context, PlaybackStatus s, Widget? _) {
            final String? line = subs.textAt(s.position);
            if (line == null) return const SizedBox.shrink();
            return Text(line, textAlign: TextAlign.center, style: MiraType.subtitle);
          },
        ),
      ),
    );
  }

  Widget _overlayLayer() {
    final Color clear = MiraColors.scrim.withValues(alpha: 0);
    final List<String> meta = <String>[
      if (_item.productionYear != null) '${_item.productionYear}',
      if (_plan != null) _plan!.isDirectPlay ? 'Direct play' : 'Server transcoding',
      if (_choice.subtitle != null) 'Subtitles: ${trackName(_choice.subtitle!)}',
    ];
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            height: 280,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[MiraColors.scrim, clear],
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            height: 420,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[MiraColors.scrim, clear],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, MiraMetrics.safeV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('NOW PLAYING', style: MiraType.sectionLabel),
              const SizedBox(height: 14),
              Text(_item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MiraType.screenTitle),
              const SizedBox(height: 12),
              Text(meta.join('   ·   '), style: MiraType.meta),
              const Spacer(),
              ValueListenableBuilder<PlaybackStatus>(
                valueListenable: _player.status,
                builder: (BuildContext context, PlaybackStatus s, Widget? _) => _ScrubBar(
                  focusNode: _scrubNode,
                  status: s,
                  pendingSeek: _pendingSeek,
                  onKey: _onScrubKey,
                  onSelect: _togglePlay,
                ),
              ),
              const SizedBox(height: 28),
              Row(
                children: <Widget>[
                  ValueListenableBuilder<PlaybackStatus>(
                    valueListenable: _player.status,
                    builder: (BuildContext context, PlaybackStatus s, Widget? _) => MiraButton(
                      label: s.isPlaying ? 'Pause' : 'Play',
                      kind: MiraButtonKind.primary,
                      focusNode: _playNode,
                      onSelect: _togglePlay,
                    ),
                  ),
                  const SizedBox(width: 18),
                  MiraButton(label: 'Subtitles & audio', onSelect: _openTracks),
                  const SizedBox(width: 18),
                  MiraButton(label: 'Stop', onSelect: _exit),
                  const Spacer(),
                  const _Hints(),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _clock(Duration d) {
  final String h = d.inHours.toString();
  final String m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// The timeline. Driven with left/right, never dragged: a gyro pointer cannot
/// hold a drag steady, and the d-pad has to be enough on its own.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({
    required this.focusNode,
    required this.status,
    required this.pendingSeek,
    required this.onKey,
    required this.onSelect,
  });

  static const double _track = 8;
  static const double _thumb = 22;

  final FocusNode focusNode;
  final PlaybackStatus status;
  final Duration? pendingSeek;
  final KeyEventResult Function(KeyEvent event) onKey;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final int total = status.duration.inMilliseconds;
    double fraction(Duration d) => total <= 0 ? 0 : (d.inMilliseconds / total).clamp(0.0, 1.0);
    final Duration shown = pendingSeek ?? status.position;
    final Duration left = status.duration - shown;

    return MiraFocusable(
      focusNode: focusNode,
      autofocus: true,
      onKey: onKey,
      onSelect: onSelect,
      debugLabel: 'player:scrub',
      builder: (BuildContext context, bool focused) {
        return SizedBox(
          height: MiraMetrics.minControl,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 120,
                  child: Text(_clock(shown), style: MiraType.status.copyWith(color: MiraColors.textPrimary)),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
                    final double w = c.maxWidth;
                    final double played = w * fraction(shown);
                    return Stack(
                      alignment: Alignment.centerLeft,
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        Container(
                          height: _track,
                          decoration: const BoxDecoration(color: MiraColors.surfaceBorder, borderRadius: MiraMetrics.borderRadius),
                        ),
                        Container(
                          height: _track,
                          width: w * fraction(status.buffered),
                          decoration: const BoxDecoration(color: MiraColors.outline, borderRadius: MiraMetrics.borderRadius),
                        ),
                        Container(
                          height: _track,
                          width: played,
                          decoration: const BoxDecoration(color: MiraColors.textPrimary, borderRadius: MiraMetrics.borderRadius),
                        ),
                        Positioned(
                          left: played - _thumb / 2,
                          child: AnimatedContainer(
                            duration: MiraMotion.focus,
                            width: focused ? _thumb : _thumb * 0.6,
                            height: focused ? _thumb : _thumb * 0.6,
                            decoration: const BoxDecoration(color: MiraColors.textPrimary, shape: BoxShape.circle),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
                SizedBox(
                  width: 140,
                  child: Text('-${_clock(left)}',
                      textAlign: TextAlign.right, style: MiraType.status.copyWith(color: MiraColors.textTertiary)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Hints extends StatelessWidget {
  const _Hints();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ASCII on purpose: the bundled faces have no arrow glyphs, and a
        // missing glyph renders as a box on a rootfs with no fallback fonts.
        _hint('< >', 'Seek', MiraColors.textFaint),
        const SizedBox(width: 30),
        _hint('OK', 'Pause', MiraColors.accent),
        const SizedBox(width: 30),
        _hint('BACK', 'Stop', MiraColors.textFaint),
      ],
    );
  }

  Widget _hint(String key, String label, Color ring) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(21)),
            border: Border.all(color: ring, width: 2),
          ),
          child: Text(key, style: MiraType.status.copyWith(fontSize: 14, letterSpacing: 0.8, color: ring)),
        ),
        const SizedBox(width: 13),
        Text(label, style: MiraType.status.copyWith(fontSize: 20, color: MiraColors.textPrimary)),
      ],
    );
  }
}
