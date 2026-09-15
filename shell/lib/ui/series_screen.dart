import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../core/track_choice.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

/// One show: what it is, the episode to watch next, and each season's episodes
/// as a row of stills.
///
/// The primary button plays the next episode straight away, which is what most
/// visits are for. OK on an episode opens its own page - resume, from start,
/// subtitles, mark watched - exactly like a film's.
class SeriesScreen extends StatefulWidget {
  const SeriesScreen({
    super.key,
    required this.source,
    required this.series,
    required this.onOpen,
    required this.onPlay,
    this.libraryChanged,
  });

  final LibrarySource source;
  final MediaItem series;
  final ValueChanged<MediaItem> onOpen;
  final void Function(MediaItem item, {required bool fromStart, TrackChoice? choice}) onPlay;

  /// Bumped when a pushed screen closes: watching an episode moves next-up and
  /// the row's progress, and this screen is still underneath.
  final Listenable? libraryChanged;

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  static const double _thumbWidth = 400;
  static const double _thumbHeight = _thumbWidth * 9 / 16;
  static const double _gap = 28;
  static const double _ringRoom = MiraFocusRing.reach + 2;

  /// Keeps the focused tile's ring and a glimpse of its neighbour in view.
  static const EdgeInsets _reveal = EdgeInsets.symmetric(horizontal: 96);

  List<MediaItem> _seasons = const <MediaItem>[];
  MediaItem? _season;
  List<MediaItem>? _episodes;
  MediaItem? _next;
  MediaItem? _focusedEpisode;
  String? _error;

  final ScrollController _rail = ScrollController();
  final FocusNode _primaryNode = FocusNode(debugLabel: 'series:primary');

  /// One node per season chip. Up from an episode goes to the season being
  /// shown, not the nearest chip: the row scrolls under the chips, so the
  /// nearest was often the next season (found in a widget test).
  final Map<String, FocusNode> _chipNodes = <String, FocusNode>{};

  FocusNode _chipNode(MediaItem season) =>
      _chipNodes.putIfAbsent(season.id, () => FocusNode(debugLabel: 'season:${_seasonName(season)}'));

  KeyEventResult _onEpisodeKey(KeyEvent event) {
    final MediaItem? season = _season;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp && season != null) {
      _chipNode(season).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Right on the last season stays put rather than dropping into the episodes.
  KeyEventResult _onChipKey(int index, KeyEvent event) {
    if (event is! KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight &&
        index == _seasons.length - 1) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    widget.libraryChanged?.addListener(_refresh);
    _load();
    debugAssertReachableAfterFrame(context, screen: 'SeriesScreen');
  }

  @override
  void dispose() {
    widget.libraryChanged?.removeListener(_refresh);
    _rail.dispose();
    _primaryNode.dispose();
    for (final FocusNode node in _chipNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final Future<MediaItem?> next = widget.source.nextUp(widget.series);
      final List<MediaItem> seasons = await widget.source.seasons(widget.series);
      final MediaItem? up = await next;
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _next = up;
      });
      final MediaItem? start = _seasonFor(up, seasons);
      if (start != null) await _showSeason(start, at: up);
    } on JellyfinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// The season of the episode to watch next; otherwise the first numbered
  /// one, so a show never started does not open on its specials.
  static MediaItem? _seasonFor(MediaItem? next, List<MediaItem> seasons) {
    if (seasons.isEmpty) return null;
    for (final MediaItem s in seasons) {
      if (next != null && s.id == next.seasonId) return s;
    }
    return seasons.firstWhere((MediaItem s) => (s.indexNumber ?? 0) > 0, orElse: () => seasons.first);
  }

  Future<void> _showSeason(MediaItem season, {MediaItem? at}) async {
    setState(() {
      _season = season;
      _episodes = null;
      _focusedEpisode = null;
    });
    try {
      final List<MediaItem> episodes = await widget.source.episodes(widget.series, season);
      if (!mounted || _season?.id != season.id) return;
      setState(() => _episodes = episodes);
      // Start the row at the episode to watch next, so Down from the seasons
      // lands on it rather than on episode one.
      final int index = at == null ? 0 : episodes.indexWhere((MediaItem e) => e.id == at.id);
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || !_rail.hasClients) return;
        final double offset = index <= 0 ? 0 : index * (_thumbWidth + _gap);
        _rail.jumpTo(offset.clamp(0.0, _rail.position.maxScrollExtent));
      });
    } on JellyfinException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Back from an episode: next-up and the row's progress may have moved. The
  /// season and focus stay where they were.
  Future<void> _refresh() async {
    final MediaItem? season = _season;
    try {
      final MediaItem? next = await widget.source.nextUp(widget.series);
      final List<MediaItem>? episodes =
          season == null ? null : await widget.source.episodes(widget.series, season);
      if (!mounted) return;
      setState(() {
        _next = next;
        if (episodes != null && _season?.id == season!.id) _episodes = episodes;
      });
    } on JellyfinException {
      // Keep what is on screen; it was right a moment ago.
    }
  }

  /// What the primary button plays: next-up, else this season's first episode.
  MediaItem? get _target {
    if (_next != null) return _next;
    final List<MediaItem>? episodes = _episodes;
    return episodes == null || episodes.isEmpty ? null : episodes.first;
  }

  String get _playLabel {
    final MediaItem? t = _target;
    if (t == null) return 'Play';
    final String what = t.episodeLabel ?? t.name;
    return t.canResume ? 'Resume $what' : 'Play $what';
  }

  static String _seasonName(MediaItem season) => switch (season.indexNumber) {
        null => 'Extras',
        0 => 'Specials',
        _ => season.name,
      };

  @override
  Widget build(BuildContext context) {
    final Uri? backdrop = widget.source.backdropFor(widget.series, maxHeight: 1080);
    return MiraBackdrop(
      tint: placeholderArt(widget.series.id).colors.first,
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
      // The rows run off the right edge, the way rails do on Home.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH - _ringRoom, MiraMetrics.safeV, 0, MiraMetrics.safeV),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(padding: const EdgeInsets.only(left: _ringRoom), child: _header()),
            const SizedBox(height: 22),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(left: _ringRoom),
                child: Text(_error!, style: MiraType.body),
              )
            else ...<Widget>[
              _seasonRow(),
              const SizedBox(height: 14),
              _episodeRow(),
              // Whatever height is left. A fixed-height caption under a
              // Spacer overflowed as soon as a real show's synopsis took two
              // lines in the header (Californication, found in the VM).
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(_ringRoom, 10, MiraMetrics.safeH, 0),
                  child: _episodeCaption(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final MediaItem s = widget.series;
    final int? start = s.productionYear;
    final String years = start == null
        ? ''
        : s.endYear != null && s.endYear != start
            ? '$start – ${s.endYear}'
            : '$start';
    final int numbered = _seasons.where((MediaItem x) => (x.indexNumber ?? 0) > 0).length;
    final int seasons = _seasons.isEmpty ? (s.childCount ?? 0) : numbered;
    final List<String> meta = <String>[
      if (years.isNotEmpty) years,
      if (seasons > 0) '$seasons season${seasons == 1 ? '' : 's'}',
      if (s.officialRating != null) s.officialRating!,
      if (s.genres.isNotEmpty) s.genres.first,
    ];
    final MediaItem? target = _target;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('SERIES', style: MiraType.sectionLabel),
            const SizedBox(height: 18),
            Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: MiraType.hero.copyWith(fontSize: 78)),
            const SizedBox(height: 16),
            Text(meta.join('   ·   '), style: MiraType.meta),
            if (s.overview != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(s.overview!, maxLines: 2, overflow: TextOverflow.ellipsis, style: MiraType.body),
            ],
            const SizedBox(height: 30),
            MiraButton(
              label: _playLabel,
              kind: MiraButtonKind.primary,
              autofocus: true,
              focusNode: _primaryNode,
              onSelect: target == null ? null : () => widget.onPlay(target, fromStart: !target.canResume),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seasonRow() {
    return SizedBox(
      height: MiraMetrics.minControl + _ringRoom * 2,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(_ringRoom, _ringRoom, MiraMetrics.safeH, _ringRoom),
        itemCount: _seasons.length,
        separatorBuilder: (BuildContext context, int i) => const SizedBox(width: 16),
        itemBuilder: (BuildContext context, int i) {
          final MediaItem season = _seasons[i];
          return _SeasonChip(
            label: _seasonName(season),
            count: season.childCount,
            active: season.id == _season?.id,
            focusNode: _chipNode(season),
            onKey: (KeyEvent event) => _onChipKey(i, event),
            onSelect: () => _showSeason(season),
          );
        },
      ),
    );
  }

  Widget _episodeRow() {
    final List<MediaItem>? episodes = _episodes;
    final double height = _thumbHeight + _EpisodeTile.gap + _EpisodeTile.captionHeight + _ringRoom * 2;
    if (episodes == null) return SizedBox(height: height);
    if (episodes.isEmpty) {
      return SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.only(left: _ringRoom, top: _ringRoom),
          child: Text('No episodes in this season.', style: MiraType.body.copyWith(color: MiraColors.textTertiary)),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: ListView.separated(
        controller: _rail,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(_ringRoom, _ringRoom, MiraMetrics.safeH, _ringRoom),
        itemCount: episodes.length,
        separatorBuilder: (BuildContext context, int i) => const SizedBox(width: _gap),
        itemBuilder: (BuildContext context, int i) {
          final MediaItem episode = episodes[i];
          // Focus is watched from outside the tile: the caption under the row
          // describes whichever episode has it.
          return Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (bool focused) {
              if (focused) setState(() => _focusedEpisode = episode);
            },
            child: _EpisodeTile(
              episode: episode,
              width: _thumbWidth,
              debugLabel: 'episode-$i',
              imageUrl: widget.source.thumbFor(episode, maxHeight: _thumbHeight.round()),
              onSelect: () => widget.onOpen(episode),
              onKey: _onEpisodeKey,
            ),
          );
        },
      ),
    );
  }

  Widget _episodeCaption() {
    final MediaItem? e = _focusedEpisode;
    return SizedBox(
      height: 92,
      child: e == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  <String>[if (e.episodeLabel != null) e.episodeLabel!, e.name].join('   ·   '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MiraType.control.copyWith(fontSize: 22),
                ),
                if (e.overview != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    e.overview!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: MiraType.meta.copyWith(fontSize: 19, color: MiraColors.textSecondary),
                  ),
                ],
              ],
            ),
    );
  }
}

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.label,
    required this.active,
    required this.onSelect,
    required this.focusNode,
    this.onKey,
    this.count,
  });

  final String label;
  final int? count;
  final bool active;
  final VoidCallback onSelect;
  final FocusNode focusNode;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      focusNode: focusNode,
      onKey: onKey,
      revealMargin: _SeriesScreenState._reveal,
      debugLabel: 'season:$label',
      builder: (BuildContext context, bool focused) => Container(
        height: MiraMetrics.minControl,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: active ? MiraColors.textPrimary.withValues(alpha: 0.12) : MiraColors.background.withValues(alpha: 0.35),
          borderRadius: MiraMetrics.borderRadius,
          border: Border.all(color: MiraColors.textPrimary.withValues(alpha: active ? 0.22 : 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: MiraType.meta.copyWith(color: active ? MiraColors.textPrimary : MiraColors.textTertiary)),
            if (count != null) ...<Widget>[
              const SizedBox(width: 12),
              Text('$count', style: MiraType.meta.copyWith(fontSize: 16, color: MiraColors.textFaint)),
            ],
          ],
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.width,
    required this.debugLabel,
    required this.onSelect,
    this.imageUrl,
    this.onKey,
  });

  static const double gap = 12;

  /// Fixed, like a poster's, so focus moving along the row shifts nothing.
  static const double captionHeight = 58;

  final MediaItem episode;
  final double width;
  final String debugLabel;
  final Uri? imageUrl;
  final VoidCallback onSelect;
  final KeyEventResult Function(KeyEvent event)? onKey;

  double get _progress {
    final int total = episode.runtime.inMilliseconds;
    if (!episode.canResume || total <= 0) return 0;
    return (episode.resumePosition.inMilliseconds / total).clamp(0.0, 1.0);
  }

  String get _meta {
    final List<String> parts = <String>[
      if (episode.runtime > Duration.zero) '${episode.runtime.inMinutes} min',
      if (episode.played)
        'watched'
      else if (episode.canResume)
        '${(episode.runtime - episode.resumePosition).inMinutes} min left',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final double height = width * 9 / 16;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return MiraFocusable(
      onSelect: onSelect,
      revealMargin: _SeriesScreenState._reveal,
      debugLabel: debugLabel,
      onKey: onKey,
      // The ring hugs the still, not the still plus its caption.
      showRing: false,
      builder: (BuildContext context, bool focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MiraFocusRingBox(
              focused: focused,
              child: Container(
                width: width,
                height: height,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: placeholderArt(episode.id),
                  borderRadius: MiraMetrics.borderRadius,
                  border: focused ? null : Border.all(color: MiraColors.hairline),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (imageUrl != null)
                      Image.network(
                        imageUrl.toString(),
                        fit: BoxFit.cover,
                        cacheHeight: (height * dpr).round(),
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    if (episode.played) const Positioned(top: 12, right: 12, child: _WatchedMark()),
                    if (_progress > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 6,
                          color: MiraColors.textPrimary.withValues(alpha: 0.22),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: _progress,
                            child: const ColoredBox(color: MiraColors.accent),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: gap),
            SizedBox(
              height: captionHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    episode.indexNumber == null ? episode.name : '${episode.indexNumber}.  ${episode.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: focused ? MiraType.tileTitle : MiraType.tileTitleIdle,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _meta,
                    maxLines: 1,
                    style: MiraType.tileTitleIdle.copyWith(
                      fontSize: 17,
                      color: focused ? MiraColors.accent : MiraColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tick on a watched episode's still. Green is the palette's "done"; gold
/// stays reserved for focus.
class _WatchedMark extends StatelessWidget {
  const _WatchedMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: MiraColors.background.withValues(alpha: 0.72),
      ),
      child: CustomPaint(painter: _TickPainter()),
    );
  }
}

class _TickPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    canvas.drawPath(
      Path()
        ..moveTo(7 * s, 12.4 * s)
        ..lineTo(10.4 * s, 15.8 * s)
        ..lineTo(17.2 * s, 8.6 * s),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = MiraColors.positive,
    );
  }

  @override
  bool shouldRepaint(_TickPainter oldDelegate) => false;
}
