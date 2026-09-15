import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../core/track_choice.dart';
import '../input/focus_debug.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import 'tracks_sheet.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

/// One film: what it is, how it will play, and the way in.
///
/// The media panel says whether the Pi decodes the file untouched. That is the
/// DeviceProfile made visible - when a title transcodes unexpectedly, the
/// reason is on screen instead of behind an ssh session.
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.source,
    required this.item,
    required this.onPlay,
  });

  final LibrarySource source;
  final MediaItem item;
  /// A null choice means the saved tracks were not loaded yet; the player
  /// loads them itself.
  final void Function(MediaItem item, {required bool fromStart, required TrackChoice? choice}) onPlay;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late MediaItem _item = widget.item;
  TrackChoice _choice = const TrackChoice();

  /// Whether [_choice] is known: loaded from what was saved, or picked here.
  bool _tracksKnown = false;

  /// Play/Resume. Focus returns here when a button it was on disappears -
  /// Clear progress removes itself - so the remote is never left stranded.
  final FocusNode _primaryNode = FocusNode(debugLabel: 'detail:primary');
  bool _busy = false;
  String? _notice;

  @override
  void dispose() {
    _primaryNode.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
    debugAssertReachableAfterFrame(context, screen: 'DetailScreen');
  }

  /// Lists arrive without full track data; fetch it so the picker has it, and
  /// the tracks saved for this film.
  Future<void> _load() async {
    try {
      final MediaItem full = await widget.source.item(widget.item.id);
      if (!mounted) return;
      setState(() => _item = full);
      final TrackChoice saved = await widget.source.savedTracks(full);
      // A pick made on this visit while that was loading wins.
      if (!mounted || _tracksKnown) return;
      setState(() {
        _choice = saved;
        _tracksKnown = true;
      });
    } on JellyfinException {
      // The screen still works with what the list gave us.
    }
  }

  /// Runs a Continue Watching change, then shows the server's view of the film
  /// rather than guessing what it became.
  Future<void> _changeProgress(Future<void> Function(MediaItem) change, String done) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await change(_item);
      final MediaItem refreshed = await widget.source.item(_item.id);
      if (!mounted) return;
      setState(() {
        _item = refreshed;
        _notice = done;
      });
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() => _notice = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && FocusManager.instance.primaryFocus?.context == null) {
        _primaryNode.requestFocus();
      }
    });
  }

  void _markWatched() =>
      _changeProgress(widget.source.markWatched, 'Marked as watched. It has left Continue Watching.');

  void _clearProgress() => _changeProgress(
      widget.source.removeFromContinueWatching, 'Progress cleared. It has left Continue Watching.');

  void _openTracks() {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => TracksSheet(
        source: widget.source,
        item: _item,
        initial: _choice,
        onChanged: (TrackChoice choice, MediaItem item) => setState(() {
          _choice = choice;
          _item = item;
          _tracksKnown = true;
        }),
      ),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  static String _clock(Duration d) {
    final String h = d.inHours.toString();
    final String m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _runtime(Duration d) {
    final int h = d.inHours;
    final int m = d.inMinutes.remainder(60);
    return h > 0 ? '$h h $m m' : '$m m';
  }

  MediaTrack? get _audio {
    if (_choice.audio != null) return _choice.audio;
    final List<MediaTrack> audio = _item.audioTracks;
    return audio.isEmpty
        ? null
        : audio.firstWhere((MediaTrack t) => t.isDefault, orElse: () => audio.first);
  }

  @override
  Widget build(BuildContext context) {
    final Uri? backdrop = widget.source.backdropFor(_item, maxHeight: 1080);
    return MiraBackdrop(
      tint: placeholderArt(_item.id).colors.first,
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
            Text(_item.seriesName ?? 'Films', style: MiraType.nav.copyWith(color: MiraColors.textSecondary)),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(child: LayoutBuilder(builder: _hero)),
                  const SizedBox(width: 72),
                  _MediaPanel(item: _item, choice: _choice, audio: _audio),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(BuildContext context, BoxConstraints c) {
    final int synopsisLines = c.maxHeight >= 620 ? 3 : (c.maxHeight >= 540 ? 2 : 1);
    final MediaItem item = _item;
    final List<String> meta = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.runtime > Duration.zero) _runtime(item.runtime),
      if (item.officialRating != null) item.officialRating!,
      if (item.genres.isNotEmpty) item.genres.first,
    ];
    return Align(
      alignment: Alignment.bottomLeft,
      child: ConstrainedBox(
        // Wide enough for all five actions on one row; wrapping them to a second
        // row pushed the hero off a 1080p screen for long titles.
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(item.isEpisode ? (item.episodeLabel ?? 'EPISODE') : 'FILM', style: MiraType.sectionLabel),
            const SizedBox(height: 20),
            Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: MiraType.hero.copyWith(fontSize: 78)),
            const SizedBox(height: 20),
            Text(meta.join('   ·   '), style: MiraType.meta),
            if (item.overview != null) ...<Widget>[
              const SizedBox(height: 20),
              Text(item.overview!, maxLines: synopsisLines, overflow: TextOverflow.ellipsis, style: MiraType.body),
            ],
            const SizedBox(height: 32),
            Wrap(
              spacing: 18,
              runSpacing: 18,
              children: <Widget>[
                MiraButton(
                  label: item.canResume ? 'Resume ${_clock(item.resumePosition)}' : 'Play',
                  kind: MiraButtonKind.primary,
                  autofocus: true,
                  focusNode: _primaryNode,
                  onSelect: () => widget.onPlay(item, fromStart: !item.canResume, choice: _tracksKnown ? _choice : null),
                ),
                if (item.canResume)
                  MiraButton(
                    label: 'From start',
                    onSelect: () => widget.onPlay(item, fromStart: true, choice: _tracksKnown ? _choice : null),
                  ),
                MiraButton(label: 'Subtitles & audio', onSelect: _openTracks),
                MiraButton(label: 'Mark watched', onSelect: _busy ? null : _markWatched),
                if (item.canResume)
                  MiraButton(label: 'Clear progress', onSelect: _busy ? null : _clearProgress),
              ],
            ),
            if (_notice != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(_notice!, style: MiraType.meta),
            ],
          ],
        ),
      ),
    );
  }
}

class _MediaPanel extends StatelessWidget {
  const _MediaPanel({required this.item, required this.choice, required this.audio});

  final MediaItem item;
  final TrackChoice choice;
  final MediaTrack? audio;

  @override
  Widget build(BuildContext context) {
    final String video = <String>[
      if (item.videoCodec != null) item.videoCodec!.toUpperCase(),
      if (item.width != null && item.height != null) '${item.width} × ${item.height}',
    ].join(' · ');

    final (String verdict, String why, bool good) = !item.likelyDirectPlay
        ? ('TRANSCODE', 'The server converts this file for the Pi', false)
        : choice.burnsInSubtitle
            ? ('TRANSCODE', 'The chosen subtitles are burned into the picture', false)
            : choice.needsServerWork
                ? ('REMUX', 'Video untouched; the server swaps the audio', false)
                : ('DIRECT PLAY', 'Decoded on the Pi, no transcode', true);

    return Container(
      width: 430,
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: MiraColors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: MiraColors.surfaceBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('MEDIA', style: MiraType.sectionLabel.copyWith(fontSize: 14, color: MiraColors.textTertiary)),
          const SizedBox(height: 22),
          _row('Video', video.isEmpty ? 'Unknown' : video),
          _row('Audio', audio == null ? 'Unknown' : '${trackName(audio!)} · ${trackDetail(audio!)}'),
          _row('Subtitles', choice.subtitle == null ? 'Off' : trackName(choice.subtitle!)),
          Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 6), color: MiraColors.surfaceBorder),
          const SizedBox(height: 16),
          Text(verdict, style: MiraType.control.copyWith(fontSize: 19, color: good ? MiraColors.positive : MiraColors.textPrimary)),
          const SizedBox(height: 4),
          Text(why, style: MiraType.meta.copyWith(fontSize: 16, color: MiraColors.textTertiary)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: MiraType.meta.copyWith(fontSize: 16, color: MiraColors.textTertiary)),
          const SizedBox(height: 4),
          Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: MiraType.meta.copyWith(fontSize: 20, color: MiraColors.textPrimary)),
        ],
      ),
    );
  }
}
