import 'package:awesome_video_player/awesome_video_player.dart';
import 'package:awesome_video_player_example/constants.dart';
import 'package:flutter/material.dart';

class PictureInPicturePage extends StatefulWidget {
  @override
  _PictureInPicturePageState createState() => _PictureInPicturePageState();
}

class _PictureInPicturePageState extends State<PictureInPicturePage> {
  late BetterPlayerController _betterPlayerController;
  GlobalKey _betterPlayerKey = GlobalKey();

  @override
  void initState() {
    BetterPlayerConfiguration betterPlayerConfiguration =
        BetterPlayerConfiguration(
      aspectRatio: 16 / 9,
      fit: BoxFit.contain,
    );
    final sources = [
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        Constants.elephantDreamVideoUrl,
      ),
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        Constants.bugBuckBunnyVideoUrl,
      ),
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        Constants.forBiggerBlazesUrl,
      ),
    ];
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerController.setupPlaylist(sources);
    _betterPlayerController.setBetterPlayerGlobalKey(_betterPlayerKey);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Picture in Picture player"),
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Example which shows how to use PiP.",
              style: TextStyle(fontSize: 16),
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(
              controller: _betterPlayerController,
              key: _betterPlayerKey,
            ),
          ),
          ElevatedButton(
            child: Text("Show PiP"),
            onPressed: () {
              _betterPlayerController.enablePictureInPicture(_betterPlayerKey);
            },
          ),
          ElevatedButton(
            child: Text("Disable PiP"),
            onPressed: () async {
              _betterPlayerController.disablePictureInPicture();
            },
          ),
        ],
      ),
    );
  }
}
