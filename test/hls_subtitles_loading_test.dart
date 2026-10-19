import 'dart:async';
import 'dart:io';

import 'package:awesome_video_player/awesome_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_method_channel.dart';

/// Serves small HLS streams with three subtitle languages and records every
/// request path, so tests can assert what the player downloads. A second
/// episode is served under `/b/`, and one with segmented subtitles (three
/// 10 s WebVTT segments) under `/s/`.
class _HlsFixtureServer {
  late HttpServer _server;
  final List<String> requests = [];
  final Set<String> failingPaths = {};

  /// Paths answered with the master playlist instead of their own content.
  final Set<String> masterPlaylistPaths = {};

  /// Paths answered with the given content instead of their own.
  final Map<String, String> bodies = {};
  final Map<String, Duration> delays = {};

  String get masterUrl => 'http://127.0.0.1:${_server.port}/master.m3u8';

  String get secondMasterUrl =>
      'http://127.0.0.1:${_server.port}/b/master.m3u8';

  String get segmentedMasterUrl =>
      'http://127.0.0.1:${_server.port}/s/master.m3u8';

  static const _master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,URI="master_subs_eng.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Français",LANGUAGE="fra",DEFAULT=NO,AUTOSELECT=YES,URI="master_subs_fra.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Deutsch",LANGUAGE="deu",DEFAULT=NO,AUTOSELECT=YES,URI="master_subs_deu.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=720x1280,SUBTITLES="subs"
master_720p.m3u8
''';

  static String _subsPlaylist(String lang) => '''#EXTM3U
#EXT-X-TARGETDURATION:90
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:90,
master_subs_${lang}_00001.vtt
#EXT-X-ENDLIST
''';

  static String _segmentedSubsPlaylist(String lang) => '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:10,
master_subs_${lang}_00001.vtt
#EXTINF:10,
master_subs_${lang}_00002.vtt
#EXTINF:10,
master_subs_${lang}_00003.vtt
#EXT-X-ENDLIST
''';

  static String _vtt(String text) => '''WEBVTT

00:00:01.000 --> 00:00:03.000
$text
''';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      await Future<void>.delayed(delays[path] ?? Duration.zero);
      final response = request.response;
      final match =
          RegExp(r'^(/b|/s)?/master_subs_(\w{3})(?:_(\d{5})\.vtt|\.m3u8)$')
              .firstMatch(path);
      if (failingPaths.contains(path)) {
        response.statusCode = HttpStatus.notFound;
      } else if (masterPlaylistPaths.contains(path)) {
        response.write(_master);
      } else if (bodies.containsKey(path)) {
        response.write(bodies[path]);
      } else if (RegExp(r'^(/b|/s)?/master\.m3u8$').hasMatch(path)) {
        response.write(_master);
      } else if (match != null && match.group(3) == null) {
        response.write(match.group(1) == '/s'
            ? _segmentedSubsPlaylist(match.group(2)!)
            : _subsPlaylist(match.group(2)!));
      } else if (match != null) {
        final int segment = int.parse(match.group(3)!);
        response.write(_vtt(segment == 1
            ? 'line in ${match.group(2)}'
            : 'line in ${match.group(2)} $segment'));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  }

  List<String> subtitleRequests() =>
      requests.where((p) => p.contains('/master_subs_')).toList();

  Future<void> stop() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test answers every HttpClient request with 400; these tests need
  // real loopback HTTP.
  HttpOverrides.global = null;
  final mockMethodChannel = MockMethodChannel();
  late _HlsFixtureServer server;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            mockMethodChannel.channel, mockMethodChannel.handle);
    server = _HlsFixtureServer();
    await server.start();
  });

  tearDown(() => server.stop());

  Future<BetterPlayerController> setUpPlayer({
    String? url,
    String? preferredSubtitleLanguage,
    String? defaultSubtitleLanguage,
    bool forceDisableSubtitles = false,
    bool lazyLoadAsmsSubtitles = true,
  }) async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url ?? server.masterUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      defaultSubtitleLanguage: defaultSubtitleLanguage,
      forceDisableSubtitles: forceDisableSubtitles,
      lazyLoadAsmsSubtitles: lazyLoadAsmsSubtitles,
    ));
    return controller;
  }

  List<String?> languages(BetterPlayerController controller) =>
      controller.betterPlayerSubtitlesSourceList
          .where((s) => s.type != BetterPlayerSubtitlesSourceType.none)
          .map((s) => s.language)
          .toList();

  test('subtitles off: lists every language but downloads no subtitle files',
      () async {
    final controller = await setUpPlayer(forceDisableSubtitles: true);

    expect(languages(controller), ['eng', 'fra', 'deu']);
    expect(server.subtitleRequests(), isEmpty);
  });

  List<String> lineTexts(BetterPlayerController controller) =>
      controller.subtitlesLines
          .expand((line) => line.texts ?? <String>[])
          .where((text) => text.isNotEmpty)
          .toList();

  test('preferred language: downloads and shows only that language', () async {
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'fra');

    expect(controller.betterPlayerSubtitlesSource?.language, 'fra');
    expect(lineTexts(controller), ['line in fra']);
    expect(server.subtitleRequests(),
        ['/master_subs_fra.m3u8', '/master_subs_fra_00001.vtt']);
  });

  BetterPlayerSubtitlesSource sourceFor(
          BetterPlayerController controller, String language) =>
      controller.betterPlayerSubtitlesSourceList
          .firstWhere((s) => s.language == language);

  test('switching language loads each playlist once and keeps the same source',
      () async {
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'fra');
    final deu = sourceFor(controller, 'deu');
    final fra = sourceFor(controller, 'fra');

    await controller.setupSubtitleSource(deu);
    expect(controller.betterPlayerSubtitlesSource, same(deu));
    expect(lineTexts(controller), ['line in deu']);

    await controller.setupSubtitleSource(fra);
    expect(controller.betterPlayerSubtitlesSource, same(fra));
    expect(lineTexts(controller), ['line in fra']);

    expect(server.subtitleRequests(), [
      '/master_subs_fra.m3u8',
      '/master_subs_fra_00001.vtt',
      '/master_subs_deu.m3u8',
      '/master_subs_deu_00001.vtt',
      '/master_subs_fra_00001.vtt',
    ]);
  });

  test('preferred playlist fails: hides it and falls back to default language',
      () async {
    server.failingPaths.add('/master_subs_fra.m3u8');

    final controller = await setUpPlayer(
        preferredSubtitleLanguage: 'fra', defaultSubtitleLanguage: 'eng');

    expect(controller.betterPlayerSubtitlesSource?.language, 'eng');
    expect(lineTexts(controller), ['line in eng']);
    expect(languages(controller), ['eng', 'deu']);
  });

  test('preferred playlist is not a media playlist: hides it and falls back',
      () async {
    server.masterPlaylistPaths.add('/master_subs_fra.m3u8');

    final controller = await setUpPlayer(
        preferredSubtitleLanguage: 'fra', defaultSubtitleLanguage: 'eng');

    expect(controller.betterPlayerSubtitlesSource?.language, 'eng');
    expect(lineTexts(controller), ['line in eng']);
    expect(languages(controller), ['eng', 'deu']);
  });

  test('picked playlist fails: hides it and keeps current subtitles', () async {
    server.failingPaths.add('/master_subs_deu.m3u8');
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'fra');
    final fra = sourceFor(controller, 'fra');

    await controller.setupSubtitleSource(sourceFor(controller, 'deu'));

    expect(controller.betterPlayerSubtitlesSource, same(fra));
    expect(lineTexts(controller), ['line in fra']);
    expect(languages(controller), ['eng', 'fra']);
  });

  test('without lazy loading, every subtitles playlist is loaded on setup',
      () async {
    final controller = await setUpPlayer(
        preferredSubtitleLanguage: 'fra', lazyLoadAsmsSubtitles: false);

    expect(lineTexts(controller), ['line in fra']);
    expect(server.subtitleRequests(), [
      '/master_subs_eng.m3u8',
      '/master_subs_fra.m3u8',
      '/master_subs_deu.m3u8',
      '/master_subs_fra_00001.vtt',
    ]);
  });

  test('playlist failing after switching away is hidden, selection kept',
      () async {
    server.failingPaths.add('/master_subs_fra.m3u8');
    server.delays['/master_subs_fra.m3u8'] = const Duration(milliseconds: 200);
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'eng');
    final eng = sourceFor(controller, 'eng');

    final fraSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'fra'));
    await controller.setupSubtitleSource(eng);
    await fraSelection;

    expect(controller.betterPlayerSubtitlesSource, same(eng));
    expect(lineTexts(controller), ['line in eng']);
    expect(languages(controller), ['eng', 'deu']);
  });

  test('reselecting a language while it loads downloads it once', () async {
    server.delays['/master_subs_fra.m3u8'] = const Duration(milliseconds: 200);
    final controller = await setUpPlayer(forceDisableSubtitles: true);
    final fra = sourceFor(controller, 'fra');

    final firstFraSelection = controller.setupSubtitleSource(fra);
    final deuSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'deu'));
    final secondFraSelection = controller.setupSubtitleSource(fra);
    await Future.wait([firstFraSelection, deuSelection, secondFraSelection]);

    expect(controller.betterPlayerSubtitlesSource, same(fra));
    expect(lineTexts(controller), ['line in fra']);
    expect(server.subtitleRequests().where((p) => p == '/master_subs_fra.m3u8'),
        hasLength(1));
  });

  test('overlapping failures restore the last loaded subtitles once', () async {
    for (final lang in ['fra', 'deu']) {
      server.failingPaths.add('/master_subs_$lang.m3u8');
      server.delays['/master_subs_$lang.m3u8'] =
          const Duration(milliseconds: 200);
    }
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'eng');
    final eng = sourceFor(controller, 'eng');

    final fraSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'fra'));
    final deuSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'deu'));
    await Future.wait([fraSelection, deuSelection]);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(controller.betterPlayerSubtitlesSource, same(eng));
    expect(lineTexts(controller), ['line in eng']);
    expect(languages(controller), ['eng']);
    expect(server.subtitleRequests().where((p) => p.endsWith('.m3u8')), [
      '/master_subs_eng.m3u8',
      '/master_subs_fra.m3u8',
      '/master_subs_deu.m3u8',
    ]);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('late subtitles of previous data source are not shown', () async {
    server.delays['/master_subs_fra.m3u8'] = const Duration(milliseconds: 100);
    server.delays['/b/master.m3u8'] = const Duration(milliseconds: 400);
    final controller = await setUpPlayer(forceDisableSubtitles: true);

    final fraSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'fra'));
    // The mock platform doesn't initialize a second data source, so the
    // test waits for its subtitles setup instead of setupDataSource.
    unawaited(controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      server.secondMasterUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      forceDisableSubtitles: true,
      lazyLoadAsmsSubtitles: true,
    )));
    await fraSelection;
    expect(lineTexts(controller), isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(languages(controller), ['eng', 'fra', 'deu']);
    expect(controller.betterPlayerSubtitlesSource?.type,
        BetterPlayerSubtitlesSourceType.none);
    expect(lineTexts(controller), isEmpty);
  });

  test(
      'late subtitles are not shown after the same data source is set up again',
      () async {
    server.delays['/master_subs_fra.m3u8'] = const Duration(milliseconds: 100);
    server.delays['/master.m3u8'] = const Duration(milliseconds: 400);
    final controller = await setUpPlayer(forceDisableSubtitles: true);
    final dataSource = controller.betterPlayerDataSource!;

    final fraSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'fra'));
    unawaited(controller.setupDataSource(dataSource));
    await fraSelection;

    expect(lineTexts(controller), isEmpty);
  });

  test('pending subtitles stop loading after dispose', () async {
    server.delays['/master_subs_fra.m3u8'] = const Duration(milliseconds: 100);
    final controller = await setUpPlayer(forceDisableSubtitles: true);

    final fraSelection =
        controller.setupSubtitleSource(sourceFor(controller, 'fra'));
    controller.dispose();
    await fraSelection;

    expect(server.subtitleRequests(), ['/master_subs_fra.m3u8']);
    expect(lineTexts(controller), isEmpty);
  });

  test('late master playlist of previous data source is not applied', () async {
    server.delays['/master.m3u8'] = const Duration(milliseconds: 300);
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());

    // The mock platform doesn't initialize a second data source, so the
    // test waits for subtitles setup instead of setupDataSource.
    unawaited(controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      server.masterUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      forceDisableSubtitles: true,
      lazyLoadAsmsSubtitles: true,
    )));
    unawaited(controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      server.secondMasterUrl,
      videoFormat: BetterPlayerVideoFormat.hls,
      preferredSubtitleLanguage: 'fra',
      lazyLoadAsmsSubtitles: true,
    )));
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(languages(controller), ['eng', 'fra', 'deu']);
    expect(controller.betterPlayerSubtitlesSource?.language, 'fra');
    expect(lineTexts(controller), ['line in fra']);
  });

  void movePosition(BetterPlayerController controller, Duration position) {
    final videoPlayerController = controller.videoPlayerController!;
    videoPlayerController.value =
        videoPlayerController.value.copyWith(position: position);
  }

  void delaySegments(String language, Duration delay) {
    for (int segment = 1; segment <= 3; segment++) {
      server.delays['/s/master_subs_${language}_0000$segment.vtt'] = delay;
    }
  }

  test('segmented subtitles are not added after dispose', () async {
    delaySegments('eng', const Duration(milliseconds: 100));
    final controller = await setUpPlayer(
        url: server.segmentedMasterUrl, preferredSubtitleLanguage: 'eng');

    movePosition(controller, const Duration(seconds: 1));
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 600));

    expect(lineTexts(controller), isEmpty);
  });

  test('segmented subtitles switched away and back add each cue once',
      () async {
    delaySegments('eng', const Duration(milliseconds: 200));
    final controller = await setUpPlayer(
        url: server.segmentedMasterUrl, preferredSubtitleLanguage: 'eng');
    final eng = sourceFor(controller, 'eng');

    movePosition(controller, const Duration(seconds: 1));
    await controller.setupSubtitleSource(sourceFor(controller, 'deu'));
    await controller.setupSubtitleSource(eng);
    movePosition(controller, const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(lineTexts(controller),
        ['line in eng', 'line in eng 2', 'line in eng 3']);
  });

  test('malformed subtitles playlist: hides it and falls back', () async {
    server.bodies['/master_subs_fra.m3u8'] = '''#EXTM3U
#EXT-X-TARGETDURATION:abc
#EXTINF:90,
master_subs_fra_00001.vtt
#EXT-X-ENDLIST
''';

    final controller = await setUpPlayer(
        preferredSubtitleLanguage: 'fra', defaultSubtitleLanguage: 'eng');

    expect(controller.betterPlayerSubtitlesSource?.language, 'eng');
    expect(lineTexts(controller), ['line in eng']);
    expect(languages(controller), ['eng', 'deu']);
  });

  test('malformed cues are skipped and other cues are shown', () async {
    server.bodies['/master_subs_deu_00001.vtt'] = '''WEBVTT

00:00:01.000 --> 00:00:03.000
good line in deu

xx:00:04.000 --> 00:00:05.000
bad timestamp

00:00:06.000-->00:00:07.000
no spaces around arrow
''';
    final controller = await setUpPlayer(preferredSubtitleLanguage: 'fra');
    final deu = sourceFor(controller, 'deu');

    await controller.setupSubtitleSource(deu);

    expect(controller.betterPlayerSubtitlesSource, same(deu));
    expect(lineTexts(controller), ['good line in deu']);
  });
}
