import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';
import '../../input/mira_focusable.dart';
import '../../jellyfin/models.dart';

/// Stand-in artwork for an item with no poster on the server.
///
/// Deterministic from the id, so a given title always looks the same rather
/// than shuffling every rebuild.
LinearGradient placeholderArt(String seed) {
  final int h = seed.hashCode;
  final List<List<Color>> palettes = <List<Color>>[
    <Color>[Color(0xFF6D4630), Color(0xFF2B1C15)],
    <Color>[Color(0xFF35696B), Color(0xFF0A1A1C)],
    <Color>[Color(0xFF3C3F63), Color(0xFF17182A)],
    <Color>[Color(0xFF5E5442), Color(0xFF23201A)],
    <Color>[Color(0xFF2F4A35), Color(0xFF121D16)],
    <Color>[Color(0xFF6A3540), Color(0xFF24131A)],
    <Color>[Color(0xFF2B4F66), Color(0xFF0F1E28)],
  ];
  final List<Color> pair = palettes[h.abs() % palettes.length];
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: pair,
  );
}

/// Watched-so-far along the foot of a poster. White on a scrim, never gold:
/// gold means focus, and this is state.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction});

  static const double height = 6;

  final double fraction;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: MiraColors.scrim,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: fraction,
        heightFactor: 1,
        child: const ColoredBox(color: MiraColors.textPrimary),
      ),
    );
  }
}

/// A 2:3 poster with its title underneath.
class PosterTile extends StatelessWidget {
  /// Gap between artwork and caption.
  static const double gap = 12;

  /// Caption block height, fixed on purpose.
  ///
  /// The focused tile shows an extra line of metadata. If the caption grew to
  /// fit, every tile in the rail would shift as focus moved along it - so the
  /// space is always reserved, focused or not.
  static const double captionHeight = 58;

  /// Total height of a tile of the given width.
  static double heightFor(double width) =>
      width / MiraMetrics.posterAspect + gap + captionHeight;

  const PosterTile({
    super.key,
    required this.item,
    required this.width,
    this.imageUrl,
    this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.onKey,
    this.revealMargin,
  });

  final MediaItem item;
  final double width;
  final Uri? imageUrl;
  final VoidCallback? onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final KeyEventResult Function(KeyEvent event)? onKey;
  final EdgeInsets? revealMargin;

  @override
  Widget build(BuildContext context) {
    final double height = width / MiraMetrics.posterAspect;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;

    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      focusNode: focusNode,
      onKey: onKey,
      revealMargin: revealMargin,
      debugLabel: 'poster:${item.name}',
      // The ring hugs the artwork, not the artwork plus its caption.
      showRing: false,
      builder: (BuildContext context, bool focused) {
        return SizedBox(
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
                    gradient: placeholderArt(item.id),
                    borderRadius: MiraMetrics.borderRadius,
                    border: focused
                        ? null
                        : Border.all(color: MiraColors.hairline),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (imageUrl != null)
                        Image.network(
                          imageUrl.toString(),
                          fit: BoxFit.cover,
                          // Decode to what is displayed. A full-size poster
                          // costs more to decode than the whole UI does to draw.
                          cacheHeight: (height * dpr).round(),
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      if (_progress(item) > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _ProgressBar(fraction: _progress(item)),
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
                      item.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: focused ? MiraType.tileTitle : MiraType.tileTitleIdle,
                    ),
                    if (focused && item.productionYear != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        _focusedMeta(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MiraType.tileTitleIdle
                            .copyWith(color: MiraColors.accent, fontSize: 17),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// How far into the film, 0 when not started. Continue Watching reads at a
  /// glance from the rail instead of needing each hero.
  static double _progress(MediaItem item) {
    final int total = item.runtime.inMilliseconds;
    if (!item.canResume || total <= 0) return 0;
    return (item.resumePosition.inMilliseconds / total).clamp(0.0, 1.0);
  }

  static String _focusedMeta(MediaItem item) {
    final List<String> parts = <String>[
      if (item.episodeLabel != null) item.episodeLabel!,
      if (item.productionYear != null) '${item.productionYear}',
      if (item.isSeries && item.childCount != null)
        '${item.childCount} season${item.childCount == 1 ? '' : 's'}',
      if (item.likelyDirectPlay && item.videoCodec != null)
        '${item.videoCodec!.toUpperCase()} ${item.height != null && item.height! > 1080 ? '4K' : 'HD'}',
    ];
    return parts.join(' · ');
  }
}
