#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenSaver/ScreenSaver.h>
#import <pwd.h>
#import <unistd.h>

// Waple 화면보호기: kr.yaki.waple.saver 도메인의 videoPath 동영상(mp4/mov/m4v)을
// AVPlayerLayer 로 무한 루프(음소거) 재생한다. 경로가 없거나 재생 불가면 검은 화면 + 안내 텍스트.
//
// SPM 은 .saver 번들 타깃을 만들 수 없으므로 이 파일은 scripts/package-app.sh 에서
// clang -bundle 로 직접 컴파일된다(레거시 legacyScreenSaver 호환을 위해 ObjC).
@interface WapleSaverView : ScreenSaverView
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CATextLayer *messageLayer;
@property(nonatomic, strong) id endObserver;
@property(nonatomic, copy) NSString *loadedVideoPath;
@property(nonatomic, copy) NSDictionary *loadedVideoIdentity;
@property(nonatomic) BOOL hasLoadedContent;
@end

@implementation WapleSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.wantsLayer = YES;
        self.layer = [CALayer layer];
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        [self setAnimationTimeInterval:1.0 / 30.0];
        [self reloadContentIfNeeded];
    }
    return self;
}

- (void)dealloc {
    [self tearDownContent];
}

- (void)startAnimation {
    [super startAnimation];
    // ScreenSaverEngine은 같은 인스턴스에 start/stop을 반복 호출한다. 설정이 그대로인데
    // player/observer/layer를 매번 버리면 재생 위치가 0으로 돌아가고 디코더도 재생성된다.
    [self reloadContentIfNeeded];
    [self.player play];
}

- (void)stopAnimation {
    [self.player pause];
    [super stopAnimation];
}

- (void)animateOneFrame {
    [self layoutContent];  // 화면 크기 변화 대응(프리뷰↔전체화면)
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutContent];
}

// 앱(ScreenSaverController)이 CFPreferences 로 써 준 동영상 경로.
// legacyScreenSaver 는 샌드박스라 CFPreferences 조회가 자기 컨테이너로 리다이렉트될 수 있어,
// 실패 시 실제 홈의 ~/Library/Preferences/kr.yaki.waple.saver.plist 를 직접 읽어 폴백한다.
- (NSString *)configuredVideoPath {
    NSString *path = (__bridge_transfer NSString *)CFPreferencesCopyAppValue(
        CFSTR("videoPath"), CFSTR("kr.yaki.waple.saver"));
    if ([path isKindOfClass:NSString.class] && path.length > 0) {
        return path;
    }
    struct passwd *pw = getpwuid(getuid());
    if (!pw || !pw->pw_dir) {
        return nil;
    }
    NSString *plistPath = [NSString stringWithFormat:
        @"%s/Library/Preferences/kr.yaki.waple.saver.plist", pw->pw_dir];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *fromFile = dict[@"videoPath"];
    return [fromFile isKindOfClass:NSString.class] ? fromFile : nil;
}

// 존재하는 파일 + AVFoundation 이 확실히 재생하는 컨테이너만 허용.
- (BOOL)isPlayableVideoPath:(NSString *)path {
    if (path.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return NO;
    }
    return [@[ @"mp4", @"mov", @"m4v" ] containsObject:path.pathExtension.lowercaseString];
}

// 같은 경로의 파일이 원자적으로 교체됐는지 판별한다. 워크숍 재임포트는 최종 경로를
// 유지한 채 새 디렉터리를 옮겨 놓으므로 경로 비교만으로는 이전 AVPlayer가 남을 수 있다.
- (NSDictionary *)videoFileIdentityForPath:(NSString *)path {
    if (path.length == 0) {
        return nil;
    }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (!attributes) {
        return nil;
    }
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSFileAttributeKey key in @[
        NSFileSystemNumber,
        NSFileSystemFileNumber,
        NSFileSize,
        NSFileCreationDate,
        NSFileModificationDate,
    ]) {
        id value = attributes[key];
        if (value) {
            identity[key] = value;
        }
    }
    return identity.count > 0 ? [identity copy] : nil;
}

- (void)reloadContentIfNeeded {
    NSString *path = [self configuredVideoPath];
    BOOL samePath = (path == nil && self.loadedVideoPath == nil)
        || [path isEqualToString:self.loadedVideoPath];
    BOOL playable = [self isPlayableVideoPath:path];
    NSDictionary *videoIdentity = playable ? [self videoFileIdentityForPath:path] : nil;
    BOOL sameIdentity = !playable || (videoIdentity != nil
        && [videoIdentity isEqual:self.loadedVideoIdentity]);
    BOOL contentMatchesState = (playable && self.player != nil)
        || (!playable && self.player == nil);
    if (self.hasLoadedContent && samePath && sameIdentity && contentMatchesState) {
        return;
    }
    [self loadContentForPath:path];
}

- (void)loadContentForPath:(NSString *)path {
    [self tearDownContent];
    self.loadedVideoPath = [path copy];
    self.loadedVideoIdentity = [self videoFileIdentityForPath:path];
    self.hasLoadedContent = YES;
    if (![self isPlayableVideoPath:path]) {
        [self showMessage:@"Waple\n재생할 동영상이 없습니다 — Waple 메뉴에서 동영상 배경을 적용한 뒤 다시 시도하세요."];
        return;
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.muted = YES;  // 화면보호기는 항상 음소거
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.layer addSublayer:self.playerLayer];

    // 끝까지 재생되면 처음으로 되감아 무한 루프.
    __weak typeof(self) weakSelf = self;
    self.endObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        [item seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [weakSelf.player play];
        }];
    }];

    [self layoutContent];
    [self.player play];
}

// 검은 배경 위 중앙 안내 텍스트.
- (void)showMessage:(NSString *)message {
    self.messageLayer = [CATextLayer layer];
    self.messageLayer.string = message;
    self.messageLayer.alignmentMode = kCAAlignmentCenter;
    self.messageLayer.wrapped = YES;
    self.messageLayer.fontSize = 22.0;
    self.messageLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
    CGFloat scale = self.window.screen.backingScaleFactor;
    self.messageLayer.contentsScale = scale > 0.0 ? scale : 1.0;
    [self.layer addSublayer:self.messageLayer];
    [self layoutContent];
}

- (void)layoutContent {
    self.playerLayer.frame = self.bounds;
    self.messageLayer.frame = NSMakeRect(32.0, NSMidY(self.bounds) - 40.0,
                                         NSWidth(self.bounds) - 64.0, 80.0);
}

- (void)tearDownContent {
    if (self.endObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    [self.player pause];
    self.player = nil;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    [self.messageLayer removeFromSuperlayer];
    self.messageLayer = nil;
    self.loadedVideoPath = nil;
    self.loadedVideoIdentity = nil;
    self.hasLoadedContent = NO;
}

@end
