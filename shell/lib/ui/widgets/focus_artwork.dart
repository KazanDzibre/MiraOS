import 'dart:async';

import 'package:flutter/widgets.dart';

/// The focused title's backdrop, drawn behind a screen in place of a plain
/// tint and crossfading as focus moves.
///
/// Two things keep it cheap enough for a Pi 4:
/// - It waits for focus to settle before loading. Holding an arrow along a
///   rail passes a poster every ~100 ms, and decoding a backdrop for each one
///   would cost more than drawing the whole UI.
/// - The previous image stays up until the next one is decoded, so the screen
///   never dips to the bare tint between titles.
///
/// Meant for [MiraBackdrop.art]: it fills the stack under the scrims.
class FocusArtwork extends StatefulWidget {
  const FocusArtwork({
    super.key,
    required this.url,
    this.opacity = 1.0,
    this.settle = const Duration(milliseconds: 220),
  });

  final Uri? url;

  /// Below 1 where posters sit on top and need the contrast.
  final double opacity;
  final Duration settle;

  /// Decoded at this height: a 1280x720 backdrop is sharp behind scrims at
  /// 1080p and a quarter of a full-size decode.
  static const int decodeHeight = 720;

  @override
  State<FocusArtwork> createState() => _FocusArtworkState();
}

class _FocusArtworkState extends State<FocusArtwork> {
  Uri? _shown;
  Timer? _timer;

  static ImageProvider _provider(Uri url) =>
      ResizeImage(NetworkImage(url.toString()), height: FocusArtwork.decodeHeight);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _load(widget.url));
  }

  @override
  void didUpdateWidget(FocusArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url) return;
    _timer?.cancel();
    _timer = Timer(widget.settle, () => _load(widget.url));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _load(Uri? url) {
    if (!mounted || url == _shown) return;
    if (url == null) {
      setState(() => _shown = null);
      return;
    }
    bool failed = false;
    precacheImage(_provider(url), context, onError: (Object _, StackTrace? __) => failed = true).then((_) {
      // Focus may have moved on while it decoded; a failed image keeps the
      // previous one rather than blanking the screen.
      if (mounted && !failed && widget.url == url) setState(() => _shown = url);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Uri? shown = _shown;
    return Positioned.fill(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        // The default layout stacks children loosely and centred, so the image
        // sized itself and sat in a box behind the hero instead of covering
        // the screen (found in the VM).
        layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
          fit: StackFit.expand,
          children: <Widget>[...previous, if (current != null) current],
        ),
        child: shown == null
            ? const SizedBox.expand(key: ValueKey<String>('none'))
            : Opacity(
                key: ValueKey<Uri>(shown),
                opacity: widget.opacity,
                child: SizedBox.expand(
                  child: Image(image: _provider(shown), fit: BoxFit.cover, gaplessPlayback: true),
                ),
              ),
      ),
    );
  }
}
