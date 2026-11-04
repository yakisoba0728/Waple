// Runs the real saver callbacks; only AVFoundation's asynchronous decoder/seek boundary is controlled.
#import <objc/runtime.h>
#import <string.h>
#import "../../../Sources/WapleSaver/WapleSaverView.m"

@interface ProbeItem : AVPlayerItem
@property(nonatomic, copy) void (^pendingSeek)(BOOL);
@end
@implementation ProbeItem
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler {
    self.pendingSeek = completionHandler;
}
@end

@interface ProbePlayer : AVPlayer
@property(nonatomic) NSUInteger plays;
@property(nonatomic) NSUInteger pauses;
@end
@implementation ProbePlayer
- (void)play { self.plays += 1; }
- (void)pause { self.pauses += 1; }
@end

static id makeItem(id receiver, SEL selector, NSURL *url) {
    return [[ProbeItem alloc] initWithURL:url];
}
static id makePlayer(id receiver, SEL selector, AVPlayerItem *item) {
    return [[ProbePlayer alloc] initWithPlayerItem:item];
}
@interface ProbeSaver : WapleSaverView
@property(nonatomic, copy) NSDictionary *configuration;
@end
@implementation ProbeSaver
- (id)configuredValueForKey:(NSString *)key { return self.configuration[key]; }
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static void drain(void) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}
static void finish(ProbeItem *item, BOOL success) {
    void (^completion)(BOOL) = item.pendingSeek;
    item.pendingSeek = nil;
    check(completion != nil, @"notification must start a seek");
    completion(success);
    drain();
}
static void end(ProbeItem *item) {
    [NSNotificationCenter.defaultCenter postNotificationName:AVPlayerItemDidPlayToEndTimeNotification object:item];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        method_setImplementation(class_getClassMethod(AVPlayerItem.class, @selector(playerItemWithURL:)), (IMP)makeItem);
        method_setImplementation(class_getClassMethod(AVPlayer.class, @selector(playerWithPlayerItem:)), (IMP)makePlayer);
        ProbeSaver *view = [[ProbeSaver alloc] initWithFrame:NSMakeRect(0, 0, 320, 180) isPreview:YES];
        NSString *message = view.messageLayer.string;
        BOOL english = argc > 2 && strcmp(argv[2], "en") == 0;
        check([message containsString:english ? @"No video to play" : @"재생할 동영상이 없습니다"], @"localized saver-bundle message");
        view.configuration = @{@"videoPath": @(argv[1]), @"videoFitMode": @"fit", @"videoPlaybackRate": @1.5};
        [view startAnimation];
        ProbePlayer *player = (ProbePlayer *)view.player;
        ProbeItem *item = (ProbeItem *)player.currentItem;
        check(player != nil && player.plays == 1, @"start uses the configured player");
        check([view.playerLayer.videoGravity isEqual:AVLayerVideoGravityResizeAspect], @"fit pass-through");
        check(fabsf(player.defaultRate - 1.5f) < 0.001f && player.muted, @"rate pass-through keeps mute policy");
        end(item);
        [view stopAnimation];
        NSUInteger plays = player.plays;
        finish(item, YES);
        check(player.plays == plays, @"late seek completion must not undo stopAnimation");
        [view startAnimation];
        end(item);
        [view stopAnimation];
        [view startAnimation];
        plays = player.plays;
        finish(item, YES);
        check(player.plays == plays, @"old seek must not cross stop/start generation");
        end(item);
        finish(item, YES);
        check(player.plays == plays + 1, @"current active loop resumes");
        end(item);
        plays = player.plays;
        finish(item, NO);
        check(player.plays == plays, @"failed seek must not resume");
        view.configuration = @{@"videoPath": @(argv[1]), @"videoFitMode": @"stretch", @"videoPlaybackRate": @9};
        [view startAnimation];
        check(view.player == player, @"settings change reuses the decoder");
        check([view.playerLayer.videoGravity isEqual:AVLayerVideoGravityResize], @"stretch pass-through");
        check(player.defaultRate == 2, @"untrusted rate is bounded");
        [view stopAnimation];
        NSLog(@"SAVER_LIFECYCLE_OK %@", english ? @"en" : @"ko");
    }
    return 0;
}
