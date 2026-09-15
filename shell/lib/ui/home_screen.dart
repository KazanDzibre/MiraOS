import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../jellyfin/models.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';
import 'widgets/focus_artwork.dart';
import 'widgets/poster.dart';

/// The Cinema home: the focused item fills the screen behind everything, with
/// rails along the bottom - Continue Watching, then Recently added.
///
/// The hero reflects whatever a rail has focused, so moving along a rail is
/// also how you read about a title. That is the whole interaction - there is no
/// separate "select to preview" step.
///
/// The rails share one window one rail tall: Down scrolls the next rail in and
/// the hero stays put, so the screen never becomes a page to scroll through.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.source,
    required this.items,
    this.recent = const <MediaItem>[],
    this.onPlay,
    this.onOpen,
    this.onTab,
  });

  final LibrarySource source;

  /// Continue Watching.
  final List<MediaItem> items;

  /// Recently added, newest first.
  final List<MediaItem> recent;

  final void Function(MediaItem item, {required bool fromStart})? onPlay;

  /// OK on a poster opens its detail; Resume on the hero plays directly.
  final ValueChanged<MediaItem>? onOpen;
  final ValueChanged<String>? onTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Section {
  const _Section(this.label, this.items);

  final String label;
  final List<MediaItem> items;
}

class _HomeScreenState extends State<HomeScreen> {
  static const double _posterWidth = 204;

  /// Room for the focus ring inside the rail, which clips.
  static const double _ringRoom = MiraFocusRing.reach + 2;
  static const double _labelHeight = 44;

  /// How much of the next rail's label shows below the current rail. On a TV
  /// nothing announces "there is more below"; without this peek the second
  /// rail was invisible until you happened to press Down.
  static const double _peek = 36;

  late List<List<FocusNode>> _nodes;
  int _rail = 0;
  int _index = 0;

  /// Snaps the rails window so the focused rail sits at the top. Focus
  /// traversal alone scrolls just far enough to show the rail, which left the
  /// bottom 36 px of the rail above - half-cut captions - visible over the
  /// second rail's label (found in the VM).
  final ScrollController _railsScroll = ScrollController();

  /// One horizontal controller per rail - there are at most two - so Right at
  /// the end of a rail can put the next rail back at its start before focusing
  /// its first poster.
  final List<ScrollController> _railScrolls =
      List<ScrollController>.generate(2, (_) => ScrollController());

  /// How far past the focused poster a rail keeps in view. Traversal alone
  /// stopped with the poster against the screen edge, its focus ring cut off
  /// and nothing of the next poster showing (found in the VM).
  static const double _revealMargin = 96;

  static double get _sectionHeight =>
      _labelHeight + PosterTile.heightFor(_posterWidth) + _ringRoom * 2;

  void _snapToRail(int rail) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || !_railsScroll.hasClients) return;
      final double target = (rail * _sectionHeight)
          .clamp(0.0, _railsScroll.position.maxScrollExtent)
          .toDouble();
      if ((_railsScroll.offset - target).abs() < 0.5) return;
      _railsScroll.animateTo(target, duration: MiraMotion.screen, curve: Curves.easeOut);
    });
  }

  /// Right on a rail's last poster carries on to the next rail's first poster
  /// instead of stopping dead.
  KeyEventResult _railKey(int rail, int index, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final List<_Section> sections = _sections;
    if (index != sections[rail].items.length - 1 || rail + 1 >= sections.length) {
      return KeyEventResult.ignored;
    }
    final ScrollController next = _railScrolls[rail + 1];
    if (next.hasClients) next.jumpTo(0);
    _nodes[rail + 1][0].requestFocus();
    return KeyEventResult.handled;
  }

  List<_Section> get _sections => <_Section>[
        if (widget.items.isNotEmpty) _Section('CONTINUE WATCHING', widget.items),
        if (widget.recent.isNotEmpty) _Section('RECENTLY ADDED', widget.recent),
      ];

  @override
  void initState() {
    super.initState();
    _makeNodes();
    debugAssertReachableAfterFrame(context, screen: 'HomeScreen');
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        oldWidget.recent.length != widget.recent.length) {
      final bool hadFocus = _nodes.any((List<FocusNode> rail) => rail.any((FocusNode n) => n.hasFocus));
      _disposeNodes();
      _makeNodes();
      final List<_Section> sections = _sections;
      _rail = _rail.clamp(0, sections.isEmpty ? 0 : sections.length - 1);
      _index = sections.isEmpty ? 0 : _index.clamp(0, sections[_rail].items.length - 1);
      // A film leaving Continue Watching must not leave the remote with
      // nothing focused - the old node is gone, so hand focus to its neighbour.
      if (hadFocus && sections.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          if (mounted) _nodes[_rail][_index].requestFocus();
        });
      }
    }
  }

  void _makeNodes() {
    final List<_Section> sections = _sections;
    _nodes = <List<FocusNode>>[
      for (int s = 0; s < sections.length; s++)
        List<FocusNode>.generate(sections[s].items.length, (int i) {
          final FocusNode node = FocusNode(debugLabel: 'rail-$s-$i');
          node.addListener(() {
            if (node.hasFocus && mounted && (_rail != s || _index != i)) {
              final bool railChanged = _rail != s;
              setState(() {
                _rail = s;
                _index = i;
              });
              if (railChanged) _snapToRail(s);
            }
          });
          return node;
        }),
    ];
  }

  void _disposeNodes() {
    for (final List<FocusNode> rail in _nodes) {
      for (final FocusNode n in rail) {
        n.dispose();
      }
    }
  }

  @override
  void dispose() {
    _disposeNodes();
    _railsScroll.dispose();
    for (final ScrollController c in _railScrolls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<_Section> sections = _sections;
    final _Section section = sections[_rail.clamp(0, sections.length - 1)];
    final MediaItem current = section.items[_index.clamp(0, section.items.length - 1)];
    final double posterHeight = _posterWidth / MiraMetrics.posterAspect;
    final double railHeight = PosterTile.heightFor(_posterWidth) + _ringRoom * 2;
    final double sectionHeight = _labelHeight + railHeight;

    final String heroLabel = section.label == 'RECENTLY ADDED'
        ? 'RECENTLY ADDED'
        : (current.canResume ? 'CONTINUE WATCHING' : 'FROM YOUR LIBRARY');

    return MiraBackdrop(
      tint: placeholderArt(current.id).colors.first,
      art: FocusArtwork(url: widget.source.backdropFor(current, maxHeight: 1080)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MiraMetrics.safeH,
              MiraMetrics.safeV,
              MiraMetrics.safeH,
              0,
            ),
            child: MiraTopBar(networkLabel: widget.source.label, onTab: widget.onTab),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: MiraMetrics.safeH),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _Hero(
                  item: current,
                  label: heroLabel,
                  onPlay: widget.onPlay,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          // The rails sit slightly outside the safe-area inset so the focus
          // ring has room: ListView clips, and a clipped ring reads as a
          // rendering glitch.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MiraMetrics.safeH - _ringRoom,
              0,
              MiraMetrics.safeH - _ringRoom,
              MiraMetrics.safeV - _ringRoom,
            ),
            child: SizedBox(
              height: sectionHeight + (sections.length > 1 ? _peek : 0),
              // One rail tall, plus a peek of the next rail's label. Focus
              // moving between rails scrolls this through
              // ensureVisible; there is nothing to drag, so it does not scroll
              // under a pointer either.
              child: ListView(
                controller: _railsScroll,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (int s = 0; s < sections.length; s++)
                    SizedBox(
                      height: sectionHeight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SizedBox(
                            height: _labelHeight,
                            child: Padding(
                              padding: const EdgeInsets.only(left: _ringRoom, top: 8),
                              child: Text(
                                sections[s].label,
                                style: MiraType.sectionLabel.copyWith(color: MiraColors.textTertiary),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: railHeight,
                            child: ListView.separated(
                              controller: _railScrolls[s],
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.all(_ringRoom),
                              itemCount: sections[s].items.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 22),
                              itemBuilder: (BuildContext context, int i) {
                                final MediaItem item = sections[s].items[i];
                                return PosterTile(
                                  item: item,
                                  width: _posterWidth,
                                  focusNode: _nodes[s][i],
                                  onKey: (KeyEvent event) => _railKey(s, i, event),
                                  revealMargin: const EdgeInsets.symmetric(horizontal: _revealMargin),
                                  autofocus: s == 0 && i == 0,
                                  imageUrl: widget.source.posterFor(item, maxHeight: posterHeight.round()),
                                  onSelect: () => widget.onOpen != null
                                      ? widget.onOpen!(item)
                                      : widget.onPlay?.call(item, fromStart: !item.canResume),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.item, required this.label, this.onPlay});

  final MediaItem item;
  final String label;
  final void Function(MediaItem item, {required bool fromStart})? onPlay;

  static String _clock(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes.remainder(60);
    return h > 0 ? '$h h $m m' : '$m m';
  }

  static String _resumeLabel(Duration d) {
    final String h = d.inHours.toString();
    final String m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static const double _maxWidth = 820;

  /// Everything in the hero except the title and the synopsis: label, the gaps
  /// around the title and meta, the meta row, the gap above the buttons, the
  /// button row, and a little slack for font metrics.
  static const double _fixedHeight = 18 + 20 + 20 + 32 + 32 + MiraMetrics.minControl + 10;
  static const double _synopsisGap = 20;
  static final double _synopsisLine = MiraType.body.fontSize! * MiraType.body.height!;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _build(context, constraints.maxHeight, constraints.maxWidth),
    );
  }

  Widget _build(BuildContext context, double available, double width) {
    // Titles in a real library wrap - "House of Flying Daggers" and "The Lord
    // of the Rings: The Fellowship of the Ring Extended" both do - so lay the
    // title out first and give the synopsis only the lines that are left. A
    // fixed height threshold ignored whether the title took one line or two,
    // and with the Recently added rail below it the hero overflowed its
    // buttons in the VM.
    final TextPainter title = TextPainter(
      text: TextSpan(text: item.displayTitle, style: MiraType.hero),
      maxLines: 2,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width < _maxWidth ? width : _maxWidth);
    final double titleHeight = title.height;
    title.dispose();

    final int synopsisLines = available.isFinite
        ? ((available - _fixedHeight - titleHeight - _synopsisGap) / _synopsisLine).floor().clamp(0, 3)
        : 3;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: MiraType.sectionLabel),
          const SizedBox(height: 20),
          Text(
            item.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: MiraType.hero,
          ),
          const SizedBox(height: 20),
          _MetaRow(item: item),
          if (item.overview != null && synopsisLines > 0) ...<Widget>[
            const SizedBox(height: 20),
            Text(
              item.overview!,
              maxLines: synopsisLines,
              overflow: TextOverflow.ellipsis,
              style: MiraType.body,
            ),
          ],
          const SizedBox(height: 32),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              MiraButton(
                label: item.canResume
                    ? 'Resume ${_resumeLabel(item.resumePosition)}'
                    : 'Play',
                kind: MiraButtonKind.primary,
                onSelect: () => onPlay?.call(item, fromStart: !item.canResume),
              ),
              if (item.canResume) ...<Widget>[
                const SizedBox(width: 18),
                MiraButton(
                  label: 'From start',
                  onSelect: () => onPlay?.call(item, fromStart: true),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final List<Widget> parts = <Widget>[];

    void text(String s) => parts.add(Text(s, style: MiraType.meta));
    void dot() => parts.add(Container(
          width: 4,
          height: 4,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: MiraColors.textFaint,
          ),
        ));

    if (item.productionYear != null) text('${item.productionYear}');
    if (item.runtime > Duration.zero) {
      if (parts.isNotEmpty) dot();
      text(_Hero._clock(item.runtime));
    }
    if (item.genres.isNotEmpty) {
      if (parts.isNotEmpty) dot();
      text(item.genres.first);
    }
    if (item.videoCodec != null) {
      if (parts.isNotEmpty) dot();
      parts.add(_Chip(
        label: '${item.videoCodec!.toUpperCase()}'
            '${(item.height ?? 0) > 1080 ? ' 4K' : ''}',
      ));
      // Whether the Pi decodes this untouched is the single most useful thing
      // to know about a title on this box, so it is on the hero, not buried.
      parts.add(const SizedBox(width: 10));
      parts.add(_Chip(
        label: item.likelyDirectPlay ? 'DIRECT PLAY' : 'TRANSCODE',
        color: item.likelyDirectPlay ? MiraColors.positive : MiraColors.accent,
      ));
    }

    return Row(mainAxisSize: MainAxisSize.min, children: parts);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? MiraColors.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.55)),
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      child: Text(
        label,
        style: MiraType.meta.copyWith(
          fontSize: 15,
          letterSpacing: 1.2,
          color: color ?? MiraColors.textSecondary,
        ),
      ),
    );
  }
}
