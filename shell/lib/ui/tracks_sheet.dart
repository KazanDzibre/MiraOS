import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../core/track_choice.dart';
import '../input/mira_focusable.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';

enum _Tab { subtitles, audio }

/// Subtitles and audio for one film, as a sheet over whatever opened it.
///
/// Search and download go through the Open Subtitles plugin on the Jellyfin
/// server: no OpenSubtitles credentials live on the TV, and a subtitle picked
/// here once is attached to the film for every client.
///
/// Every change is reported immediately through [onChanged], so the screen
/// underneath - detail or a playing film - can react without waiting for the
/// sheet to close.
class TracksSheet extends StatefulWidget {
  const TracksSheet({
    super.key,
    required this.source,
    required this.item,
    required this.initial,
    required this.onChanged,
    this.languages = const <String>['srp', 'hrv', 'eng'],
  });

  final LibrarySource source;
  final MediaItem item;
  final TrackChoice initial;
  final void Function(TrackChoice choice, MediaItem item) onChanged;

  /// Search languages offered, most wanted first.
  final List<String> languages;

  @override
  State<TracksSheet> createState() => _TracksSheetState();
}

class _TracksSheetState extends State<TracksSheet> {
  static const int _onFileShown = 2;

  late MediaItem _item = widget.item;
  late TrackChoice _choice = widget.initial;
  _Tab _tab = _Tab.subtitles;
  bool _showAllOnFile = false;

  late String _language = widget.languages.first;
  List<RemoteSubtitle>? _results;
  bool _searching = false;
  String? _searchError;
  String? _downloadingId;

  @override
  void initState() {
    super.initState();
    _search(_language);
  }

  void _choose(TrackChoice choice) {
    setState(() => _choice = choice);
    widget.onChanged(choice, _item);
  }

  Future<void> _search(String language) async {
    setState(() {
      _language = language;
      _searching = true;
      _searchError = null;
      _results = null;
    });
    try {
      final List<RemoteSubtitle> results = await widget.source.searchSubtitles(_item, language);
      if (!mounted || _language != language) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on JellyfinException catch (e) {
      if (!mounted || _language != language) return;
      setState(() {
        _searchError = e.message;
        _searching = false;
      });
    }
  }

  /// Costs one of the account's daily OpenSubtitles downloads, so it only ever
  /// runs on an explicit OK - never on focus, never speculatively.
  Future<void> _download(RemoteSubtitle subtitle) async {
    if (_downloadingId != null) return;
    setState(() => _downloadingId = subtitle.id);
    try {
      final Set<int> before = _item.subtitleTracks.map((MediaTrack t) => t.index).toSet();
      await widget.source.downloadSubtitle(_item, subtitle);
      final MediaItem refreshed = await widget.source.item(_item.id);
      if (!mounted) return;
      final List<MediaTrack> added = refreshed.subtitleTracks
          .where((MediaTrack t) => !before.contains(t.index))
          .toList();
      MediaTrack? pick;
      for (final MediaTrack t in added) {
        if (t.language == _language) pick = t;
      }
      pick ??= added.isEmpty ? null : added.last;
      setState(() {
        _item = refreshed;
        _downloadingId = null;
      });
      if (pick != null) {
        _choose(_choice.withSubtitle(pick));
      } else {
        widget.onChanged(_choice, _item);
      }
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadingId = null;
        _searchError = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const Positioned.fill(child: ColoredBox(color: MiraColors.scrim)),
        Positioned(
          top: 0,
          right: 0,
          bottom: 0,
          width: MiraMetrics.sheetWidth,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: MiraColors.panel,
              border: Border(left: BorderSide(color: MiraColors.hairline)),
            ),
            child: Stack(
              children: <Widget>[
                // The list ends above the hints rather than scrolling under them:
                // with real OpenSubtitles results the last rows sat behind
                // "OK Choose / BACK Close" (found in the VM; demo data is short).
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: 110,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(64, 64, 64, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(_item.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: MiraType.sectionLabel),
                        const SizedBox(height: 10),
                        Text('Subtitles & audio', style: MiraType.screenTitle.copyWith(fontSize: 44)),
                        const SizedBox(height: 24),
                        Row(
                          children: <Widget>[
                            _Pill(label: 'Subtitles', active: _tab == _Tab.subtitles, autofocus: true, onSelect: () => setState(() => _tab = _Tab.subtitles)),
                            const SizedBox(width: 14),
                            _Pill(
                              label: 'Audio',
                              trailing: '${_item.audioTracks.length} track${_item.audioTracks.length == 1 ? '' : 's'}',
                              active: _tab == _Tab.audio,
                              onSelect: () => setState(() => _tab = _Tab.audio),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        if (_tab == _Tab.subtitles) ..._subtitles() else ..._audio(),
                      ],
                    ),
                  ),
                ),
                const Positioned(left: 64, right: 64, bottom: 40, child: _Hints()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _subtitles() {
    final List<MediaTrack> onFile = _item.subtitleTracks;
    final List<MediaTrack> shown = _showAllOnFile ? onFile : onFile.take(_onFileShown).toList();
    final int hidden = onFile.length - shown.length;
    final List<RemoteSubtitle> results = _results ?? const <RemoteSubtitle>[];

    return <Widget>[
      const _SectionLabel('ON THIS FILE'),
      _TrackRow(title: 'Off', selected: _choice.subtitle == null, onSelect: () => _choose(_choice.withSubtitle(null))),
      for (final MediaTrack t in shown)
        _TrackRow(
          title: trackName(t),
          detail: trackDetail(t),
          selected: _choice.subtitle?.index == t.index,
          onSelect: () => _choose(_choice.withSubtitle(t)),
        ),
      if (hidden > 0)
        _TrackRow(
          title: '$hidden more on this file',
          compact: true,
          onSelect: () => setState(() => _showAllOnFile = true),
        ),
      const SizedBox(height: 22),
      const _SectionLabel('FIND ON OPENSUBTITLES'),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          for (final String lang in widget.languages)
            _Pill(label: languageName(lang), active: _language == lang, onSelect: () => _search(lang)),
        ],
      ),
      const SizedBox(height: 16),
      if (_searching)
        _Note('Searching ${languageName(_language)} subtitles…')
      else if (_searchError != null)
        _Note(_searchError!)
      else if (results.isEmpty)
        _Note('Nothing found in ${languageName(_language)}.')
      else
        for (final RemoteSubtitle r in results.take(8))
          _TrackRow(
            title: r.name.isEmpty ? '${languageName(r.language)} subtitles' : r.name,
            detail: _downloadingId == r.id
                ? 'Downloading…'
                : <String>[
                    '${r.downloads} downloads',
                    if (r.format != null) r.format!.toUpperCase(),
                    if (r.isHashMatch) 'matches this file',
                    if (r.isForced) 'forced',
                    if (r.isHearingImpaired) 'hearing impaired',
                  ].join(' · '),
            download: true,
            onSelect: () => _download(r),
          ),
    ];
  }

  List<Widget> _audio() {
    final List<MediaTrack> tracks = _item.audioTracks;
    final int current = _choice.audio?.index ??
        tracks.firstWhere((MediaTrack t) => t.isDefault, orElse: () => tracks.isEmpty ? const MediaTrack(index: -1, kind: TrackKind.audio) : tracks.first).index;
    return <Widget>[
      const _SectionLabel('ON THIS FILE'),
      if (tracks.isEmpty) const _Note('This file has no separate audio tracks.'),
      for (final MediaTrack t in tracks)
        _TrackRow(
          title: trackName(t),
          detail: trackDetail(t),
          selected: t.index == current,
          onSelect: () => _choose(_choice.withAudio(t.isDefault ? null : t)),
        ),
      if (tracks.length > 1)
        const _Note('Anything but the default track makes the server remux the file. The picture is untouched.'),
    ];
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: MiraType.sectionLabel.copyWith(fontSize: 14, color: MiraColors.textTertiary)),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Text(text, style: MiraType.meta.copyWith(fontSize: 18, color: MiraColors.textTertiary)),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.active, required this.onSelect, this.trailing, this.autofocus = false});

  final String label;
  final String? trailing;
  final bool active;
  final bool autofocus;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      debugLabel: 'pill:$label',
      builder: (BuildContext context, bool focused) => Container(
        height: MiraMetrics.minControl,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: active ? MiraColors.textPrimary.withValues(alpha: 0.10) : null,
          borderRadius: MiraMetrics.borderRadius,
          border: Border.all(color: MiraColors.textPrimary.withValues(alpha: active ? 0.18 : 0.0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: MiraType.meta.copyWith(color: active ? MiraColors.textPrimary : MiraColors.textTertiary)),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              Text(trailing!, style: MiraType.meta.copyWith(fontSize: 16, color: MiraColors.textFaint)),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.title,
    required this.onSelect,
    this.detail,
    this.selected = false,
    this.compact = false,
    this.download = false,
  });

  final String title;
  final String? detail;
  final bool selected;
  final bool compact;
  final bool download;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MiraFocusable(
        onSelect: onSelect,
        debugLabel: 'track:$title',
        builder: (BuildContext context, bool focused) => Container(
          height: compact ? 56 : (download ? 72 : MiraMetrics.minControl),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          decoration: BoxDecoration(
            color: MiraColors.textPrimary.withValues(alpha: focused ? 0.08 : (compact ? 0.0 : 0.04)),
            borderRadius: MiraMetrics.borderRadius,
          ),
          child: Row(
            children: <Widget>[
              if (!compact && !download) ...<Widget>[
                _Radio(selected: selected),
                const SizedBox(width: 18),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MiraType.meta.copyWith(
                        fontSize: compact ? 18 : 20,
                        color: selected || focused ? MiraColors.textPrimary : MiraColors.textPrimary.withValues(alpha: 0.86),
                      ),
                    ),
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: MiraType.meta.copyWith(fontSize: 16, color: MiraColors.textTertiary)),
                    ],
                  ],
                ),
              ),
              if (download) CustomPaint(size: const Size.square(24), painter: _GlyphPainter(_Glyph.download, focused ? MiraColors.textPrimary : MiraColors.textTertiary)),
              if (compact) CustomPaint(size: const Size.square(18), painter: _GlyphPainter(_Glyph.chevronDown, MiraColors.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selection is shown in white. Gold is reserved for focus, so a selected row
/// and a focused row can never be mistaken for each other.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? MiraColors.textPrimary : null,
        border: selected ? null : Border.all(color: MiraColors.textPrimary.withValues(alpha: 0.36), width: 2),
      ),
      child: selected ? CustomPaint(painter: _GlyphPainter(_Glyph.check, MiraColors.background)) : null,
    );
  }
}

enum _Glyph { check, download, chevronDown }

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    switch (glyph) {
      case _Glyph.check:
        p.strokeWidth = 3 * s;
        canvas.drawPath(Path()..moveTo(6.6 * s, 12.4 * s)..lineTo(10.2 * s, 16 * s)..lineTo(17.6 * s, 8.4 * s), p);
      case _Glyph.download:
        p.strokeWidth = 2 * s;
        canvas
          ..drawLine(Offset(12 * s, 4.2 * s), Offset(12 * s, 15.2 * s), p)
          ..drawPath(Path()..moveTo(7.6 * s, 11 * s)..lineTo(12 * s, 15.4 * s)..lineTo(16.4 * s, 11 * s), p)
          ..drawLine(Offset(4.8 * s, 19.2 * s), Offset(19.2 * s, 19.2 * s), p);
      case _Glyph.chevronDown:
        p.strokeWidth = 2 * s;
        canvas.drawPath(Path()..moveTo(6.4 * s, 9.4 * s)..lineTo(12 * s, 15 * s)..lineTo(17.6 * s, 9.4 * s), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) => oldDelegate.glyph != glyph || oldDelegate.color != color;
}

class _Hints extends StatelessWidget {
  const _Hints();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _hint('OK', 'Choose', MiraColors.accent),
        const SizedBox(width: 30),
        _hint('BACK', 'Close', MiraColors.textFaint),
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
