import 'package:flutter/widgets.dart';

/// Design tokens for Mira Shell, in the Cinema direction.
///
/// Values are lifted from the design canvas rather than re-derived. A literal
/// colour or size inside a widget is drift waiting to happen - put it here.
abstract final class MiraColors {
  static const background = Color(0xFF08080A);

  static const textPrimary = Color(0xFFF6F4F0);
  static const textSecondary = Color(0xB3F6F4F0); // 0.70
  static const textTertiary = Color(0x75F6F4F0); // 0.46
  static const textFaint = Color(0x57F6F4F0); // 0.34

  /// Gold means focus, and nothing else. Never use it for decoration.
  static const accent = Color(0xFFE8B04B);
  static const positive = Color(0xFF6FCF8A);
  static const danger = Color(0xFFD9603F);

  static const surface = Color(0x0FF6F4F0); // 0.06
  static const surfaceBorder = Color(0x1AF6F4F0); // 0.10
  static const outline = Color(0x52F6F4F0); // 0.32
  static const hairline = Color(0x12F6F4F0); // 0.07

  /// Dims whatever sits behind a sheet or the player's overlay.
  static const scrim = Color(0x9E060608); // 0.62

  /// The side panel a sheet is drawn in.
  static const panel = Color(0xFF0E0E11);
}

/// Ten-foot type. Sized for ~3 m, not for a desk.
abstract final class MiraType {
  static const _body = 'Archivo';
  static const _display = 'ArchivoBlack';

  // Archivo ships as a variable font, so weight is an axis value rather than a
  // separate file. fontWeight is set alongside for correct fallback metrics.
  static const _w400 = <FontVariation>[FontVariation('wght', 400)];
  static const _w500 = <FontVariation>[FontVariation('wght', 500)];
  static const _w600 = <FontVariation>[FontVariation('wght', 600)];

  static const hero = TextStyle(
    fontFamily: _display,
    fontSize: 88,
    height: 0.94,
    letterSpacing: -1.76,
    color: MiraColors.textPrimary,
  );
  static const screenTitle = TextStyle(
    fontFamily: _display,
    fontSize: 56,
    height: 1.0,
    letterSpacing: -0.84,
    color: MiraColors.textPrimary,
  );
  static const sectionLabel = TextStyle(
    fontFamily: _body,
    fontVariations: _w600,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 4.5, // 0.30em
    color: MiraColors.accent,
  );
  static const body = TextStyle(
    fontFamily: _body,
    fontVariations: _w400,
    fontSize: 22,
    height: 1.5,
    color: MiraColors.textSecondary,
  );
  static const meta = TextStyle(
    fontFamily: _body,
    fontVariations: _w400,
    fontSize: 19,
    color: MiraColors.textSecondary,
  );
  static const control = TextStyle(
    fontFamily: _body,
    fontVariations: _w600,
    fontSize: 21,
    fontWeight: FontWeight.w600,
    color: MiraColors.textPrimary,
  );
  static const tileTitle = TextStyle(
    fontFamily: _body,
    fontVariations: _w600,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: MiraColors.textPrimary,
  );
  static const tileTitleIdle = TextStyle(
    fontFamily: _body,
    fontVariations: _w400,
    fontSize: 18,
    color: MiraColors.textTertiary,
  );
  static const nav = TextStyle(
    fontFamily: _body,
    fontVariations: _w500,
    fontSize: 21,
    color: MiraColors.textTertiary,
  );
  static const status = TextStyle(
    fontFamily: _body,
    fontVariations: _w400,
    fontSize: 18,
    color: MiraColors.textSecondary,
  );

  /// Subtitles over video: large, and outlined by shadow so a bright frame
  /// cannot swallow them. Sized for the couch, not the desk.
  static const subtitle = TextStyle(
    fontFamily: _body,
    fontVariations: _w500,
    fontSize: 40,
    height: 1.3,
    color: MiraColors.textPrimary,
    shadows: <Shadow>[
      Shadow(color: Color(0xE6000000), blurRadius: 6),
      Shadow(color: Color(0xE6000000), offset: Offset(0, 2), blurRadius: 3),
    ],
  );
}

abstract final class MiraMetrics {
  /// Overscan safe area. The TV will eat the edges; assume it does.
  static const safeH = 80.0;
  static const safeV = 72.0;

  /// The gyro pointer jitters and the remote is imprecise. Nothing smaller.
  static const minControl = 68.0;

  static const posterAspect = 2 / 3;

  /// The subtitle and audio sheet's width, from the design.
  static const sheetWidth = 760.0;
  static const radius = Radius.circular(6);
  static const borderRadius = BorderRadius.all(radius);
}

/// The focus ring: 4px gold plus a 6px halo, identical whichever input put it
/// there.
///
/// Stroked rather than filled, and painted outside the control's bounds, so it
/// never tints a transparent interior and never reflows the layout. See
/// MiraFocusRingBox for why a BoxShadow is the wrong tool here.
abstract final class MiraFocusRing {
  /// Solid gold, from the edge outwards.
  static const double width = 4;

  /// The softer halo, sitting just beyond the solid ring.
  static const double haloWidth = 6;
  static const double haloOpacity = 0.22;

  /// Total reach beyond the control's bounds. Layouts must leave this much room
  /// wherever a focusable sits inside something that clips.
  static const double reach = width + haloWidth;
}

abstract final class MiraMotion {
  /// A Cortex-A72 with a VideoCore VI. Short and cheap, or not at all.
  static const focus = Duration(milliseconds: 120);
  static const screen = Duration(milliseconds: 220);
}
