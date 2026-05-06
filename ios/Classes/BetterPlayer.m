// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayer.h"
#import <MediaPlayer/MediaPlayer.h>
#import <awesome_video_player/awesome_video_player-Swift.h>

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;
static void* presentationSizeContext = &presentationSizeContext;


#if TARGET_OS_IOS
void (^__strong _Nonnull _restoreUserInterfaceForPIPStopCompletionHandler)(BOOL);
#endif

@implementation BetterPlayer {
    AVPictureInPictureController *_pipController;
    NSMutableArray<AVPlayerItem*>* _playlistItems;
    __weak BetterPlayerView* _platformView;
    BOOL _pipForegroundObserverInstalled;
    BOOL _autoPipRequestedDeferred;
    // iOS 14+ refuses auto-PiP if layer had zero bounds at init time; track to force rebuild.
    BOOL _pipControllerHasValidBounds;
    BOOL _autoPipDesired;
    BOOL _suppressPlaylistKvo;
    BOOL _currentItemReachedEnd;
    // Tracks user-initiated pause inside PiP overlay; keeps _isPlaying in sync via rate KVO.
    BOOL _pipUserPaused;
    // Set during AVKit's PiP→app restore; blocks our own stopPictureInPicture call.
    BOOL _pipRestoreInProgress;
    // Must be invoked or AVKit hangs the PiP→app transition forever.
    void (^_pipRestoreCompletion)(BOOL);
    BOOL _currentItemKvoInstalled;
    // Saved to restore on dispose; enabling PiP changes AVAudioSession category.
    NSString* _priorAudioSessionCategory;
    AVAudioSessionMode _priorAudioSessionMode;
    BOOL _priorAudioSessionSaved;
    // Set inside didStopPictureInPicture; blocks setPictureInPicture:false from
    // re-entering AVKit's stop transition and wedging the main thread.
    BOOL _pipStopInProgress;
    // Wall-clock time of the last stall-recovery play(); rate-limits handleStalled
    // so transient rate=0 dips after PiP exit cannot drive an infinite play() loop.
    NSTimeInterval _lastStallRecoveryAt;
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _player = [[AVQueuePlayer alloc] init];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    [_player addObserver:self
              forKeyPath:@"currentItem"
                 options:NSKeyValueObservingOptionNew
                 context:nil];
    _currentItemKvoInstalled = YES;
    _playlistItems = [NSMutableArray array];
    // Ignore iOS accessibility caption settings - Flutter renders subtitles
    _player.appliesMediaSelectionCriteriaAutomatically = NO;
    // Must be YES for PiP correctness: with NO, iOS doesn't wait for buffer and
    // immediately drops rate to 0 after play() if buffer is empty (e.g. after a
    // pause inside PiP). That spurious rate-drop fires our rate KVO, flips
    // _pipUserPaused back to YES, and the PiP overlay gets stuck in paused
    // state with play tap doing nothing. With YES, iOS reports tcs=Waiting and
    // resumes silently when buffer is ready.
    if (@available(iOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = true;
    }
    self._observersAdded = false;
    self.isNaturalSizeLoaded = false;
    self.isPreferredTransformLoaded = false;
    self.isDurationLoaded = false;
    self.cachedDuration = kCMTimeZero;
    self.isNominalFrameRateLoaded = false;
    self.cachedNominalFrameRate = 0;
    return self;
}

- (nonnull UIView *)view {
    BetterPlayerView *playerView = [[BetterPlayerView alloc] initWithFrame:CGRectZero];
    playerView.player = _player;
    BetterPlayerView* previousView = _platformView;
    _platformView = playerView;

    // Rebuild PiP controller once the layer has non-zero bounds (iOS 14+ requirement).
    __weak typeof(self) weakSelf = self;
    __weak BetterPlayerView* weakView = playerView;
    playerView.onLayout = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        BetterPlayerView* v = weakView;
        if (strongSelf == nil || v == nil || strongSelf->_disposed) return;
        CGRect b = v.bounds;
        if (b.size.width <= 0 || b.size.height <= 0) return;
        BOOL needsRebuild = strongSelf->_autoPipRequestedDeferred
            || (strongSelf->_pipController != nil && !strongSelf->_pipControllerHasValidBounds);
        if (!needsRebuild) return;
        if (!strongSelf->_autoPipDesired) {
            strongSelf->_autoPipRequestedDeferred = NO;
            return;
        }
        // Don't tear down during active PiP — AVKit drives the close animation through it.
        if (strongSelf->_pipController != nil &&
            strongSelf->_pipController.pictureInPictureActive) {
            return;
        }
        if (@available(iOS 14.2, *)) {
            strongSelf->_pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
        }
        strongSelf->_pipController.delegate = nil;
        strongSelf->_pipController = nil;
        strongSelf._playerLayer = nil;
        strongSelf->_autoPipRequestedDeferred = NO;
        strongSelf->_pipControllerHasValidBounds = NO;
        [strongSelf setAutoPictureInPictureMode:YES];
    };

    if (_pipController != nil && previousView != nil && previousView != playerView) {
        if (_pipController.pictureInPictureActive) {
            _autoPipRequestedDeferred = _autoPipDesired;
        } else {
            if (@available(iOS 14.2, *)) {
                _pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
            }
            _pipController.delegate = nil;
            _pipController = nil;
            self._playerLayer = nil;
            _autoPipRequestedDeferred = _autoPipDesired;
        }
    }
    if (_autoPipRequestedDeferred && _autoPipDesired) {
        _autoPipRequestedDeferred = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_disposed) return;
            [strongSelf setAutoPictureInPictureMode:YES];
        });
    }
    return playerView;
}

- (void)addObservers:(AVPlayerItem*)item {
    if (!self._observersAdded){
        [_player addObserver:self forKeyPath:@"rate" options:0 context:nil];
        [item addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:timeRangeContext];
        [item addObserver:self forKeyPath:@"status" options:0 context:statusContext];
        [item addObserver:self forKeyPath:@"presentationSize" options:0 context:presentationSizeContext];
        [item addObserver:self
               forKeyPath:@"playbackLikelyToKeepUp"
                  options:0
                  context:playbackLikelyToKeepUpContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferEmpty"
                  options:0
                  context:playbackBufferEmptyContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferFull"
                  options:0
                  context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidPlayToEndTime:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
        self._observersAdded = true;
    }
}

- (void)clear {
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _failedCount = 0;
    _key = nil;
    if (_player.currentItem == nil) {
        return;
    }

    [self removeObservers];

    // Cancel delayed buffer checks on pause
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startStalledCheck) object:nil];

    AVAsset* asset = [_player.currentItem asset];
    [asset cancelLoading];

    [_player replaceCurrentItemWithPlayerItem:nil];

    self.isNaturalSizeLoaded = false;
    self.isPreferredTransformLoaded = false;
    self.isDurationLoaded = false;
    self.cachedDuration = kCMTimeZero;
    self.isNominalFrameRateLoaded = false;
    self.cachedNominalFrameRate = 0;
    self.cachedNaturalSize = CGSizeZero;
    self.cachedPreferredTransform = CGAffineTransformIdentity;
}

- (void) removeObservers{
    if (self._observersAdded){
        [_player removeObserver:self forKeyPath:@"rate" context:nil];
        [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
        [[_player currentItem] removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"loadedTimeRanges"
                                      context:timeRangeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackLikelyToKeepUp"
                                      context:playbackLikelyToKeepUpContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferEmpty"
                                      context:playbackBufferEmptyContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferFull"
                                      context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self._observersAdded = false;
    }
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
    if (_isLooping) {
        AVPlayerItem* p = [notification object];
        __weak typeof(self) weakSelf = self;
        [p seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (finished && strongSelf->_isPlaying) { 
                [strongSelf play];
            }
        }];
    } else if (_playlistItems.count > 0 && _player.items.count > 1) {
        // Reusing the same AVQueuePlayer keeps PiP open across item boundaries.
        [_player advanceToNextItem];
        _currentItemReachedEnd = NO;
        if (_isPlaying) {
            [self play];
        }
    } else {
        _currentItemReachedEnd = YES;
        // Business rule #5: PiP must NOT survive end-of-video. Dismiss the
        // window so the user isn't left staring at a frozen final frame with
        // a stale audio session still active.
        if (_pipController != nil && _pipController.pictureInPictureActive) {
            [_pipController stopPictureInPicture];
        }
        if (_eventSink) {
            _eventSink(@{@"event" : @"completed", @"key" : _key});
            [ self removeObservers];

        }
    }
}


static inline CGFloat radiansToDegrees(CGFloat radians) {
    // Input range [-pi, pi] or [-180, 180]
    CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
    if (degrees < 0) {
        // Convert -90 to 270 and -180 to 180
        return degrees + 360;
    }
    // Output degrees in between [0, 360[
    return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack
                                                      duration:(CMTime)duration
                                              nominalFrameRate:(float)nominalFrameRate
                                                   naturalSize:(CGSize)naturalSize {
    AVMutableVideoCompositionInstruction* instruction =
    [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, duration);
    AVMutableVideoCompositionLayerInstruction* layerInstruction =
    [AVMutableVideoCompositionLayerInstruction
     videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:transform atTime:kCMTimeZero];

    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];

    // If in portrait mode, switch the width and height of the video
    CGFloat width = naturalSize.width;
    CGFloat height = naturalSize.height;
    NSInteger rotationDegrees =
    (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
    if (rotationDegrees == 90 || rotationDegrees == 270) {
        width = naturalSize.height;
        height = naturalSize.width;
    }
    videoComposition.renderSize = CGSizeMake(width, height);

    int fps = 30;
    if (nominalFrameRate > 0) {
        fps = (int) ceil(nominalFrameRate);
    }
    videoComposition.frameDuration = CMTimeMake(1, fps);
    
    return videoComposition;
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
  NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  if (rotationDegrees == 90) {
    transform.tx = videoTrack.naturalSize.height;
    transform.ty = 0;
  } else if (rotationDegrees == 180) {
    transform.tx = videoTrack.naturalSize.width;
    transform.ty = videoTrack.naturalSize.height;
  } else if (rotationDegrees == 270) {
    transform.tx = 0;
    transform.ty = videoTrack.naturalSize.width;
  }
  return transform;
}

- (void)setDataSourceAsset:(NSString*)asset withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration allowedScreenSleep:(BOOL)allowedScreenSleep{
    NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
    return [self setDataSourceURL:[NSURL fileURLWithPath:path] withKey:key withCertificateUrl:certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders: @{} withCache: false cacheKey:cacheKey cacheManager:cacheManager overriddenDuration:overriddenDuration videoExtension: nil allowedScreenSleep:allowedScreenSleep];
}

- (void)setDataSourceURL:(NSURL*)url withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders:(NSDictionary*)headers withCache:(BOOL)useCache cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration videoExtension: (NSString*) videoExtension allowedScreenSleep:(BOOL)allowedScreenSleep{
    _overriddenDuration = 0;
    
    // Set the preventsDisplaySleepDuringVideoPlayback property based on allowedScreenSleep parameter
    if (@available(iOS 12.0, *)) {
        NSLog(@"Setting preventsDisplaySleepDuringVideoPlayback to %d", !allowedScreenSleep);
        _player.preventsDisplaySleepDuringVideoPlayback = !allowedScreenSleep;
    }
    
    if (headers == [NSNull null] || headers == NULL){
        headers = @{};
    }
    
    AVPlayerItem* item;
    if (useCache){
        if (cacheKey == [NSNull null]){
            cacheKey = nil;
        }
        if (videoExtension == [NSNull null]){
            videoExtension = nil;
        }
        
        item = [cacheManager getCachingPlayerItemForNormalPlayback:url cacheKey:cacheKey videoExtension: videoExtension headers:headers];
    } else {
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url
                                                options:@{@"AVURLAssetHTTPHeaderFieldsKey" : headers}];
        if (certificateUrl && certificateUrl != [NSNull null] && [certificateUrl length] > 0) {
            NSURL * certificateNSURL = [[NSURL alloc] initWithString: certificateUrl];
            NSURL * licenseNSURL = [[NSURL alloc] initWithString: licenseUrl];
            _loaderDelegate = [[BetterPlayerEzDrmAssetsLoaderDelegate alloc] init:certificateNSURL withLicenseURL:licenseNSURL];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:_loaderDelegate queue:streamQueue];
        }
        item = [AVPlayerItem playerItemWithAsset:asset];
    }

    if (@available(iOS 10.0, *) && overriddenDuration > 0) {
        _overriddenDuration = overriddenDuration;
    }
    return [self setDataSourcePlayerItem:item withKey:key];
}

- (void)setDataSourcePlayerItem:(AVPlayerItem*)item withKey:(NSString*)key{
    [self prepareCurrentItem:item withKey:key replaceCurrent:YES];
}

- (void)prepareCurrentItem:(AVPlayerItem*)item withKey:(NSString*)key replaceCurrent:(BOOL)replaceCurrent {
    _key = key;
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _playerRate = 1;
    _currentItemReachedEnd = NO;
    if (replaceCurrent) {
        // AVQueuePlayer.replaceCurrentItem empties the queue — playlist mode passes NO.
        [_player replaceCurrentItemWithPlayerItem:item];
    }

    AVAsset* asset = [item asset];
    void (^assetCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded &&
            [asset statusOfValueForKey:@"duration" error:nil] == AVKeyValueStatusLoaded) {
            
            CMTime assetDuration = [asset duration];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.cachedDuration = assetDuration;
                self.isDurationLoaded = true;
            });
            
            NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack* videoTrack = tracks[0];
                void (^trackCompletionHandler)(void) = ^{
                    if (self->_disposed) return;
                    if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                                  error:nil] == AVKeyValueStatusLoaded &&
                        [videoTrack statusOfValueForKey:@"naturalSize"
                                                  error:nil] == AVKeyValueStatusLoaded &&
                        [videoTrack statusOfValueForKey:@"nominalFrameRate"
                                                  error:nil] == AVKeyValueStatusLoaded) {
                        
                        // Prepare values on background thread
                        CGAffineTransform preferredTransform = [self fixTransform:videoTrack];
                        CGSize naturalSize = videoTrack.naturalSize;
                        float nominalFrameRate = videoTrack.nominalFrameRate;

                        // Note:
                        // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                        // Video composition can only be used with file-based media and is not supported for
                        // use with media served using HTTP Live Streaming.
                        AVMutableVideoComposition* videoComposition =
                        [self getVideoCompositionWithTransform:preferredTransform
                                                     withAsset:asset
                                                withVideoTrack:videoTrack
                                                      duration:assetDuration
                                              nominalFrameRate:nominalFrameRate
                                                   naturalSize:naturalSize];
                        item.videoComposition = videoComposition;
                        
                        // Dispatch property updates to main queue for thread safety
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.cachedPreferredTransform = preferredTransform;
                            self.cachedNaturalSize = naturalSize;
                            self.cachedNominalFrameRate = nominalFrameRate;
                            self.isPreferredTransformLoaded = true;
                            self.isNaturalSizeLoaded = true;
                            self.isNominalFrameRateLoaded = true;
                            
                            if (self->_player.status == AVPlayerStatusReadyToPlay) {
                                [self onReadyToPlay];
                            }
                        });
                    }
                };
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform", @"naturalSize", @"nominalFrameRate" ]
                                          completionHandler:trackCompletionHandler];
            } else {
                // Audio-only or no video tracks
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.isPreferredTransformLoaded = true;
                    self.isNaturalSizeLoaded = true;
                    self.isNominalFrameRateLoaded = true;
                    
                    if (self->_player.status == AVPlayerStatusReadyToPlay) {
                        [self onReadyToPlay];
                    }
                });
            }
        }
    };

    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ] completionHandler:assetCompletionHandler];
    [self addObservers:item];
}

-(void)handleStalled {
    if (_isStalledCheckStarted){
        return;
    }
    // Rate-limit: when iOS briefly drops rate to 0 with tcs=Playing (e.g. after
    // PiP exit, audio session re-config, track switch), rate KVO would call
    // handleStalled → play() → KVO fires again → handleStalled, infinite loop.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastStallRecoveryAt < 2.0) {
        return;
    }
    // tcs=Playing with rate=0 is a transient AVPlayer state, not a real stall.
    // tcs=Waiting means iOS is already handling buffer recovery itself
    // (automaticallyWaitsToMinimizeStalling=true) — don't fight it.
    AVPlayerTimeControlStatus tcs = _player.timeControlStatus;
    if (tcs == AVPlayerTimeControlStatusPlaying ||
        tcs == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
        return;
    }
    _isStalledCheckStarted = true;
    [self startStalledCheck];
}

-(void)startStalledCheck{
    // Do not resume if user already swiped to another video
    if (!_isPlaying) {
        _isStalledCheckStarted = false;
        return;
    }

    // Prevent audio starting if app was sent to background during stall
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        _isStalledCheckStarted = false;
        return;
    }

    if (_player.currentItem.playbackLikelyToKeepUp ||
        [self availableDuration] - CMTimeGetSeconds(_player.currentItem.currentTime) > 10.0) {
        _lastStallRecoveryAt = [[NSDate date] timeIntervalSince1970];
        [self play];
    } else {
        _stalledCount++;
        if (_stalledCount > 60){
            if (_eventSink != nil) {
                _eventSink([FlutterError
                        errorWithCode:@"VideoError"
                        message:@"Failed to load video: playback stalled"
                        details:nil]);
            }
            return;
        }
        [self performSelector:@selector(startStalledCheck) withObject:nil afterDelay:1];

    }
}

- (NSTimeInterval) availableDuration
{
    NSArray *loadedTimeRanges = [[_player currentItem] loadedTimeRanges];
    if (loadedTimeRanges.count > 0){
        CMTimeRange timeRange = [[loadedTimeRanges objectAtIndex:0] CMTimeRangeValue];
        Float64 startSeconds = CMTimeGetSeconds(timeRange.start);
        Float64 durationSeconds = CMTimeGetSeconds(timeRange.duration);
        NSTimeInterval result = startSeconds + durationSeconds;
        return result;
    } else {
        return 0;
    }

}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {

    if ([path isEqualToString:@"currentItem"]) {
        if (_suppressPlaylistKvo || _disposed) return;
        if (_eventSink != nil && _playlistItems.count > 0) {
            AVPlayerItem* current = _player.currentItem;
            if (current != nil) {
                NSUInteger idx = [_playlistItems indexOfObjectIdenticalTo:current];
                if (idx != NSNotFound) {
                    _currentItemReachedEnd = NO;
                    _eventSink(@{@"event": @"playlistIndexChanged", @"index": @(idx)});
                }
            }
        }
        return;
    }
    if ([path isEqualToString:@"rate"]) {
        if (@available(iOS 10.0, *)) {
            if (_pipController.pictureInPictureActive == true){
                // PiP overlay drives [_player play/pause] directly, so rate KVO
                // is our only sync point. Dedup against _isPlaying to avoid
                // re-emitting events for our own play()/pause() calls.
                BOOL nowPlaying = _player.rate != 0.0f;
                if (nowPlaying == _isPlaying) {
                    return;
                }
                _isPlaying = nowPlaying;
                _pipUserPaused = !nowPlaying;
                [self syncNowPlayingPlaybackRate];
                if (_eventSink != nil) {
                    _eventSink(@{@"event" : nowPlaying ? @"play" : @"pause"});
                }
                return;
            }
        }

        if (_player.rate == 0 && //if player rate dropped to 0
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, >, kCMTimeZero) && //if video was started
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, <, _player.currentItem.duration) && //but not yet finished
            _isPlaying) { //instance variable to handle overall state (changed to YES when user triggers playback)
            [self handleStalled];
        }
    }

    if (context == timeRangeContext) {
        if (_eventSink != nil) {
            NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
            for (NSValue* rangeValue in [object loadedTimeRanges]) {
                CMTimeRange range = [rangeValue CMTimeRangeValue];
                int64_t start = [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.start)];
                int64_t end = start + [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.duration)];
                if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
                    int64_t endTime = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.forwardPlaybackEndTime)];
                    if (end > endTime){
                        end = endTime;
                    }
                }

                [values addObject:@[ @(start), @(end) ]];
            }
            _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values, @"key" : _key});
        }
    }
    else if (context == presentationSizeContext){
        [self onReadyToPlay];
    }

    else if (context == statusContext) {
        AVPlayerItem* item = (AVPlayerItem*)object;
        switch (item.status) {
            case AVPlayerItemStatusFailed:
                NSLog(@"Failed to load video:");
                NSLog(item.error.debugDescription);

                if (_eventSink != nil) {
                    _eventSink([FlutterError
                                errorWithCode:@"VideoError"
                                message:[@"Failed to load video: "
                                         stringByAppendingString:[item.error localizedDescription]]
                                details:nil]);
                }
                break;
            case AVPlayerItemStatusUnknown:
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self onReadyToPlay];
                break;
        }
    } else if (context == playbackLikelyToKeepUpContext) {
        if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
            // Skip during PiP — rate KVO already syncs _isPlaying; calling
            // updatePlayingState would race it and fight AVKit.
            if (!_pipController || !_pipController.pictureInPictureActive) {
                [self updatePlayingState];
            }
            if (_eventSink != nil) {
                _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
            }
        }
    } else if (context == playbackBufferEmptyContext) {
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingStart", @"key" : _key});
        }
    } else if (context == playbackBufferFullContext) {
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
        }
    }
}

- (void)updatePlayingState {
    if (!_isInitialized || !_key) {
        return;
    }
    if (!self._observersAdded){
        [self addObservers:[_player currentItem]];
    }

    if (_isPlaying) {
        // Use [play] not [playImmediatelyAtRate:] — the latter ignores
        // automaticallyWaitsToMinimizeStalling and forces rate=N even with
        // empty buffer, which iOS then resets to 0 (breaks PiP play tap).
        [_player play];
        if (_playerRate != 1.0f) {
            _player.rate = _playerRate;
        }
    } else {
        [_player pause];
    }
}

- (void)onReadyToPlay {
    if (_eventSink && !_isInitialized && _key) {
        if (!_player.currentItem) {
            return;
        }
        if (_player.status != AVPlayerStatusReadyToPlay) {
            return;
        }
        
        // Fix: Ensure all async properties are loaded before proceeding.
        // This prevents blocking the main thread with synchronous property access.
        if (!self.isNaturalSizeLoaded || !self.isPreferredTransformLoaded || !self.isDurationLoaded) {
            return;
        }

        CGSize size = [_player currentItem].presentationSize;
        CGFloat width = size.width;
        CGFloat height = size.height;

        // Calculate the final dimensions that would be sent to Flutter
        CGSize naturalSize = self.cachedNaturalSize;
        CGAffineTransform prefTrans = self.cachedPreferredTransform;
        CGSize realSize = CGSizeApplyAffineTransform(naturalSize, prefTrans);
        CGFloat finalWidth = fabs(realSize.width) > 0 ? realSize.width : width;
        CGFloat finalHeight = fabs(realSize.height) > 0 ? realSize.height : height;

        // For HLS/streaming, tracks array may be empty initially even for video content,
        // causing cachedNaturalSize to be 0x0. Wait for presentationSize KVO to provide
        // valid dimensions before sending initialized event to Flutter.
        // However, for local audio-only files, dimensions are legitimately 0x0.
        if (finalWidth == 0 && finalHeight == 0) {
            // Check if this is streaming content (HTTP/HTTPS URL)
            BOOL isStreaming = NO;
            AVAsset *asset = _player.currentItem.asset;
            if ([asset isKindOfClass:[AVURLAsset class]]) {
                NSURL *url = ((AVURLAsset *)asset).URL;
                NSString *scheme = [url scheme];
                isStreaming = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
            }

            if (isStreaming) {
                // Streaming content with no dimensions - wait for presentationSize KVO
                return;
            }
            // Local file with no dimensions - audio-only content, proceed
        }
        const BOOL isLive = CMTIME_IS_INDEFINITE(self.cachedDuration);
        // The player may be initialized but still needs to determine the duration.
        if (isLive == false && [self duration] == 0) {
            return;
        }

        int64_t duration = [BetterPlayerTimeUtils FLTCMTimeToMillis:(self.cachedDuration)];
        if (_overriddenDuration > 0 && duration > _overriddenDuration){
            _player.currentItem.forwardPlaybackEndTime = CMTimeMake(_overriddenDuration/1000, 1);
        }

        _isInitialized = true;
        [self updatePlayingState];
        _eventSink(@{
            @"event" : @"initialized",
            @"duration" : @(duration),
            @"width" : @(finalWidth),
            @"height" : @(finalHeight),
            @"key" : _key
        });
    }
}

- (void)play {
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _isPlaying = true;
    // Don't reset _pipUserPaused here — rate KVO clears it and emits the "play" event.
    // Pre-clearing would make the KVO dedup skip the event, leaving Dart stuck at paused.
    [self updatePlayingState];
}

// Keep MPNowPlayingInfoCenter.playbackRate in sync with the player. Stale rate
// here makes iOS dispatch the wrong MPRemoteCommand for the PiP center button
// (always pause, never play), wedging resume after PiP-pause.
- (void)syncNowPlayingPlaybackRate {
    MPNowPlayingInfoCenter* center = [MPNowPlayingInfoCenter defaultCenter];
    NSDictionary* current = center.nowPlayingInfo;
    if (current == nil) return;
    NSMutableDictionary* info = [current mutableCopy];
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.position / 1000.0);
    center.nowPlayingInfo = info;
}

- (void)pause {
    _isPlaying = false;

    // Cancel delayed buffer checks on pause
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(startStalledCheck) object:nil];

    _isStalledCheckStarted = false;

    [self updatePlayingState];
}

- (int64_t)position {
    return [BetterPlayerTimeUtils FLTCMTimeToMillis:([_player currentTime])];
}

- (int64_t)absolutePosition {
    return [BetterPlayerTimeUtils FLTNSTimeIntervalToMillis:([[[_player currentItem] currentDate] timeIntervalSince1970])];
}

- (int64_t)duration {
    CMTime time;
    if (self.isDurationLoaded) {
        time = self.cachedDuration;
    } else if (@available(iOS 13, *)) {
        time =  [[_player currentItem] duration];
    } else {
        time =  [[[_player currentItem] asset] duration];
    }
    if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
        time = [[_player currentItem] forwardPlaybackEndTime];
    }

    return [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];
}

- (void)seekTo:(int)location {
    // Any explicit seek invalidates the "reached end" flag.
    _currentItemReachedEnd = NO;
    // When player is playing, pause video, seek to new position and start again.
    // This will prevent issues with seekbar jumps.
    bool wasPlaying = _isPlaying;
    if (wasPlaying){
        [_player pause];
    }

    __weak typeof(self) weakSelf = self;

    [_player seekToTime:CMTimeMake(location, 1000)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished){
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Ensure that user not paused/swiped video while seek was in progress
        if (wasPlaying && strongSelf->_isPlaying){
            [strongSelf play];
        }
    }];
}

- (void)setPlaylistItems:(NSArray<NSDictionary*>*)items startIndex:(int)startIndex {
    if (_disposed) return;
    if (items == nil || items.count == 0) return;

    int safeStart = startIndex;
    if (safeStart < 0) safeStart = 0;
    if (safeStart >= (int)items.count) safeStart = (int)items.count - 1;

    // Strand-free queue rebuild: prepareCurrentItem will re-attach KVO.
    [self removeObservers];
    // currentItem KVO would otherwise emit playlistIndexChanged for every
    // intermediate state during removeAllItems / insertItem / advanceToNextItem.
    _suppressPlaylistKvo = YES;

    NSMutableArray<AVPlayerItem*>* built = [NSMutableArray arrayWithCapacity:items.count];
    for (id raw in items) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary* entry = (NSDictionary*)raw;
        id uri = entry[@"uri"];
        if (![uri isKindOfClass:[NSString class]] || [(NSString*)uri length] == 0) continue;
        NSURL* nsUrl = [NSURL URLWithString:(NSString*)uri];
        if (nsUrl == nil) continue;

        NSDictionary* headers = entry[@"headers"];
        if (![headers isKindOfClass:[NSDictionary class]]) headers = @{};
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:nsUrl
                                                options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}];

        NSString* certificateUrl = entry[@"certificateUrl"];
        NSString* licenseUrl = entry[@"licenseUrl"];
        if ([certificateUrl isKindOfClass:[NSString class]] && certificateUrl.length > 0
            && [licenseUrl isKindOfClass:[NSString class]] && licenseUrl.length > 0) {
            BetterPlayerEzDrmAssetsLoaderDelegate* loader =
                [[BetterPlayerEzDrmAssetsLoaderDelegate alloc]
                    init:[NSURL URLWithString:certificateUrl]
                    withLicenseURL:[NSURL URLWithString:licenseUrl]];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:loader queue:streamQueue];
        }

        AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
        [built addObject:item];
    }
    if (built.count == 0) return;

    [_playlistItems removeAllObjects];
    [_playlistItems addObjectsFromArray:built];

    [_player removeAllItems];
    for (AVPlayerItem* item in built) {
        if ([_player canInsertItem:item afterItem:nil]) {
            [_player insertItem:item afterItem:nil];
        }
    }
    for (int i = 0; i < safeStart && _player.items.count > 1; i++) {
        [_player advanceToNextItem];
    }

    AVPlayerItem* first = _player.currentItem ?: built[safeStart];
    NSDictionary* startEntry = items[safeStart];
    NSString* uri = ([startEntry[@"uri"] isKindOfClass:[NSString class]])
        ? (NSString*)startEntry[@"uri"] : @"";
    NSString* key = [NSString stringWithFormat:@"playlist:%@", uri];
    _currentItemReachedEnd = NO;
    _suppressPlaylistKvo = NO;
    [self prepareCurrentItem:first withKey:key replaceCurrent:NO];
    if (_eventSink != nil) {
        _eventSink(@{@"event": @"playlistIndexChanged", @"index": @(safeStart)});
    }
}

- (BOOL)isPipActive {
    if (@available(iOS 9.0, *)) {
        return _pipController != nil && _pipController.pictureInPictureActive;
    }
    return NO;
}

- (void)setAutoPictureInPictureMode:(BOOL)enabled {
    if (@available(iOS 14.2, *)) {
        _autoPipDesired = enabled;
        if (enabled) {
            if (_disposed) return;
            [self ensurePipControllerForInlineLayer];
            if (_pipController == nil || self._playerLayer == nil) {
                _autoPipRequestedDeferred = YES;
                return;
            }
            _autoPipRequestedDeferred = NO;
            _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
            [self installPipForegroundObserverIfNeeded];
        } else {
            _autoPipRequestedDeferred = NO;
            _pipControllerHasValidBounds = NO;
            if (_pipController != nil) {
                _pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
                // Don't tear down while PiP is active — didStopPictureInPicture releases it.
                if (!_pipController.pictureInPictureActive) {
                    _pipController = nil;
                    self._playerLayer = nil;
                    [self restorePriorAudioSessionIfNeeded];
                }
            } else {
                self._playerLayer = nil;
                [self restorePriorAudioSessionIfNeeded];
            }
        }
    }
}

// Switches AVAudioSession to Playback/MoviePlayback (required for PiP) and
// snapshots the prior category/mode so we can restore on dispose.
- (void)activatePiPAudioSession {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    if (session.category != AVAudioSessionCategoryPlayback) {
        if (!_priorAudioSessionSaved) {
            _priorAudioSessionCategory = session.category;
            _priorAudioSessionMode = session.mode;
            _priorAudioSessionSaved = YES;
        }
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeMoviePlayback
                     options:0
                       error:nil];
    }
    [session setActive:YES error:nil];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
}

- (void)ensurePipControllerForInlineLayer {
    if (![AVPictureInPictureController isPictureInPictureSupported]) return;
    if (_pipController != nil && self._playerLayer != nil) return;

    BetterPlayerView* view = _platformView;
    if (view == nil) return;
    AVPlayerLayer* layer = view.playerLayer;
    if (layer == nil) return;
    _pipControllerHasValidBounds = !CGRectIsEmpty(layer.bounds);

    [self activatePiPAudioSession];

    self._playerLayer = layer;
    _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
    _pipController.delegate = self;
}

- (void)restorePriorAudioSessionIfNeeded {
    if (!_priorAudioSessionSaved) return;
    AVAudioSession* session = [AVAudioSession sharedInstance];
    [session setCategory:_priorAudioSessionCategory
                    mode:_priorAudioSessionMode
                 options:0
                   error:nil];
    _priorAudioSessionSaved = NO;
    _priorAudioSessionCategory = nil;
}

- (void)installPipForegroundObserverIfNeeded {
    if (_pipForegroundObserverInstalled) return;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onAppDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    _pipForegroundObserverInstalled = YES;
}

- (void)onAppDidBecomeActive:(NSNotification*)note {
    if (_disposed) return;
    // Don't call stopPictureInPicture if AVKit is already driving the expand transition.
    if (_pipRestoreInProgress) return;

    if (@available(iOS 9.0, *)) {
        if (_pipController != nil && _pipController.pictureInPictureActive) {
            // Close PiP on app-icon foreground; defer one runloop in case a restore is in flight.
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf->_disposed) return;
                if (strongSelf->_pipRestoreInProgress) return;
                if (strongSelf->_pipController != nil &&
                    strongSelf->_pipController.pictureInPictureActive) {
                    [strongSelf->_pipController stopPictureInPicture];
                }
            });
            return;
        }
    }
    // X-tap-on-PiP path: iOS silently pauses AVPlayer. Resume if user intended to play.
    if (!_autoPipDesired) return;
    if (_pipController == nil) return;
    if (_isPlaying && !_currentItemReachedEnd && !_pipUserPaused &&
        _player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
        [self play];
    }
}

- (void)nativeSkip:(NSInteger)deltaSeconds {
    AVPlayerItem* item = _player.currentItem;
    if (item == nil) return;
    Float64 cur = CMTimeGetSeconds(item.currentTime);
    Float64 dur = CMTimeGetSeconds(item.duration);
    Float64 target = cur + (Float64)deltaSeconds;

    if (target < 0) {
        [_player seekToTime:kCMTimeZero
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {}];
        return;
    }
    if (deltaSeconds > 0 && !isnan(dur) && target >= dur) {
        // Clamp to duration; itemDidPlayToEndTime fires and dismisses PiP.
        [_player seekToTime:item.duration
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {}];
        if ([self isPipActive]) {
            _currentItemReachedEnd = YES;
            [_pipController stopPictureInPicture];
        }
        return;
    }
    [_player seekToTime:CMTimeMakeWithSeconds(target, NSEC_PER_SEC)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished) {}];
}

- (void)setIsLooping:(bool)isLooping {
    _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
    _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setSpeed:(double)speed result:(FlutterResult)result {
    if (speed < 0 || speed > 2.0) {
        result([FlutterError errorWithCode:@"unsupported_speed"
                                   message:@"Speed must be >= 0.0 and <= 2.0"
                                   details:nil]);
        return;
    }

    _playerRate = (speed == 0.0) ? 1.0 : speed;
    result(nil);

    if (_isPlaying){
        if (@available(iOS 16, *)) {
            _player.defaultRate = _playerRate;
        }
        _player.rate = _playerRate;
    }
}


- (void)setTrackParameters:(int) width: (int) height: (int)bitrate {
    _player.currentItem.preferredPeakBitRate = bitrate;
    if (@available(iOS 11.0, *)) {
        if (width == 0 && height == 0){
            _player.currentItem.preferredMaximumResolution = CGSizeZero;
        } else {
            _player.currentItem.preferredMaximumResolution = CGSizeMake(width, height);
        }
    }
}

- (void)setPictureInPicture:(BOOL)pictureInPicture
{
    self._pictureInPicture = pictureInPicture;
    if (@available(iOS 9.0, *)) {
        if (_pipController && self._pictureInPicture && ![_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController startPictureInPicture];
            });
        } else if (_pipController && !self._pictureInPicture && [_pipController isPictureInPictureActive]) {
            // Don't re-enter stop while AVKit is already mid-transition — that
            // path can deadlock the main thread (watchdog kill on app foreground).
            if (_pipStopInProgress || _pipRestoreInProgress) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController stopPictureInPicture];
            });
        } else {
            // Fallback on earlier versions
        } }
}

#if TARGET_OS_IOS
- (void)setRestoreUserInterfaceForPIPStopCompletionHandler:(BOOL)restore
{
    if (_restoreUserInterfaceForPIPStopCompletionHandler != NULL) {
        _restoreUserInterfaceForPIPStopCompletionHandler(restore);
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
    }
}

- (void)setupPipController {
    if (@available(iOS 9.0, *)) {
        [self activatePiPAudioSession];
        if (!_pipController && self._playerLayer && [AVPictureInPictureController isPictureInPictureSupported]) {
            _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self._playerLayer];
            _pipController.delegate = self;
        }
    }
}

- (void) enablePictureInPicture: (CGRect) frame{
    // The legacy upstream pattern was disable+usePlayerLayer to "reset"
    // the overlay layer. With auto-PiP we want to reuse the inline-bound
    // controller — only tear down when PiP is actually active OR when an
    // overlay layer (non-inline) was previously installed.
    BetterPlayerView* inlineView = _platformView;
    BOOL hasOverlayLayer = self._playerLayer != nil &&
                           inlineView != nil &&
                           self._playerLayer != inlineView.playerLayer;
    BOOL pipActive = _pipController != nil && _pipController.pictureInPictureActive;
    if (hasOverlayLayer || pipActive) {
        [self disablePictureInPicture];
    }
    [self usePlayerLayer:frame];
}

- (void)usePlayerLayer: (CGRect) frame
{
    if( !_player ) return;

    // Reuse the inline-bound auto-PiP controller; recreating the layer here
    // would break canStartPiPAutomaticallyFromInline.
    BetterPlayerView* inlineView = _platformView;
    if (_pipController != nil && inlineView != nil &&
        self._playerLayer == inlineView.playerLayer) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self setPictureInPicture:true];
        });
        return;
    }

    self._playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    UIViewController* vc = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    self._playerLayer.frame = frame;
    self._playerLayer.needsDisplayOnBoundsChange = YES;
    [vc.view.layer addSublayer:self._playerLayer];
    vc.view.layer.needsDisplayOnBoundsChange = YES;
    if (@available(iOS 9.0, *)) {
        _pipController = NULL;
    }
    [self setupPipController];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self setPictureInPicture:true];
    });
}

- (void)disablePictureInPicture
{
    [self setPictureInPicture:false];

    // Removing the inline layer detaches BetterPlayerView's backing layer
    // and blacks out the player on PiP exit; only tear down overlay layers.
    BetterPlayerView* inlineView = _platformView;
    BOOL isInlineLayer = inlineView != nil && self._playerLayer == inlineView.playerLayer;

    if (self._playerLayer && !isInlineLayer) {
        [self._playerLayer removeFromSuperlayer];
        self._playerLayer = nil;
    }
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pipStop"});
    }
}
#endif

#if TARGET_OS_IOS
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    BOOL userPausedInPip = _pipUserPaused;
    _pipUserPaused = NO;
    _pipRestoreInProgress = NO;
    if (_pipRestoreCompletion != nil) {
        _pipRestoreCompletion(YES);
        _pipRestoreCompletion = nil;
    }
    _pipStopInProgress = YES;
    [self disablePictureInPicture];
    _pipStopInProgress = NO;
    if (_disposed) return;

    if (_currentItemReachedEnd) {
        if (_eventSink != nil) {
            _eventSink(@{@"event": @"pause"});
        }
        return;
    }
    if (userPausedInPip) {
        _isPlaying = false;
        [_player pause];
        if (_eventSink != nil) {
            _eventSink(@{@"event": @"pause"});
        }
        return;
    }
    if (_isPlaying && _player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
        [self play];
    } else if (!_isPlaying && _eventSink != nil) {
        _eventSink(@{@"event": @"pause"});
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    _pipUserPaused = (_player.rate == 0.0f);
    _pipRestoreInProgress = NO;
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pipStart"});
    }
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"BetterPlayer: PiP failed to start: %@", error);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    // AVKit blocks PiP→app transition until completionHandler is invoked.
    _pipRestoreInProgress = YES;
    _pipRestoreCompletion = [completionHandler copy];
    [self setRestoreUserInterfaceForPIPStopCompletionHandler:true];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pipRestoreCompletion != nil) {
            self->_pipRestoreCompletion(YES);
            self->_pipRestoreCompletion = nil;
        }
    });
}

- (void) setAudioTrack:(NSString*) name index:(int) index{
    AVMediaSelectionGroup *audioSelectionGroup = [[[_player currentItem] asset] mediaSelectionGroupForMediaCharacteristic: AVMediaCharacteristicAudible];
    NSArray* options = audioSelectionGroup.options;


    for (int audioTrackIndex = 0; audioTrackIndex < [options count]; audioTrackIndex++) {
        AVMediaSelectionOption* option = [options objectAtIndex:audioTrackIndex];
        NSArray *metaDatas = [AVMetadataItem metadataItemsFromArray:option.commonMetadata withKey:@"title" keySpace:@"comn"];
        if (metaDatas.count > 0) {
            NSString *title = ((AVMetadataItem*)[metaDatas objectAtIndex:0]).stringValue;
            if ([name compare:title] == NSOrderedSame && audioTrackIndex == index ){
                [[_player currentItem] selectMediaOption:option inMediaSelectionGroup: audioSelectionGroup];
            }
        }

    }

}

- (void)setMixWithOthers:(bool)mixWithOthers {
  if (mixWithOthers) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}


#endif

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
    // https://github.com/flutter/flutter/issues/21483
    // This line ensures the 'initialized' event is sent when the event
    // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
    // onListenWithArguments is called)
    [self onReadyToPlay];
    return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
    @try{
        [self clear];
    }
    @catch(NSException *exception) {
        NSLog(exception.debugDescription);
    }
}

- (void)dispose {
    [self pause];
    // Route through the canonical disable path so auto-PiP arming is undone
    // even when the inline layer was already torn down.
    if (@available(iOS 14.2, *)) {
        [self setAutoPictureInPictureMode:NO];
    }
    [self disposeSansEventChannel];
    [_eventChannel setStreamHandler:nil];
    [self disablePictureInPicture];
    [self setPictureInPicture:false];
    if (_currentItemKvoInstalled) {
        [_player removeObserver:self forKeyPath:@"currentItem"];
        _currentItemKvoInstalled = NO;
    }
    if (_pipForegroundObserverInstalled) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:UIApplicationDidBecomeActiveNotification
                                                      object:nil];
        _pipForegroundObserverInstalled = NO;
    }
    // Per-instance cleanup — no longer touches a shared global.
    if (_pipController != nil) {
        if (@available(iOS 14.2, *)) {
            _pipController.canStartPictureInPictureAutomaticallyFromInline = NO;
        }
        _pipController.delegate = nil;
        _pipController = nil;
    }
    self._playerLayer = nil;
    _pipControllerHasValidBounds = NO;
    _autoPipDesired = NO;
    _pipUserPaused = NO;
    if (_pipRestoreCompletion != nil) {
        _pipRestoreCompletion(YES);
        _pipRestoreCompletion = nil;
    }
    _pipRestoreInProgress = NO;
    [self restorePriorAudioSessionIfNeeded];
    [_playlistItems removeAllObjects];
    _disposed = true;
}

@end
