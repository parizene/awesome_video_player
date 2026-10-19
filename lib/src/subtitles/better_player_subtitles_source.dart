import 'package:awesome_video_player/src/asms/better_player_asms_subtitle_segment.dart';

import 'better_player_subtitles_source_type.dart';

///Representation of subtitles source. Used to define subtitles in Better
/// Player.
class BetterPlayerSubtitlesSource {
  ///Source type
  final BetterPlayerSubtitlesSourceType? type;

  ///Name of the subtitles, default value is "Default subtitles"
  final String? name;

  ///Language code of the subtitles (e.g. "en", "es")
  final String? language;

  ///Url of the subtitles, used with file or network subtitles
  final List<String?>? urls;

  ///Content of subtitles, used when type is memory
  final String? content;

  ///Subtitles selected by default, without user interaction
  final bool? selectedByDefault;

  //Additional headers used in HTTP request. Works only for
  // [BetterPlayerSubtitlesSourceType.memory] source type.
  final Map<String, String>? headers;

  ///Is ASMS segmented source (more than 1 subtitle file). This shouldn't be
  ///configured manually.
  final bool? asmsIsSegmented;

  ///Max. time between segments in milliseconds. This shouldn't be configured
  /// manually.
  final int? asmsSegmentsTime;

  ///List of segments (start,end,url of the segment). This shouldn't be
  ///configured manually.
  final List<BetterPlayerAsmsSubtitleSegment>? asmsSegments;

  ///Url of ASMS subtitles playlist which is loaded when subtitles are
  ///selected. Set only when playlist was not loaded during data source setup.
  ///This shouldn't be configured manually.
  final String? asmsPlaylistUrl;

  BetterPlayerSubtitlesSource({
    this.type,
    this.name = "Default subtitles",
    this.language,
    this.urls,
    this.content,
    this.selectedByDefault,
    this.headers,
    this.asmsIsSegmented,
    this.asmsSegmentsTime,
    this.asmsSegments,
    this.asmsPlaylistUrl,
  });

  ///Creates list with only one subtitles
  static List<BetterPlayerSubtitlesSource> single({
    BetterPlayerSubtitlesSourceType? type,
    String name = "Default subtitles",
    String? url,
    String? content,
    bool? selectedByDefault,
    Map<String, String>? headers,
  }) =>
      [
        BetterPlayerSubtitlesSource(
          type: type,
          name: name,
          urls: [url],
          content: content,
          selectedByDefault: selectedByDefault,
          headers: headers,
        )
      ];
}
