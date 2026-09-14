import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';

/// Focus and scrolling shared by Mira's poster grids - Films, Genres, Discover
/// and search results - so all of them move the same way under a remote:
///
///  * **The focused row sits at the top of the grid.** Flutter's traversal only
///    scrolls until the focused tile's edge touches the viewport's, which left
///    the row at the bottom with its focus ring clipped and the grid creeping
///    rather than paging.
///  * **Right at the end of a row carries on to the next row's first tile**,
///    and Left at the start of a row goes back to the previous row's last one,
///    instead of stopping dead.
///
/// Owns the grid's ScrollController and one FocusNode per tile. The screen
/// passes both to its GridView and tiles, and sets [rowExtent] during layout.
class GridFocus {
  GridFocus({required this.columns, required this.debugName, this.wrapLeft = true});

  final int columns;
  final String debugName;

  /// Off where Left from the first column has somewhere better to go - the
  /// on-screen keyboard beside search results.
  final bool wrapLeft;

  final ScrollController scroll = ScrollController();
  final Map<int, FocusNode> _nodes = <int, FocusNode>{};

  /// One row's height plus the spacing below it. Depends on the screen width,
  /// so the grid sets it during layout, along with the spacing on its own.
  double rowExtent = 0;
  double mainAxisSpacing = 0;
  int itemCount = 0;

  FocusNode nodeFor(int index) => _nodes.putIfAbsent(index, () {
        final FocusNode node = FocusNode(debugLabel: '$debugName-$index');
        node.addListener(() {
          if (node.hasFocus) _snapRow(index ~/ columns);
        });
        return node;
      });

  /// Bottom padding that lets the last row rise to the top like every other
  /// row. Without it the final rows could never reach the top.
  double bottomPadding(double viewportHeight, {required double top, required double minimum}) =>
      math.max(minimum, viewportHeight - top - rowExtent + mainAxisSpacing);

  double _offsetFor(int row) =>
      (row * rowExtent).clamp(0.0, scroll.position.maxScrollExtent).toDouble();

  void _snapRow(int row) {
    // After the frame, so this lands after the traversal's own ensureVisible
    // and replaces it, rather than being replaced by it.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!scroll.hasClients || rowExtent <= 0) return;
      final double target = _offsetFor(row);
      if ((scroll.offset - target).abs() < 0.5) return;
      scroll.animateTo(target, duration: MiraMotion.screen, curve: Curves.easeOut);
    });
  }

  /// For each tile's MiraFocusable.onKey.
  KeyEventResult handleKey(int index, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight && index % columns == columns - 1 && index + 1 < itemCount) {
      _focus(index + 1);
      return KeyEventResult.handled;
    }
    if (wrapLeft && key == LogicalKeyboardKey.arrowLeft && index % columns == 0 && index > 0) {
      _focus(index - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focus(int index) {
    final FocusNode node = nodeFor(index);
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    // Not built - its row is outside the grid's cache. Bring the row in first;
    // the tile builds on the next frame and takes focus then.
    if (scroll.hasClients && rowExtent > 0) scroll.jumpTo(_offsetFor(index ~/ columns));
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => node.requestFocus());
  }

  void dispose() {
    for (final FocusNode node in _nodes.values) {
      node.dispose();
    }
    scroll.dispose();
  }
}
