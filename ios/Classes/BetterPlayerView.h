// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

// BetterPlayerView.h
@interface BetterPlayerView : UIView
@property AVPlayer *player;
@property (readonly) AVPlayerLayer *playerLayer;
/// Fires from -layoutSubviews; lets owner build AVPictureInPictureController
/// only after the layer has non-zero bounds (iOS 14+ auto-PiP requirement).
@property (nonatomic, copy) void (^onLayout)(void);
@end
