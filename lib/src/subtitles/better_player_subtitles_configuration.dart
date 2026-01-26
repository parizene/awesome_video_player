// Flutter imports:
import 'package:flutter/material.dart';

///Configuration of subtitles - colors/padding/font. Used in
///BetterPlayerConfiguration.
class BetterPlayerSubtitlesConfiguration {
  ///Subtitle font size
  final double fontSize;

  ///Subtitle font weight
  final FontWeight fontWeight;

  ///Subtitle font color
  final Color fontColor;

  ///Enable outline (border) of the text
  final bool outlineEnabled;

  ///Color of the outline stroke
  final Color outlineColor;

  ///Outline stroke size
  final double outlineSize;

  ///Font family of the subtitle
  final String fontFamily;

  ///Left padding of the subtitle
  final double leftPadding;

  ///Right padding of the subtitle
  final double rightPadding;

  ///Bottom padding of the subtitle (fixed pixels)
  final double bottomPadding;

  ///Bottom padding as percentage of video height (0.0 - 1.0)
  ///Takes precedence over bottomPadding when set
  final double? bottomPaddingPercent;

  ///Alignment of the subtitle
  final Alignment alignment;

  ///Background color of the subtitle
  final Color backgroundColor;

  ///Inner padding inside the background box
  final EdgeInsets innerPadding;

  /// Enable subtitles. If false, then subtitles will not be displayed.
  final bool enabled;

  const BetterPlayerSubtitlesConfiguration({
    this.fontSize = 14,
    this.fontWeight = FontWeight.normal,
    this.fontColor = Colors.white,
    this.outlineEnabled = true,
    this.outlineColor = Colors.black,
    this.outlineSize = 2.0,
    this.fontFamily = "Roboto",
    this.leftPadding = 8.0,
    this.rightPadding = 8.0,
    this.bottomPadding = 20.0,
    this.bottomPaddingPercent,
    this.alignment = Alignment.center,
    this.backgroundColor = Colors.transparent,
    this.innerPadding = EdgeInsets.zero,
    this.enabled = true,
  }) : assert(
          bottomPaddingPercent == null ||
              (bottomPaddingPercent >= 0.0 && bottomPaddingPercent <= 1.0),
          'bottomPaddingPercent must be between 0.0 and 1.0',
        );
}
