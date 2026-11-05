// VideoStarTool.mm - Dynamic Library for Video Star
// High-performance Beat Detection Integration with VSBeatCore & Advanced Overlay Tooling
// Target: iOS / ARM64 (dylib)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <CoreMedia/CoreMedia.h>
#include <vector>
#include <cmath>
#include <algorithm>
// Tích hợp lõi phân tích Beat C++ mới
#include "VSBeatCore.hpp"
// Forward Declarations
@class VSToolOverlay;
@class VSLogoView;
@class VSPassthroughWindow;
@class VSOverlayViewController;
static VSToolOverlay *g_overlayInstance = nil;
static VSPassthroughWindow *g_overlayWindow = nil;
static UIImage *g_customLogoImage = nil;
static NSData *g_lastCodeData = nil;
// ─────────────────────────────────────────────────────────────────────────────
// AUDIO EXTRACTION UTILITY
// ─────────────────────────────────────────────────────────────────────────────
static std::vector<float> ExtractMonoPCM(AVAsset *asset, double targetSampleRate, double *outDuration) {
    std::vector<float> pcmData;
    if (!asset) return pcmData;
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error || !reader) return pcmData;
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) return pcmData;
    AVAssetTrack *audioTrack = tracks.firstObject;
    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(targetSampleRate),
        AVNumberOfChannelsKey: @(1),
        AVLinearPCMBitDepthKey: @(32),
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:outputSettings];
    [reader addOutput:output];
    if (![reader startReading]) return pcmData;
    if (outDuration) {
        *outDuration = CMTimeGetSeconds(asset.duration);
    }
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (!sampleBuffer) break;
        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (blockBuffer) {
            size_t length = CMBlockBufferGetDataLength(blockBuffer);
            size_t sampleCount = length / sizeof(float);
            size_t currentSize = pcmData.size();
            pcmData.resize(currentSize + sampleCount);
            CMBlockBufferCopyDataBytes(blockBuffer, 0, length, pcmData.data() + currentSize);
        }
        CFRelease(sampleBuffer);
    }
    return pcmData;
}
// ─────────────────────────────────────────────────────────────────────────────
// VSLogoView Implementation
// ─────────────────────────────────────────────────────────────────────────────

@interface VSLogoView : UIView
@end

@implementation VSLogoView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(self.bounds, point);
}
@end
// ─────────────────────────────────────────────────────────────────────────────
// VSQRCaptureProxy Implementation
// ─────────────────────────────────────────────────────────────────────────────

@interface VSQRCaptureProxy : NSProxy
@property (nonatomic, weak) id target;
@property (nonatomic, copy) id captured;
@end

@implementation VSQRCaptureProxy

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *s = [self.target methodSignatureForSelector:sel];
    return s ? s : [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    if ([self.target respondsToSelector:inv.selector]) [inv invokeWithTarget:self.target];
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    return [self.target respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.target respondsToSelector:aSelector]) {
        return self.target;
    }
    return nil;
}
- (id)dataToShare {
    if ([self.target respondsToSelector:@selector(dataToShare)]) {
        return [self.target dataToShare];
    }
    return nil;
}
- (void)importedData:(id)arg1 code:(id)arg2 {
    if (self.captured) {
        void (^block)(id, id, id) = (void (^)(id, id, id))self.captured;
        block(self, arg1, arg2);
    }
}
- (void)setActivityiPadPopup:(id)arg1 {
    if ([self.target respondsToSelector:@selector(setActivityiPadPopup:)]) {
        [self.target setActivityiPadPopup:arg1];
    }
}
- (id)codePrefix {
    if ([self.target respondsToSelector:@selector(codePrefix)]) {
        id res = [self.target codePrefix];
        return res ? res : @"";
    }
    return @"";
}
- (id)qrLabel {
    if ([self.target respondsToSelector:@selector(qrLabel)]) {
        id res = [self.target qrLabel];
        return res ? res : @"";
    }
    return @"";
}
- (id)qrSetupLabel {
    if ([self.target respondsToSelector:@selector(qrSetupLabel)]) {
        id res = [self.target qrSetupLabel];
        return res ? res : @"";
    }
    return @"";
}
- (id)qrImage {
    if ([self.target respondsToSelector:@selector(qrImage)]) {
        return [self.target qrImage];
    }
    return nil;
}
- (id)qrIcon {
    if ([self.target respondsToSelector:@selector(qrIcon)]) {
        return [self.target qrIcon];
    }
    return nil;
}
- (BOOL)validCode:(id)arg1 {
    if (self.target && [self.target respondsToSelector:@selector(validCode:)]) {
        return [self.target validCode:arg1];
    }
    return YES;
}
@end
// ─────────────────────────────────────────────────────────────────────────────
// VSToolOverlay Implementation
// ─────────────────────────────────────────────────────────────────────────────

@interface VSToolOverlay : UIView <UIGestureRecognizerDelegate> {
    @public
    NSInteger _selectedTab;
    NSInteger _activeFeature;
    NSMutableArray *_featureStates;
    // UI Elements
    UIView *_panel;
    VSLogoView *_logoControl;
    UIPanGestureRecognizer *_logoPanGesture;
    UITapGestureRecognizer *_logoTapGesture;
    UILabel *_brandLabel;
    UILabel *_subtitleLabel;
    UIButton *_closeButton;
    NSArray *_tabButtons;
    UIScrollView *_contentScrollView;
    UIView *_footerLeftRule;
    UIView *_footerRightRule;
    UILabel *_footerLabel;
    UIView *_panelDragHandle;
    UIPanGestureRecognizer *_panelPanGesture;
    // Flow UI
    UIView *_flowView;
    UILabel *_flowTitle;
    UILabel *_flowMessage;
    UIScrollView *_flowScroll;
    UIButton *_flowPrimaryButton;
    UIButton *_flowSecondaryButton;
    UIImageView *_flowImageView;
    // State Tracking
    CGPoint _normalizedLogoPosition;
    BOOL _hasSavedLogoPosition;
    BOOL _didInitialLogoPosition;
    BOOL _logoGestureActive;
    CGPoint _logoPanStartCenter;
    CGPoint _normalizedPanelPosition;
    BOOL _hasSavedPanelPosition;
    BOOL _didInitialPanelPosition;
    BOOL _panelPositionNeedsRestore;
    CGPoint _panelPanStartCenter;
    CGSize _lastOverlaySize;
    CGSize _lastPanelSize;
    // Feature 2: Auto Beat Split (VSBeatCore System)
    BOOL _beatSplitRunning;
    id _beatSplitView;
    id _beatSplitProject;
    NSUInteger _beatSplitSceneBefore;
    NSUInteger _beatSplitQueued;
    NSUInteger _beatSplitGuard;
    NSUInteger _beatSplitNoAdvanceRetries;
    CMTime _beatSplitLastTime;
    NSUInteger _beatSplitInitialSplitCount;
    std::vector<vsbeat::Event> _calculatedBeatEvents;
    NSUInteger _currentBeatEventIndex;
    // Merge System
    NSMutableArray *_mergeCodeImages;
    NSMutableArray *_mergePresets;
    NSMutableArray *_tempMergeNavigators;
    id _mediaSourceEditor;
    NSInteger _mediaSourceMode;
    BOOL _mediaPickerResponseHandled;
    id _mediaPickerResponse;
    id _mediaApplyResponse;
    BOOL _mediaApplyInProgress;
    id _mediaApplyEditor;
    id _mediaApplyEngine;
    NSArray *_mediaApplyLayers;
    NSUInteger _mediaApplyIndex;
    NSUInteger _mediaApplyChanged;
    id _mediaApplyCompletion;
    UIImage *_mediaApplyImage;
    AVAsset *_mediaApplyAsset;
    id _mediaBeforeLayer;
    id _mediaBeforeGenerator;
    UIImage *_mediaBeforeImage;
    AVAsset *_mediaBeforeAsset;
    BOOL _mergeWaitingForNativeImport;
    id _mergeImportEditor;
    NSUInteger _mergeImportOffset;
    id _mergeQRPreviousDelegate;
    UIImage *_pendingMediaImage;
    NSURL *_pendingMediaURL;
    AVAsset *_pendingMediaAsset;
    id _mergeProject;
    id _mergeReviewVC;
    id _mediaSourceNav;
    NSUInteger _mergeStartScene;
    NSUInteger _mergeEndScene;
    NSUInteger _mergeCodeIndex;
    NSUInteger _mergeOriginalLastViewedSceneIndex;
    id _qrPreviousDelegate;
    VSQRCaptureProxy *_qrCaptureProxy;
    id _singleCodePicker;
    NSUInteger _singleCodePickerIndex;
}
- (void)openPanel;
- (void)closePanel;
- (void)togglePanel;
- (void)showSimpleAlert:(NSString *)title message:(NSString *)message index:(NSInteger)index;
- (void)finishFeatureIndex:(NSInteger)index;
- (void)startFeatureBeatSplit;
- (void)beatSplitAdvanceStepWithAttempt:(NSUInteger)attempt;
- (void)finishBeatSplitNativeWorkflow;
@end

@implementation VSToolOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        g_overlayInstance = self;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _selectedTab = 0;
        _activeFeature = -1;
        _featureStates = [NSMutableArray arrayWithCapacity:4];
        for (int i = 0; i < 4; i++) {
            [_featureStates addObject:@NO];
        }
        _mergeCodeImages = [NSMutableArray array];
        _mergePresets = [NSMutableArray array];
        _tempMergeNavigators = [NSMutableArray array];
        _beatSplitRunning = NO;
        _beatSplitView = nil;
        _beatSplitProject = nil;
        _beatSplitLastTime = kCMTimeInvalid;
        // Custom Logo Setup
        _logoControl = [[VSLogoView alloc] initWithFrame:CGRectMake(20, 40, 52, 52)];
        _logoControl.backgroundColor = [UIColor clearColor];
        _logoControl.layer.shadowColor = [UIColor colorWithRed:0.4 green:0.6 blue:1.0 alpha:1.0].CGColor;
        _logoControl.layer.shadowRadius = 12.0;
        _logoControl.layer.shadowOpacity = 0.8;
        _logoControl.layer.shadowOffset = CGSizeMake(0, 2);
        UIImageView *logoImgView = [[UIImageView alloc] initWithFrame:_logoControl.bounds];
        logoImgView.contentMode = UIViewContentModeScaleAspectFit;
        logoImgView.clipsToBounds = NO;
        UIImage *custImage = [self loadCustomLogo];
        if (custImage) {
            logoImgView.image = custImage;
        }
        [_logoControl addSubview:logoImgView];
        _logoPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleLogoPan:)];
        _logoPanGesture.maximumNumberOfTouches = 1;
        _logoPanGesture.minimumNumberOfTouches = 1;
        _logoTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleLogoTap:)];
        [_logoTapGesture requireGestureRecognizerToFail:_logoPanGesture];
        [_logoControl addGestureRecognizer:_logoPanGesture];
        [_logoControl addGestureRecognizer:_logoTapGesture];
        [self addSubview:_logoControl];
        [self bringSubviewToFront:_logoControl];
    }
    return self;
}
- (UIImage *)loadCustomLogo {
    if (g_customLogoImage) return g_customLogoImage;
    NSString *homeDir = NSHomeDirectory();
    NSString *docPath = [homeDir stringByAppendingPathComponent:@"Documents/VideoStarToolLogo.png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:docPath]) {
        g_customLogoImage = [UIImage imageWithContentsOfFile:docPath];
        return g_customLogoImage;
    }
    // Default fallback logo drawing dynamically
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(52, 52), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 48, 48)];
    [[UIColor colorWithRed:0.15 green:0.15 blue:0.25 alpha:0.9] setFill];
    [path fill];
    [[UIColor colorWithRed:0.4 green:0.6 blue:1.0 alpha:1.0] setStroke];
    path.lineWidth = 2.0;
    [path stroke];
    NSDictionary *attr = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    NSString *txt = @"VS";
    CGSize sz = [txt sizeWithAttributes:attr];
    [txt drawAtPoint:CGPointMake((52 - sz.width)/2, (52 - sz.height)/2) withAttributes:attr];
    g_customLogoImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return g_customLogoImage;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_panel && !_panel.isHidden) {
        if (CGRectContainsPoint(_panel.frame, point)) return YES;
    }
    if (_logoControl) {
        CGRect logoRect = CGRectInset(_logoControl.frame, -8, -8);
        if (CGRectContainsPoint(logoRect, point)) return YES;
    }
    if (_flowView && !_flowView.isHidden) {
        if (CGRectContainsPoint(_flowView.frame, point)) return YES;
    }
    return NO;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    if (w <= 0 || h <= 0) return;
    if (!_didInitialLogoPosition) {
        _logoControl.center = CGPointMake(w - 40, 100);
        _didInitialLogoPosition = YES;
    }
    [self clampLogoPosition];
}
- (void)clampLogoPosition {
    if (!_logoControl) return;
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGPoint c = _logoControl.center;
    c.x = std::max((CGFloat)30.0, std::min((CGFloat)(w - 30.0), c.x));
    c.y = std::max((CGFloat)30.0, std::min((CGFloat)(h - 30.0), c.y));
    _logoControl.center = c;
}
- (void)handleLogoTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        [self togglePanel];
    }
}
- (void)handleLogoPan:(UIPanGestureRecognizer *)gesture {
    CGPoint trans = [gesture translationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        _logoPanStartCenter = _logoControl.center;
        _logoControl.alpha = 0.7;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        _logoControl.center = CGPointMake(_logoPanStartCenter.x + trans.x, _logoPanStartCenter.y + trans.y);
        [self clampLogoPosition];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        _logoControl.alpha = 1.0;
        [self clampLogoPosition];
    }
}
- (void)togglePanel {
    if (_panel) {
        [self closePanel];
    } else {
        [self openPanel];
    }
}
- (void)openPanel {
    if (_panel) return;
    CGFloat pw = std::min((CGFloat)(CGRectGetWidth(self.bounds) - 32.0), (CGFloat)340.0);
    CGFloat ph = std::min((CGFloat)(CGRectGetHeight(self.bounds) - 100.0), (CGFloat)420.0);
    _panel = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(self.bounds) - pw)/2, (CGRectGetHeight(self.bounds) - ph)/2, pw, ph)];
    _panel.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:0.95];
    _panel.layer.cornerRadius = 20.0;
    _panel.layer.borderColor = [UIColor colorWithRed:0.4 green:0.6 blue:1.0 alpha:1.0].CGColor;
    _panel.layer.borderWidth = 1.5;
    _panel.layer.shadowColor = [UIColor blackColor].CGColor;
    _panel.layer.shadowRadius = 16.0;
    _panel.layer.shadowOpacity = 0.5;
    // Header Label
    _brandLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 16, pw - 60, 28)];
    _brandLabel.text = @"VideoStar Tool";
    _brandLabel.textColor = [UIColor whiteColor];
    _brandLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [_panel addSubview:_brandLabel];
    _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 44, pw - 60, 18)];
    _subtitleLabel.text = @"Auto Beat AI & Advanced Utilities";
    _subtitleLabel.textColor = [UIColor colorWithRed:0.7 green:0.8 blue:1.0 alpha:1.0];
    _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel addSubview:_subtitleLabel];
    // Close Button
    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.frame = CGRectMake(pw - 40, 16, 28, 28);
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_closeButton addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_closeButton];
    // Feature Switch UI List
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(16, 75, pw - 32, ph - 110)];
    _contentScrollView = scrollView;
    [_panel addSubview:scrollView];
    NSArray *featureNames = @[
    @"Auto nhập ảnh vào các lớp",
    @"Hiển thị code gần nhất từng nhập",
    @"Auto chia beat (Lõi VSBeatCore mới)",
    @"Auto nhập code và ảnh vào phân cảnh"
    ];
    CGFloat y = 10;
    for (NSInteger i = 0; i < featureNames.count; i++) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, y, pw - 90, 30)];
        lbl.text = featureNames[i];
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [scrollView addSubview:lbl];
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 85, y, 50, 30)];
        sw.tag = i;
        sw.on = [_featureStates[i] boolValue];
        sw.onTintColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:1.0];
        [sw addTarget:self action:@selector(featureSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:sw];
        y += 45;
    }
    scrollView.contentSize = CGSizeMake(pw - 32, y);
    _panel.transform = CGAffineTransformMakeScale(0.8, 0.8);
    _panel.alpha = 0.0;
    [self addSubview:_panel];
    [UIView animateWithDuration:0.25 animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
        self->_panel.alpha = 1.0;
    }];
}
- (void)closePanel {
    if (!_panel) return;
    [UIView animateWithDuration:0.2 animations:^{
        self->_panel.transform = CGAffineTransformMakeScale(0.8, 0.8);
        self->_panel.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self->_panel removeFromSuperview];
        self->_panel = nil;
    }];
}
- (void)featureSwitchChanged:(UISwitch *)sender {
    NSInteger idx = sender.tag;
    BOOL isOn = sender.isOn;
    _featureStates[idx] = @(isOn);
    if (isOn) {
        _activeFeature = idx;
        // Turn off other switches
        for (NSInteger i = 0; i < _featureStates.count; i++) {
            if (i != idx) {
                _featureStates[i] = @NO;
            }
        }
        [self closePanel];
        if (idx == 2) {
            [self startFeatureBeatSplit];
        } else {
            [self showSimpleAlert:@"Thông báo" message:[NSString stringWithFormat:@"Chức năng '%@' đã được bật.", (idx >= 0 && idx < 4) ? @[@"Auto nhập ảnh vào các lớp", @"Hiển thị code gần nhất từng nhập", @"Auto chia beat", @"Auto nhập code và ảnh vào phân cảnh"][idx] : @"?"] index:idx];
        }
    } else {
        if (_activeFeature == idx) {
            _activeFeature = -1;
        }
    }
}
- (void)showSimpleAlert:(NSString *)title message:(NSString *)message index:(NSInteger)index {
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self finishFeatureIndex:index];
    }]];
    [topVC presentViewController:alert animated:YES completion:nil];
}
- (void)finishFeatureIndex:(NSInteger)index {
    if (index >= 0 && index < _featureStates.count) {
        _featureStates[index] = @NO;
    }
    _activeFeature = -1;
}
// ─────────────────────────────────────────────────────────────────────────────
// FEATURE 2: AUTO CHIA BEAT (TÍCH HỢP LÕI VSBEATCORE C++)
// ─────────────────────────────────────────────────────────────────────────────
- (void)startFeatureBeatSplit {
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    Class reviewEditClass = NSClassFromString(@"VideoReviewEditVC");
    if (!reviewEditClass || ![topVC isKindOfClass:reviewEditClass]) {
        [self showSimpleAlert:@"Thông báo" message:@"Bạn cần ở màn hình chia phân cảnh (VideoReviewEditVC) để dùng chức năng này." index:2];
        return;
    }
    id project = nil;
    if ([topVC respondsToSelector:@selector(project)]) {
        project = [topVC performSelector:@selector(project)];
    }
    if (!project) {
        [self showSimpleAlert:@"Thông báo" message:@"Không lấy được thông tin Project hiện tại." index:2];
        return;
    }
    // Tìm track audio của phân cảnh
    AVAsset *audioAsset = nil;
    if ([project respondsToSelector:@selector(audioAsset)]) {
        audioAsset = [project performSelector:@selector(audioAsset)];
    } else if ([topVC respondsToSelector:@selector(audioAsset)]) {
        audioAsset = [topVC performSelector:@selector(audioAsset)];
    }
    // Nếu không lấy được trực tiếp audioAsset, trích xuất từ clipURL của Scene
    if (!audioAsset && [project respondsToSelector:@selector(clipURLForSceneIndex:clipIndex:)]) {
        NSURL *clipURL = ((NSURL *(*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(project, @selector(clipURLForSceneIndex:clipIndex:), 0, 0);
        if (clipURL) {
            audioAsset = [AVURLAsset URLAssetWithURL:clipURL options:nil];
        }
    }
    if (!audioAsset) {
        [self showSimpleAlert:@"Thông báo" message:@"Không thể tìm thấy file âm thanh để phân tích nhịp." index:2];
        return;
    }
    _beatSplitRunning = YES;
    _beatSplitView = topVC;
    _beatSplitProject = project;
    _calculatedBeatEvents.clear();
    _currentBeatEventIndex = 0;
    // Phân tích Beat bất đồng bộ ở background thread bằng VSBeatCore
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        double duration = 0;
        vsbeat::Config cfg;
        cfg.sampleRate = 22050.0;
        std::vector<float> pcm = ExtractMonoPCM(audioAsset, cfg.sampleRate, &duration);
        if (pcm.empty()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showSimpleAlert:@"Lỗi phân tích" message:@"Không thể trích xuất dữ liệu âm thanh PCM." index:2];
                self->_beatSplitRunning = NO;
            });
            return;
        }
        // Chạy thuật toán SuperFlux + DP Beat Tracker
        vsbeat::Result res = vsbeat::analyze(pcm, cfg, nullptr);
        vsbeat::SelectOptions opts;
        opts.mode = vsbeat::Mode::Grid;
        opts.minGap = 0.20; // Tối thiểu 200ms giữa các lần chia nhịp
        std::vector<vsbeat::Event> events = vsbeat::selectEvents(res, opts);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (events.empty()) {
                [self showSimpleAlert:@"Thông báo" message:@"Không phát hiện được mốc nhịp phù hợp trong bài nhạc." index:2];
                self->_beatSplitRunning = NO;
                return;
            }
            self->_calculatedBeatEvents = events;
            self->_currentBeatEventIndex = 0;
            // Bắt đầu thực thi chia beat theo mốc nhịp đã tính toán
            [self beatSplitAdvanceStepWithAttempt:0];
        });
    });
}
- (void)beatSplitAdvanceStepWithAttempt:(NSUInteger)attempt {
    if (!_beatSplitRunning || !_beatSplitView || !_beatSplitProject) return;
    if (_currentBeatEventIndex >= _calculatedBeatEvents.size()) {
        [self finishBeatSplitNativeWorkflow];
        return;
    }
    vsbeat::Event ev = _calculatedBeatEvents[_currentBeatEventIndex];
    _currentBeatEventIndex++;
    CMTime targetTime = CMTimeMakeWithSeconds(ev.time, 60000);
    // Đặt mốc thời gian chia (Set Split Point)
    if ([_beatSplitView respondsToSelector:@selector(setSplitPointAtTime:)]) {
        ((void (*)(id, SEL, CMTime))objc_msgSend)(_beatSplitView, @selector(setSplitPointAtTime:), targetTime);
    } else if ([_beatSplitView respondsToSelector:@selector(setCurrentTime:)]) {
        ((void (*)(id, SEL, CMTime))objc_msgSend)(_beatSplitView, @selector(setCurrentTime:), targetTime);
    }
    // Thực hiện lệnh chia (Do Split)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self->_beatSplitView respondsToSelector:@selector(doSplit)]) {
            [self->_beatSplitView performSelector:@selector(doSplit)];
        } else if ([self->_beatSplitView respondsToSelector:@selector(splitCurrentScene)]) {
            [self->_beatSplitView performSelector:@selector(splitCurrentScene)];
        }
        self->_beatSplitQueued++;
        // Chuyển sang mốc beat tiếp theo
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self beatSplitAdvanceStepWithAttempt:0];
        });
    });
}
- (void)finishBeatSplitNativeWorkflow {
    _beatSplitRunning = NO;
    NSUInteger total = _beatSplitQueued;
    _beatSplitQueued = 0;
    _beatSplitView = nil;
    _beatSplitProject = nil;
    [self showSimpleAlert:@"Chia Beat Hoàn Tất" message:[NSString stringWithFormat:@"Đã tự động chia %lu phân cảnh theo nhịp nhạc thành công!", (unsigned long)total] index:2];
}
@end
// ─────────────────────────────────────────────────────────────────────────────
// VSPassthroughWindow & OverlayViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface VSPassthroughWindow : UIWindow
@end

@implementation VSPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // Cho phép tương tác xuyên qua các vùng trống vào Video Star
    }
    return hitView;
}
@end

@interface VSOverlayViewController : UIViewController
@end

@implementation VSOverlayViewController
- (void)loadView {
    CGRect bounds = [UIScreen mainScreen].bounds;
    self.view = [[VSToolOverlay alloc] initWithFrame:bounds];
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end
// ─────────────────────────────────────────────────────────────────────────────
// INITIALIZATION & ENTRY POINT (CONSTRUCTOR)
// ─────────────────────────────────────────────────────────────────────────────
static void InitVideoStarTool() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_overlayWindow) return;
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (activeScene) {
            g_overlayWindow = [[VSPassthroughWindow alloc] initWithWindowScene:activeScene];
        } else {
            g_overlayWindow = [[VSPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        g_overlayWindow.windowLevel = UIWindowLevelStatusBar + 100;
        g_overlayWindow.backgroundColor = [UIColor clearColor];
        g_overlayWindow.rootViewController = [VSOverlayViewController new];
        g_overlayWindow.hidden = NO;
        NSLog(@"[VideoStarTool] Tải thành công Dylib nâng cấp lõi chia Beat AI.");
    });
}
__attribute__((constructor))
static void DylibMain() {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID containsString:@"VideoStar"] || [bundleID containsString:@"videostar"]) {
            InitVideoStarTool();
        }
    }
}