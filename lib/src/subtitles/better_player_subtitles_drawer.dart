import 'dart:async';
import 'package:awesome_video_player/awesome_video_player.dart';
import 'package:awesome_video_player/src/subtitles/better_player_subtitle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

class BetterPlayerSubtitlesDrawer extends StatefulWidget {
  final List<BetterPlayerSubtitle> subtitles;
  final BetterPlayerController betterPlayerController;
  final BetterPlayerSubtitlesConfiguration? betterPlayerSubtitlesConfiguration;
  final Stream<bool> playerVisibilityStream;

  const BetterPlayerSubtitlesDrawer({
    Key? key,
    required this.subtitles,
    required this.betterPlayerController,
    this.betterPlayerSubtitlesConfiguration,
    required this.playerVisibilityStream,
  }) : super(key: key);

  @override
  _BetterPlayerSubtitlesDrawerState createState() =>
      _BetterPlayerSubtitlesDrawerState();
}

class _BetterPlayerSubtitlesDrawerState
    extends State<BetterPlayerSubtitlesDrawer> {
  final RegExp htmlRegExp =
      // ignore: unnecessary_raw_strings
      RegExp(r"<[^>]*>", multiLine: true);

  VideoPlayerValue? _latestValue;
  BetterPlayerSubtitlesConfiguration? _configuration;
  bool _playerVisible = false;

  ///Stream used to detect if play controls are visible or not
  late StreamSubscription _visibilityStreamSubscription;

  @override
  void initState() {
    _visibilityStreamSubscription =
        widget.playerVisibilityStream.listen((state) {
      setState(() {
        _playerVisible = state;
      });
    });

    if (widget.betterPlayerSubtitlesConfiguration != null) {
      _configuration = widget.betterPlayerSubtitlesConfiguration;
    } else {
      _configuration = setupDefaultConfiguration();
    }

    widget.betterPlayerController.videoPlayerController!
        .addListener(_updateState);

    super.initState();
  }

  (TextStyle inner, TextStyle outer) _buildTextStyles(double fontSize) {
    final outer = TextStyle(
        fontSize: fontSize,
        fontWeight: _configuration!.fontWeight,
        fontFamily: _configuration!.fontFamily,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _configuration!.outlineSize
          ..color = _configuration!.outlineColor);

    final inner = TextStyle(
        fontFamily: _configuration!.fontFamily,
        fontWeight: _configuration!.fontWeight,
        color: _configuration!.fontColor,
        fontSize: fontSize);

    return (inner, outer);
  }

  @override
  void dispose() {
    widget.betterPlayerController.videoPlayerController!
        .removeListener(_updateState);
    _visibilityStreamSubscription.cancel();
    super.dispose();
  }

  ///Called when player state has changed, i.e. new player position, etc.
  void _updateState() {
    if (mounted) {
      setState(() {
        _latestValue =
            widget.betterPlayerController.videoPlayerController!.value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPip = _latestValue?.isPip == true;
    if (isPip && !_configuration!.pipEnable) {
      return const SizedBox.shrink();
    }

    final fontSize = isPip && _configuration!.pipFontSize != null
        ? _configuration!.pipFontSize!
        : _configuration!.fontSize;
    final (innerStyle, outerStyle) = _buildTextStyles(fontSize);

    final BetterPlayerSubtitle? subtitle = _getSubtitleAtCurrentPosition();
    widget.betterPlayerController.renderedSubtitle = subtitle;
    final List<String> subtitles = subtitle?.texts ?? [];
    final List<Widget> textWidgets = subtitles
        .map((text) => _buildSubtitleTextWidget(text, innerStyle, outerStyle))
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final bottomPadding = _configuration!.bottomPaddingPercent != null
            ? constraints.maxHeight * _configuration!.bottomPaddingPercent!
            : _configuration!.bottomPadding;

        return Padding(
          padding: EdgeInsets.only(
            bottom: _playerVisible ? bottomPadding + 30 : bottomPadding,
            left: _configuration!.leftPadding,
            right: _configuration!.rightPadding,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: textWidgets,
          ),
        );
      },
    );
  }

  BetterPlayerSubtitle? _getSubtitleAtCurrentPosition() {
    if (_latestValue == null) {
      return null;
    }

    final Duration position = _latestValue!.position;
    for (final BetterPlayerSubtitle subtitle
        in widget.betterPlayerController.subtitlesLines) {
      if (subtitle.start! <= position && subtitle.end! >= position) {
        return subtitle;
      }
    }
    return null;
  }

  Widget _buildSubtitleTextWidget(
      String subtitleText, TextStyle innerStyle, TextStyle outerStyle) {
    return Row(children: [
      Expanded(
        child: Align(
          alignment: _configuration!.alignment,
          child: _getTextWithStroke(subtitleText, innerStyle, outerStyle),
        ),
      ),
    ]);
  }

  Widget _getTextWithStroke(
      String subtitleText, TextStyle innerStyle, TextStyle outerStyle) {
    return Container(
      color: _configuration!.backgroundColor,
      padding: _configuration!.innerPadding,
      child: Stack(
        children: [
          if (_configuration!.outlineEnabled)
            _buildHtmlWidget(subtitleText, outerStyle)
          else
            const SizedBox(),
          _buildHtmlWidget(subtitleText, innerStyle)
        ],
      ),
    );
  }

  Widget _buildHtmlWidget(String text, TextStyle textStyle) {
    return HtmlWidget(
      text,
      textStyle: textStyle,
    );
  }

  BetterPlayerSubtitlesConfiguration setupDefaultConfiguration() {
    return const BetterPlayerSubtitlesConfiguration();
  }
}
