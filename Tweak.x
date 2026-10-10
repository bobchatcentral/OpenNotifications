// OpenNotifications v0.2.0
// Made by Evrik Colozzo 2026
//Last updated October 9, 2026
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AddressBook/AddressBook.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <sys/utsname.h>

#define SETTINGS_DOMAIN CFSTR("com.opennotifications.settings")
#define TRIGGER_PATH @"/var/mobile/on_test_now"
#define CALL_TRIGGER_PATH @"/var/mobile/on_call_now"
#define LOG_PATH "/var/mobile/opennotifications.log"
#define DEFAULT_TONE @"/System/Library/CoreServices/SpringBoard.app/ring.m4r"
#define TUI_PATH "/System/Library/PrivateFrameworks/TelephonyUI.framework/TelephonyUI"

@interface BBBulletinRequest : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *sectionID;
@property(nonatomic, copy) NSString *bulletinID;
@property(nonatomic, copy) NSString *publisherBulletinID;
@property(nonatomic, copy) NSString *recordID;
@property(nonatomic, retain) NSDate *date;
@end

@interface BBServer : NSObject
- (void)publishBulletinRequest:(id)request destinations:(unsigned int)dest;
@end

@interface SBBacklightController : NSObject
+ (id)sharedInstance;
- (void)turnOnScreenFullyWithBacklightSource:(int)source;
- (void)turnOnScreenWithBacklightSource:(int)source;
- (void)resetLockScreenIdleTimer;
- (void)animateBacklightToFactor:(float)f duration:(double)d source:(int)s;
@end

@interface SBAwayController : NSObject
+ (id)sharedAwayController;
- (void)undimScreen;
@end

static BBServer *gServer = nil;

// ---------- logging ----------
static void ONLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    FILE *f = fopen(LOG_PATH, "a");
    if (f) { fprintf(f, "%s\n", [s UTF8String]); fclose(f); }
    [s release];
}

// ---------- settings ----------
static NSString *prefString(CFStringRef key, NSString *def) {
    NSString *out = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, SETTINGS_DOMAIN);
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetLength((CFStringRef)v) > 0)
            out = [NSString stringWithString:(NSString *)v];
        CFRelease(v);
    }
    return out;
}

static int prefInt(CFStringRef key, int def) {
    int out = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, SETTINGS_DOMAIN);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out);
        CFRelease(v);
    }
    return out;
}

static BOOL prefBool(CFStringRef key, BOOL def) {
    BOOL out = def;
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, SETTINGS_DOMAIN);
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID())
            out = CFBooleanGetValue((CFBooleanRef)v) ? YES : NO;
        CFRelease(v);
    }
    return out;
}

static BOOL padMode(void) {
    NSString *m = [prefString(CFSTR("uimode"), @"auto") lowercaseString];
    if ([m isEqualToString:@"ipad"]) return YES;
    if ([m isEqualToString:@"iphone"]) return NO;
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
}

static NSDictionary *currentEvent(void) {
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    return [NSDictionary dictionaryWithObjectsAndKeys:
            prefString(CFSTR("sender"), @"Alex"), @"title",
            prefString(CFSTR("message"), @"hey, are you free later?"), @"message",
            @"com.apple.MobileSMS", @"sectionID", nil];
}

// ---------- contact photo (matches the caller name to a contact) ----------
static UIImage *contactPhoto(NSString *name) {
    UIImage *img = nil;
    ABAddressBookRef ab = ABAddressBookCreate();
    if (!ab) return nil;
    CFArrayRef ppl = ABAddressBookCopyPeopleWithName(ab, (CFStringRef)name);
    if (ppl && CFArrayGetCount(ppl) > 0) {
        ABRecordRef p = CFArrayGetValueAtIndex(ppl, 0);
        if (ABPersonHasImageData(p)) {
            CFDataRef d = ABPersonCopyImageData(p);
            if (d) {
                img = [UIImage imageWithData:(NSData *)d];
                CFRelease(d);
            }
        }
    }
    if (ppl) CFRelease(ppl);
    CFRelease(ab);
    return img;
}

static UIImage *callBackground(NSString *name) {
    UIImage *img = contactPhoto(name);
    if (img) { ONLog(@"[OpenNotifications] background: contact photo"); return img; }
    img = [UIImage imageWithContentsOfFile:@"/var/mobile/on_call_bg.png"];
    if (!img) img = [UIImage imageWithContentsOfFile:@"/var/mobile/on_call_bg.jpg"];
    ONLog(@"[OpenNotifications] background: %s", img ? "custom file" : "default gradient");
    return img;
}

// ---------- capture the BBServer instance ----------
%hook BBServer
- (id)init {
    id r = %orig;
    if (r) {
        gServer = r;
        ONLog(@"[OpenNotifications] captured BBServer via init");
    }
    return r;
}
- (void)publishBulletinRequest:(id)req destinations:(unsigned int)d {
    if (!gServer) {
        gServer = self;
        ONLog(@"[OpenNotifications] captured BBServer via publish");
    }
    %orig;
}
%end

// ---------- posting banners ----------
static void postEvent(NSDictionary *e, unsigned int dest, BOOL tone) {
    if (!gServer) {
        ONLog(@"[OpenNotifications] server not captured yet, cannot post");
        return;
    }
    Class reqClass = objc_getClass("BBBulletinRequest");
    if (!reqClass) {
        ONLog(@"[OpenNotifications] BBBulletinRequest class missing");
        return;
    }

    NSString *uid = [NSString stringWithFormat:@"opennotifications-%@",
                     [[NSProcessInfo processInfo] globallyUniqueString]];
    BBBulletinRequest *r = [[reqClass alloc] init];
    r.title = [e objectForKey:@"title"];
    r.message = [e objectForKey:@"message"];
    NSString *sec = [e objectForKey:@"sectionID"];
    r.sectionID = sec ? sec : @"com.apple.MobileSMS";
    r.bulletinID = uid;
    r.publisherBulletinID = uid;
    r.recordID = uid;
    r.date = [NSDate date];

    if ([r respondsToSelector:@selector(setUnlockActionLabel:)])
        [r performSelector:@selector(setUnlockActionLabel:) withObject:@"view"];
    Class actCls = objc_getClass("BBAction");
    SEL asel = @selector(actionWithLaunchBundleID:callblock:);
    BOOL hasAct = (actCls && [actCls respondsToSelector:asel]);
    BOOL hasSet = [r respondsToSelector:@selector(setDefaultAction:)];
    ONLog(@"[OpenNotifications] action support: BBAction %d, setDefaultAction %d", hasAct, hasSet);
    if (hasAct && hasSet) {
        id act = ((id (*)(id, SEL, id, id))objc_msgSend)(actCls, asel, r.sectionID, nil);
        if (act) [r performSelector:@selector(setDefaultAction:) withObject:act];
    }

    dispatch_queue_t q = NULL;
    Ivar iv = class_getInstanceVariable(object_getClass(gServer), "_queue");
    if (iv) q = (dispatch_queue_t)object_getIvar(gServer, iv);
    if (!q) q = dispatch_get_main_queue();
    ONLog(@"[OpenNotifications] posting \"%@\" in %@ (destinations %u)", r.message, r.sectionID, dest);

    dispatch_async(q, ^{
        [gServer publishBulletinRequest:r destinations:dest];
        [r release];
    });
    if (tone) AudioServicesPlaySystemSound(1007);
}

// ---------- waking / keeping the screen on ----------
static BOOL gKeepAwakeLogged = NO;

static void keepAwake(void) {
    id bl = objc_getClass("SBBacklightController");
    id inst = (bl && [bl respondsToSelector:@selector(sharedInstance)]) ? [bl sharedInstance] : nil;
    if (inst && [inst respondsToSelector:@selector(resetLockScreenIdleTimer)])
        [inst resetLockScreenIdleTimer];

    id aw = objc_getClass("SBAwayController");
    id ai = (aw && [aw respondsToSelector:@selector(sharedAwayController)]) ? [aw sharedAwayController] : nil;
    if (ai && [ai respondsToSelector:@selector(undimScreen)])
        [ai undimScreen];

    if (!gKeepAwakeLogged) {
        gKeepAwakeLogged = YES;
        ONLog(@"[OpenNotifications] keepAwake: backlight %s, away %s",
              inst ? "found" : "MISSING", ai ? "found" : "MISSING");
    }
}

static void wakeScreen(void) {
    id bl = objc_getClass("SBBacklightController");
    id inst = (bl && [bl respondsToSelector:@selector(sharedInstance)]) ? [bl sharedInstance] : nil;
    if (inst) {
        if ([inst respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)])
            [inst turnOnScreenFullyWithBacklightSource:1];
        if ([inst respondsToSelector:@selector(turnOnScreenWithBacklightSource:)])
            [inst turnOnScreenWithBacklightSource:1];
        if ([inst respondsToSelector:@selector(animateBacklightToFactor:duration:source:)])
            [inst animateBacklightToFactor:1.0f duration:0.0 source:1];
    }
    keepAwake();
}

// ---------- drawn icons ----------
@interface ONCamIcon : UIView
@end

@implementation ONCamIcon
- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)r {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, h * 0.15, w * 0.68, h * 0.7)
                                cornerRadius:5] fill];
    UIBezierPath *lens = [UIBezierPath bezierPath];
    [lens moveToPoint:CGPointMake(w * 0.74, h * 0.5)];
    [lens addLineToPoint:CGPointMake(w, h * 0.15)];
    [lens addLineToPoint:CGPointMake(w, h * 0.85)];
    [lens closePath];
    [lens fill];
    UIBezierPath *slash = [UIBezierPath bezierPath];
    slash.lineWidth = 4;
    [slash moveToPoint:CGPointMake(w * 0.05, h * 0.95)];
    [slash addLineToPoint:CGPointMake(w * 0.95, h * 0.05)];
    [slash stroke];
}
@end

@interface ONHandset : UIView
@end

@implementation ONHandset
- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)r {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat rad = w * 0.36;
    CGFloat cy = h * 0.85;
    [[UIColor colorWithWhite:0.95 alpha:1.0] setStroke];
    [[UIColor colorWithWhite:0.95 alpha:1.0] setFill];
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.lineWidth = h * 0.24;
    p.lineCapStyle = kCGLineCapRound;
    [p addArcWithCenter:CGPointMake(w / 2, cy) radius:rad
             startAngle:M_PI * 1.18 endAngle:M_PI * 1.82 clockwise:YES];
    [p stroke];
    CGFloat x1 = w / 2 + cos(M_PI * 1.18) * rad;
    CGFloat y1 = cy + sin(M_PI * 1.18) * rad;
    CGFloat x2 = w / 2 + cos(M_PI * 1.82) * rad;
    CGFloat y2 = cy + sin(M_PI * 1.82) * rad;
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x1 - w * 0.11, y1 - h * 0.08, w * 0.22, h * 0.36)
                                cornerRadius:3] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x2 - w * 0.11, y2 - h * 0.08, w * 0.22, h * 0.36)
                                cornerRadius:3] fill];
}
@end

// one cell of the in-call button grid
@interface ONCell : UIView {
    int kind;
    BOOL on;
    NSString *title;
}
- (id)initWithKind:(int)k title:(NSString *)t;
@end

@implementation ONCell
- (id)initWithKind:(int)k title:(NSString *)t {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        kind = k;
        title = [t copy];
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}
- (void)dealloc {
    [title release];
    [super dealloc];
}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (kind == 0 || kind == 2) {
        on = !on;
        [self setNeedsDisplay];
    }
    ONLog(@"[OpenNotifications] grid button: %@", title);
}
- (void)drawRect:(CGRect)r {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (on) {
        [[UIColor colorWithWhite:1.0 alpha:0.28] setFill];
        UIRectFill(self.bounds);
    }
    [[UIColor colorWithWhite:1.0 alpha:0.12] setFill];
    UIRectFill(CGRectMake(w - 1, 0, 1, h));
    UIRectFill(CGRectMake(0, h - 1, w, 1));

    UIColor *col = on ? [UIColor whiteColor] : [UIColor colorWithWhite:0.82 alpha:1.0];
    [col setFill];
    [col setStroke];
    CGFloat gx = w / 2 - 15;
    CGFloat gy = (h - 24 - 30) / 2 + 2;
    UIBezierPath *p;
    int i, j;

    if (kind == 0) {            // mute: microphone with slash
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gx + 10, gy, 10, 18) cornerRadius:5] fill];
        p = [UIBezierPath bezierPath];
        p.lineWidth = 2;
        [p addArcWithCenter:CGPointMake(gx + 15, gy + 12) radius:9 startAngle:0 endAngle:M_PI clockwise:YES];
        [p moveToPoint:CGPointMake(gx + 15, gy + 21)];
        [p addLineToPoint:CGPointMake(gx + 15, gy + 28)];
        [p stroke];
        p = [UIBezierPath bezierPath];
        p.lineWidth = 3;
        [p moveToPoint:CGPointMake(gx + 3, gy + 28)];
        [p addLineToPoint:CGPointMake(gx + 27, gy + 2)];
        [p stroke];
    } else if (kind == 1) {     // keypad: 3x3 dots
        for (i = 0; i < 3; i++)
            for (j = 0; j < 3; j++)
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gx + 3 + j * 9, gy + 3 + i * 9, 6, 6)
                                            cornerRadius:1] fill];
    } else if (kind == 2) {     // speaker
        p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(gx + 2, gy + 11)];
        [p addLineToPoint:CGPointMake(gx + 8, gy + 11)];
        [p addLineToPoint:CGPointMake(gx + 16, gy + 4)];
        [p addLineToPoint:CGPointMake(gx + 16, gy + 26)];
        [p addLineToPoint:CGPointMake(gx + 8, gy + 19)];
        [p addLineToPoint:CGPointMake(gx + 2, gy + 19)];
        [p closePath];
        [p fill];
        p = [UIBezierPath bezierPath];
        p.lineWidth = 2;
        [p addArcWithCenter:CGPointMake(gx + 16, gy + 15) radius:7 startAngle:-0.9 endAngle:0.9 clockwise:YES];
        [p stroke];
        p = [UIBezierPath bezierPath];
        p.lineWidth = 2;
        [p addArcWithCenter:CGPointMake(gx + 16, gy + 15) radius:12 startAngle:-0.9 endAngle:0.9 clockwise:YES];
        [p stroke];
    } else if (kind == 3) {     // add call: plus
        UIRectFill(CGRectMake(gx + 12, gy + 3, 6, 24));
        UIRectFill(CGRectMake(gx + 3, gy + 12, 24, 6));
    } else if (kind == 4) {     // FaceTime: camera
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gx + 1, gy + 7, 18, 16) cornerRadius:3] fill];
        p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(gx + 21, gy + 15)];
        [p addLineToPoint:CGPointMake(gx + 30, gy + 8)];
        [p addLineToPoint:CGPointMake(gx + 30, gy + 22)];
        [p closePath];
        [p fill];
    } else {                    // contacts: person
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(gx + 9, gy + 1, 12, 12)] fill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(gx + 3, gy + 15, 24, 14) cornerRadius:7] fill];
    }

    [title drawInRect:CGRectMake(0, h - 22, w, 16)
             withFont:[UIFont boldSystemFontOfSize:12]
        lineBreakMode:UILineBreakModeClip
            alignment:UITextAlignmentCenter];
}
@end

// ---------- fake call screen ----------
@interface ONCallHandler : NSObject
- (void)accept;
- (void)decline;
- (void)remind;
- (void)messageTap;
- (void)handsetTap;
- (void)replyTap:(UIButton *)b;
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)tick:(NSTimer *)t;
- (void)ring:(NSTimer *)t;
- (void)timeout:(NSTimer *)t;
- (void)awake:(NSTimer *)t;
- (void)orient:(NSNotification *)n;
- (void)lockBarUnlocked:(id)bar;
@end

static UIWindow *gCallWindow = nil;
static ONCallHandler *gCallHandler = nil;
static AVAudioPlayer *gRing = nil;
static SystemSoundID gRingSID = 0;
static BOOL gRingSIDActive = NO;
static NSTimer *gRingTimer = nil;
static NSTimer *gTickTimer = nil;
static NSTimer *gTimeoutTimer = nil;
static NSTimer *gAwakeTimer = nil;

static UIView *gCallView = nil;
static CAGradientLayer *gBg = nil;
static UIImageView *gPhoto = nil;
static UIView *gShade = nil;
static UIView *gTopV = nil;
static UIView *gBotV = nil;
static CAGradientLayer *gTopG = nil;
static CAGradientLayer *gBotG = nil;
static UILabel *gNameLabel = nil;
static UILabel *gSubLabel = nil;
static UILabel *gStatus = nil;

static UIView *gVIncoming = nil;
static UIView *gVOptions = nil;
static UIView *gVCall = nil;
static UIView *gVReply = nil;
static UIButton *gHandset = nil;

static UIView *gRealBar = nil;
static UIView *gTrack = nil;
static UIView *gKnob = nil;
static UILabel *gSlideLabel = nil;
static BOOL gDragging = NO;

static UIButton *gDeclineBtn = nil;
static UIButton *gAcceptBtn = nil;
static UIButton *gReplyMsgBtn = nil;
static UIButton *gRemindBtn = nil;

static UIView *gGridBg = nil;
static UIView *gCell[6];
static UIButton *gEndBtn = nil;
static UIView *gEndIcon = nil;

static UILabel *gReplyTitle = nil;
static UIButton *gReplyBtn[5];

static NSDate *gCallStart = nil;
static NSString *gCallerName = nil;
static BOOL gFT = NO;
static int gMode = 0;   // 0 slide to answer, 1 options, 2 in call, 3 reply list
static BOOL gOrientOn = NO;
static UIDeviceOrientation gLastOrient = UIDeviceOrientationPortrait;

static void stopRinging(void) {
    if (gRingSID) {
        gRingSIDActive = NO;
        AudioServicesRemoveSystemSoundCompletion(gRingSID);
        AudioServicesDisposeSystemSoundID(gRingSID);
        gRingSID = 0;
    }
    if (gRing) { [gRing stop]; [gRing release]; gRing = nil; }
    if (gRingTimer) { [gRingTimer invalidate]; [gRingTimer release]; gRingTimer = nil; }
    if (gTimeoutTimer) { [gTimeoutTimer invalidate]; [gTimeoutTimer release]; gTimeoutTimer = nil; }
}

static void dismissCall(void) {
    stopRinging();
    if (gOrientOn) {
        gOrientOn = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:gCallHandler];
        [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    }
    if (gCallHandler)
        [NSObject cancelPreviousPerformRequestsWithTarget:gCallHandler];
    if (gTickTimer) { [gTickTimer invalidate]; [gTickTimer release]; gTickTimer = nil; }
    if (gAwakeTimer) { [gAwakeTimer invalidate]; [gAwakeTimer release]; gAwakeTimer = nil; }
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    if (gCallWindow) { [gCallWindow setHidden:YES]; [gCallWindow release]; gCallWindow = nil; }
    [gCallStart release]; gCallStart = nil;
    int i;
    for (i = 0; i < 6; i++) gCell[i] = nil;
    for (i = 0; i < 5; i++) gReplyBtn[i] = nil;
    gCallView = nil; gBg = nil; gPhoto = nil; gShade = nil;
    gTopV = nil; gBotV = nil; gTopG = nil; gBotG = nil;
    gNameLabel = nil; gSubLabel = nil; gStatus = nil;
    gVIncoming = nil; gVOptions = nil; gVCall = nil; gVReply = nil; gHandset = nil;
    gRealBar = nil; gTrack = nil; gKnob = nil; gSlideLabel = nil; gDragging = NO;
    gDeclineBtn = nil; gAcceptBtn = nil; gReplyMsgBtn = nil; gRemindBtn = nil;
    gGridBg = nil; gEndBtn = nil; gEndIcon = nil; gReplyTitle = nil;
    gMode = 0;
    ONLog(@"[OpenNotifications] call dismissed");
}

// kind 0 red, 1 green, 2 dark gray, 3 white, 4 black
static UIButton *makeButton(NSString *title, int kind, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.layer.cornerRadius = gFT ? 12 : 8;
    b.layer.masksToBounds = YES;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:(gFT ? 28 : 18)];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:(kind == 3 ? [UIColor blackColor] : [UIColor whiteColor])
            forState:UIControlStateNormal];

    CAGradientLayer *g = [CAGradientLayer layer];
    UIColor *top, *bot;
    if (kind == 0) {
        top = [UIColor colorWithRed:0.93 green:0.35 blue:0.35 alpha:1.0];
        bot = [UIColor colorWithRed:0.65 green:0.0 blue:0.0 alpha:1.0];
    } else if (kind == 1) {
        top = [UIColor colorWithRed:0.45 green:0.85 blue:0.45 alpha:1.0];
        bot = [UIColor colorWithRed:0.10 green:0.55 blue:0.15 alpha:1.0];
    } else if (kind == 3) {
        top = [UIColor colorWithWhite:0.98 alpha:1.0];
        bot = [UIColor colorWithWhite:0.78 alpha:1.0];
    } else if (kind == 4) {
        top = [UIColor colorWithWhite:0.30 alpha:1.0];
        bot = [UIColor colorWithWhite:0.02 alpha:1.0];
    } else {
        top = [UIColor colorWithWhite:0.45 alpha:1.0];
        bot = [UIColor colorWithWhite:0.14 alpha:1.0];
    }
    g.colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bot.CGColor, nil];
    [b.layer insertSublayer:g atIndex:0];

    [b addTarget:gCallHandler action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void setBtnFrame(UIButton *b, CGRect f) {
    if (!b) return;
    b.frame = f;
    NSArray *subs = b.layer.sublayers;
    if ([subs count] && [[subs objectAtIndex:0] isKindOfClass:[CAGradientLayer class]])
        [(CALayer *)[subs objectAtIndex:0] setFrame:b.bounds];
}

static void layoutCall(void) {
    if (!gCallView) return;
    CGRect b = gCallView.bounds;
    CGFloat W = b.size.width, H = b.size.height;
    int i;

    if (gBg) gBg.frame = b;
    gPhoto.frame = b;
    gShade.frame = b;
    gTopV.frame = CGRectMake(0, 0, W, 130);
    gTopG.frame = gTopV.bounds;
    gBotV.frame = CGRectMake(0, H - 220, W, 220);
    gBotG.frame = gBotV.bounds;
    gVIncoming.frame = b;
    gVOptions.frame = b;
    gVCall.frame = b;
    gVReply.frame = b;

    if (gFT) {
        gNameLabel.frame = CGRectMake(20, 34, W - 40, 56);
        gStatus.frame = CGRectMake(0, 92, W, 36);
        CGFloat bh = 64, y = H - 110;
        CGFloat bw = (W - 90) / 2;
        setBtnFrame(gDeclineBtn, CGRectMake(30, y, bw, bh));
        setBtnFrame(gAcceptBtn, CGRectMake(60 + bw, y, bw, bh));
        setBtnFrame(gEndBtn, CGRectMake(30, y, W - 60, bh));
    } else {
        BOOL shortScreen = (H < 400);
        CGFloat ty = shortScreen ? 8 : 22;
        gNameLabel.frame = CGRectMake(10, ty, W - 20, 40);
        gSubLabel.frame = CGRectMake(0, ty + 40, W, 22);
        gStatus.frame = CGRectMake(0, ty + 40, W, 22);

        if (gRealBar) gRealBar.frame = CGRectMake(0, H - 96, W, 96);
        if (gTrack) {
            gTrack.frame = CGRectMake(20, H - 90, W - 40, 64);
            gSlideLabel.frame = CGRectMake(70, 0, W - 40 - 70, 64);
            if (!gDragging) gKnob.frame = CGRectMake(4, 4, 76, 56);
        }
        gHandset.frame = CGRectMake(W - 54, H - 70, 44, 44);

        CGFloat bw = (W - 60) / 2;
        setBtnFrame(gDeclineBtn, CGRectMake(20, H - 230, bw, 46));
        setBtnFrame(gAcceptBtn, CGRectMake(40 + bw, H - 230, bw, 46));
        setBtnFrame(gReplyMsgBtn, CGRectMake(20, H - 176, W - 40, 44));
        setBtnFrame(gRemindBtn, CGRectMake(20, H - 124, W - 40, 44));

        if (gGridBg) {
            CGFloat cw = (W - 40) / 3.0f;
            CGFloat ch = shortScreen ? 62 : 88;
            CGFloat py = shortScreen ? 86 : 110;
            gGridBg.frame = CGRectMake(20, py, W - 40, ch * 2);
            for (i = 0; i < 6; i++)
                gCell[i].frame = CGRectMake(20 + (i % 3) * cw, py + (i / 3) * ch, cw, ch);
        }
        setBtnFrame(gEndBtn, CGRectMake(14, H - 74, W - 28, 58));
    }

    if (gEndBtn && gEndIcon) {
        CGFloat bw = gEndBtn.bounds.size.width, bh = gEndBtn.bounds.size.height;
        CGFloat iw = gFT ? 46 : 28, ih = gFT ? 30 : 16;
        gEndIcon.frame = CGRectMake(bw / 2 - iw - 30, (bh - ih) / 2, iw, ih);
    }

    if (gVReply) {
        CGFloat bh = (H < 400) ? 30 : 40;
        CGFloat sp = bh + 6;
        for (i = 0; i < 5; i++) {
            CGFloat y = H - 10 - bh - (4 - i) * sp;
            setBtnFrame(gReplyBtn[i], CGRectMake(20, y, W - 40, bh));
        }
        gReplyTitle.frame = CGRectMake(0, H - 10 - bh - 4 * sp - 28, W, 22);
    }
}

static void setMode(int m) {
    gMode = m;
    gVIncoming.hidden = (m != 0);
    gVOptions.hidden = !(m == 1 || m == 3);
    gVCall.hidden = (m != 2);
    gVReply.hidden = (m != 3);
    gHandset.hidden = gFT || !(m == 0 || m == 1);
    gSubLabel.hidden = gFT || m == 2;
    gStatus.hidden = !(gFT || m == 2);
    gShade.alpha = (m == 2) ? 0.6f : (gFT ? 0.25f : 0.0f);
    layoutCall();
}

static void applyOrientation(BOOL animated) {
    if (!gCallView) return;
    CGRect sb = [[UIScreen mainScreen] bounds];
    UIDeviceOrientation o = [[UIDevice currentDevice] orientation];
    if (!prefBool(CFSTR("rotate"), YES)) o = UIDeviceOrientationPortrait;
    if (!(o == UIDeviceOrientationPortrait || o == UIDeviceOrientationPortraitUpsideDown ||
          o == UIDeviceOrientationLandscapeLeft || o == UIDeviceOrientationLandscapeRight))
        o = gLastOrient;
    gLastOrient = o;

    CGFloat ang = 0;
    BOOL land = NO;
    if (o == UIDeviceOrientationLandscapeLeft) { ang = M_PI_2; land = YES; }
    else if (o == UIDeviceOrientationLandscapeRight) { ang = -M_PI_2; land = YES; }
    else if (o == UIDeviceOrientationPortraitUpsideDown) { ang = M_PI; }

    CGFloat W = land ? sb.size.height : sb.size.width;
    CGFloat H = land ? sb.size.width : sb.size.height;
    void (^apply)(void) = ^{
        gCallView.transform = CGAffineTransformIdentity;
        gCallView.bounds = CGRectMake(0, 0, W, H);
        gCallView.center = CGPointMake(sb.size.width / 2, sb.size.height / 2);
        gCallView.transform = CGAffineTransformMakeRotation(ang);
        layoutCall();
    };
    if (animated) [UIView animateWithDuration:0.25 animations:apply];
    else apply();
}

// loops the system sound until the call ends
static void ringDone(SystemSoundID sid, void *ctx) {
    if (gRingSIDActive) AudioServicesPlaySystemSound(sid);
}

// looks for a FaceTime ringtone file anywhere in the usual sound folders
static NSString *findFaceTimeTone(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *roots[] = { "/System/Library/Audio/UISounds", "/Library/Ringtones",
                            "/System/Library/CoreServices/SpringBoard.app",
                            "/Applications/FaceTime.app",
                            "/System/Library/PrivateFrameworks/FaceTimeUI.framework" };
    NSString *fallback = nil;
    int i;
    for (i = 0; i < 5; i++) {
        NSString *root = [NSString stringWithUTF8String:roots[i]];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        NSString *f;
        while ((f = [en nextObject])) {
            NSString *l = [f lowercaseString];
            if ([l rangeOfString:@"facetime"].location == NSNotFound) continue;
            NSString *ext = [l pathExtension];
            if (!([ext isEqualToString:@"caf"] || [ext isEqualToString:@"m4r"] ||
                  [ext isEqualToString:@"aif"] || [ext isEqualToString:@"aiff"] ||
                  [ext isEqualToString:@"m4a"] || [ext isEqualToString:@"mp3"] ||
                  [ext isEqualToString:@"wav"])) continue;
            NSString *full = [root stringByAppendingPathComponent:f];
            if ([l rangeOfString:@"ring"].location != NSNotFound) return full;
            if (!fallback) fallback = full;
        }
    }
    return fallback;
}

static void startRinging(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@"/Library/Ringtones" error:NULL];

    NSString *name = prefString(CFSTR("ringtone"), @"Marimba");
    NSString *lname = [name lowercaseString];
    NSString *src = nil;

    if ([lname isEqualToString:@"facetime"]) {
        src = findFaceTimeTone();
        if (!src) {
            ONLog(@"[OpenNotifications] facetime tone not found, using default tone");
            src = DEFAULT_TONE;
        }
    } else if (([lname isEqualToString:@"marimba"] || [lname isEqualToString:@"default"])
        && [fm fileExistsAtPath:DEFAULT_TONE]) {
        src = DEFAULT_TONE;
    } else if ([name hasPrefix:@"/"] && [fm fileExistsAtPath:name]) {
        src = name;
    } else {
        for (NSString *f in files) {
            NSString *base = [[f stringByDeletingPathExtension] lowercaseString];
            if ([base isEqualToString:lname]) {
                src = [@"/Library/Ringtones" stringByAppendingPathComponent:f];
                break;
            }
        }
    }
    if (!src) {
        ONLog(@"[OpenNotifications] ringtone '%@' not found anywhere", name);
        src = @"/Library/Ringtones/none.m4r";
    }
    ONLog(@"[OpenNotifications] ringtone source: %@ (exists %d)", src, [fm fileExistsAtPath:src]);

    NSString *ext = [[src pathExtension] lowercaseString];
    if ([ext length] == 0 || [ext isEqualToString:@"m4r"]) ext = @"m4a";
    NSString *tmp = [NSString stringWithFormat:@"/tmp/on_ring.%@", ext];
    [fm removeItemAtPath:tmp error:NULL];
    NSError *cerr = nil;
    BOOL copied = [fm copyItemAtPath:src toPath:tmp error:&cerr];
    NSString *playPath = copied ? tmp : src;

    SystemSoundID sid = 0;
    OSStatus st = AudioServicesCreateSystemSoundID((CFURLRef)[NSURL fileURLWithPath:playPath], &sid);
    ONLog(@"[OpenNotifications] system sound create status %d", (int)st);
    if (st == 0 && sid) {
        gRingSID = sid;
        gRingSIDActive = YES;
        AudioServicesAddSystemSoundCompletion(sid, NULL, NULL, ringDone, NULL);
        AudioServicesPlaySystemSound(sid);
    } else {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        gRing = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:playPath] error:&err];
        if (gRing) {
            gRing.numberOfLoops = -1;
            [gRing play];
        } else {
            ONLog(@"[OpenNotifications] AVAudioPlayer load failed: %@", [err localizedDescription]);
        }
    }

    gRingTimer = [[NSTimer scheduledTimerWithTimeInterval:2.0 target:gCallHandler
                    selector:@selector(ring:) userInfo:nil repeats:YES] retain];
    gTimeoutTimer = [[NSTimer scheduledTimerWithTimeInterval:30.0 target:gCallHandler
                    selector:@selector(timeout:) userInfo:nil repeats:NO] retain];
}

static UILabel *makeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *l = [[[UILabel alloc] init] autorelease];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.textAlignment = UITextAlignmentCenter;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

static UIView *makeFade(BOOL fromTop, CAGradientLayer **outLayer) {
    UIView *v = [[[UIView alloc] init] autorelease];
    v.userInteractionEnabled = NO;
    CAGradientLayer *g = [CAGradientLayer layer];
    UIColor *dark = [UIColor colorWithWhite:0.0 alpha:0.55];
    UIColor *clear = [UIColor colorWithWhite:0.0 alpha:0.0];
    if (fromTop)
        g.colors = [NSArray arrayWithObjects:(id)dark.CGColor, (id)clear.CGColor, nil];
    else
        g.colors = [NSArray arrayWithObjects:(id)clear.CGColor, (id)dark.CGColor, nil];
    [v.layer addSublayer:g];
    *outLayer = g;
    return v;
}

// Apple's own slide-to-answer bar from TelephonyUI; NO means "use the fallback slider"
static BOOL tryRealSlider(CGFloat W, CGFloat H) {
    @try {
        dlopen(TUI_PATH, RTLD_LAZY);
        Class c = objc_getClass("TPBottomLockBar");
        SEL isel = @selector(initForIncomingCallWithFrame:);
        if (!c || ![c instancesRespondToSelector:isel]) {
            ONLog(@"[OpenNotifications] real slider: class or init missing, using fallback");
            return NO;
        }
        id bar = [c alloc];
        bar = ((id (*)(id, SEL, CGRect))objc_msgSend)(bar, isel, CGRectMake(0, H - 96, W, 40));
        if (!bar || ![bar isKindOfClass:[UIView class]]) {
            ONLog(@"[OpenNotifications] real slider: init failed, using fallback");
            return NO;
        }
        if ([bar respondsToSelector:@selector(setDelegate:)])
            [bar performSelector:@selector(setDelegate:) withObject:gCallHandler];

        NSString *lbl = @"slide to answer";
        if ([bar respondsToSelector:@selector(setLabel:)])
            [bar performSelector:@selector(setLabel:) withObject:lbl];
        else if ([bar respondsToSelector:@selector(setLabels:)])
            [bar performSelector:@selector(setLabels:) withObject:[NSArray arrayWithObject:lbl]];
        if ([bar respondsToSelector:@selector(setTextAlpha:)])
            ((void (*)(id, SEL, float))objc_msgSend)(bar, @selector(setTextAlpha:), 1.0f);

        if ([bar respondsToSelector:@selector(startAnimating)])
            [bar performSelector:@selector(startAnimating)];
        gRealBar = (UIView *)bar;
        [gVIncoming addSubview:gRealBar];
        [bar release];
        ONLog(@"[OpenNotifications] real slider: created TPBottomLockBar");
        return YES;
    } @catch (NSException *ex) {
        ONLog(@"[OpenNotifications] real slider exception: %@", ex);
        gRealBar = nil;
        return NO;
    }
}

static void buildDragSlider(void) {
    gTrack = [[[UIView alloc] init] autorelease];
    gTrack.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    gTrack.layer.cornerRadius = 10;
    gTrack.layer.borderWidth = 1;
    gTrack.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    [gVIncoming addSubview:gTrack];

    gSlideLabel = makeLabel(@"slide to answer", [UIFont systemFontOfSize:24],
                            [UIColor colorWithWhite:0.85 alpha:1.0]);
    [gTrack addSubview:gSlideLabel];

    gKnob = [[[UIView alloc] init] autorelease];
    gKnob.backgroundColor = [UIColor colorWithRed:0.1 green:0.7 blue:0.25 alpha:1.0];
    gKnob.layer.cornerRadius = 8;
    gKnob.userInteractionEnabled = YES;
    UILabel *arrow = makeLabel(@">", [UIFont boldSystemFontOfSize:32], [UIColor whiteColor]);
    arrow.frame = CGRectMake(0, 0, 76, 56);
    [gKnob addSubview:arrow];
    UIPanGestureRecognizer *pg = [[[UIPanGestureRecognizer alloc] initWithTarget:gCallHandler
                                                                          action:@selector(pan:)] autorelease];
    [gKnob addGestureRecognizer:pg];
    [gTrack addSubview:gKnob];
}

static void addHandsetIcon(UIButton *b, BOOL flip) {
    ONHandset *h = [[[ONHandset alloc] initWithFrame:CGRectMake(12, 15, 26, 16)] autorelease];
    if (flip) h.transform = CGAffineTransformMakeRotation(M_PI);
    [b addSubview:h];
    b.titleEdgeInsets = UIEdgeInsetsMake(0, 22, 0, 0);
}

static void buildReplyView(void) {
    gVReply = [[[UIView alloc] init] autorelease];
    gVReply.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    [gCallView addSubview:gVReply];
    gReplyTitle = makeLabel(@"Can't talk right now...", [UIFont systemFontOfSize:14],
                            [UIColor colorWithWhite:0.75 alpha:1.0]);
    [gVReply addSubview:gReplyTitle];
    const char *t[] = { "I'll call you later.", "I'm on my way.", "What's up?", "Custom...", "Cancel" };
    int i;
    for (i = 0; i < 5; i++) {
        gReplyBtn[i] = makeButton([NSString stringWithUTF8String:t[i]], (i == 4 ? 4 : 3),
                                  @selector(replyTap:));
        gReplyBtn[i].tag = i;
        gReplyBtn[i].titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [gVReply addSubview:gReplyBtn[i]];
    }
}

static void showCall(NSString *name) {
    if (gCallWindow) return;
    if (!gCallHandler) gCallHandler = [[ONCallHandler alloc] init];
    [gCallerName release];
    gCallerName = [name copy];
    gFT = padMode();
    ONLog(@"[OpenNotifications] call style: %s", gFT ? "FaceTime/iPad" : "iPhone");

    wakeScreen();
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    gKeepAwakeLogged = NO;
    gAwakeTimer = [[NSTimer scheduledTimerWithTimeInterval:3.0 target:gCallHandler
                    selector:@selector(awake:) userInfo:nil repeats:YES] retain];

    CGRect b = [[UIScreen mainScreen] bounds];
    gCallWindow = [[UIWindow alloc] initWithFrame:b];
    gCallWindow.windowLevel = 10000;
    gCallWindow.backgroundColor = [UIColor blackColor];

    gCallView = [[[UIView alloc] initWithFrame:b] autorelease];
    gCallView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    [gCallWindow addSubview:gCallView];

    // background: gradient, then the contact photo or custom picture on top
    gBg = [CAGradientLayer layer];
    if (gFT) {
        gBg.colors = [NSArray arrayWithObjects:
                      (id)[UIColor colorWithWhite:0.32 alpha:1.0].CGColor,
                      (id)[UIColor colorWithWhite:0.14 alpha:1.0].CGColor,
                      (id)[UIColor colorWithWhite:0.04 alpha:1.0].CGColor, nil];
    } else {
        gBg.colors = [NSArray arrayWithObjects:
                      (id)[UIColor colorWithRed:0.34 green:0.36 blue:0.42 alpha:1.0].CGColor,
                      (id)[UIColor colorWithRed:0.10 green:0.11 blue:0.14 alpha:1.0].CGColor, nil];
    }
    [gCallView.layer insertSublayer:gBg atIndex:0];

    UIImage *bg = callBackground(name);
    gPhoto = [[[UIImageView alloc] init] autorelease];
    gPhoto.contentMode = UIViewContentModeScaleAspectFill;
    gPhoto.clipsToBounds = YES;
    gPhoto.image = bg;
    [gCallView addSubview:gPhoto];

    gShade = [[[UIView alloc] init] autorelease];
    gShade.backgroundColor = [UIColor blackColor];
    gShade.userInteractionEnabled = NO;
    gShade.alpha = 0.0f;
    [gCallView addSubview:gShade];

    gTopV = makeFade(YES, &gTopG);
    gBotV = makeFade(NO, &gBotG);
    [gCallView addSubview:gTopV];
    [gCallView addSubview:gBotV];

    // header labels
    if (gFT) {
        gNameLabel = makeLabel(name, [UIFont systemFontOfSize:46], [UIColor whiteColor]);
        gStatus = makeLabel(@"FaceTime...", [UIFont systemFontOfSize:30], [UIColor whiteColor]);
    } else {
        gNameLabel = makeLabel(name, [UIFont systemFontOfSize:34], [UIColor whiteColor]);
        gSubLabel = makeLabel(@"mobile", [UIFont systemFontOfSize:18], [UIColor colorWithWhite:0.85 alpha:1.0]);
        gStatus = makeLabel(@"0:00", [UIFont systemFontOfSize:18], [UIColor colorWithWhite:0.85 alpha:1.0]);
    }
    gNameLabel.adjustsFontSizeToFitWidth = YES;
    gNameLabel.shadowColor = [UIColor blackColor];
    gNameLabel.shadowOffset = CGSizeMake(0, 1);
    [gCallView addSubview:gNameLabel];
    if (gSubLabel) [gCallView addSubview:gSubLabel];
    [gCallView addSubview:gStatus];

    // containers for each screen state
    gVIncoming = [[[UIView alloc] init] autorelease];
    gVOptions = [[[UIView alloc] init] autorelease];
    gVCall = [[[UIView alloc] init] autorelease];
    [gCallView addSubview:gVIncoming];
    [gCallView addSubview:gVOptions];
    [gCallView addSubview:gVCall];

    // options: Decline / Answer (+ Reply with Message / Remind Me Later on iPhone)
    gDeclineBtn = makeButton(@"Decline", 0, @selector(decline));
    gAcceptBtn = makeButton(gFT ? @"Accept" : @"Answer", 1, @selector(accept));
    [gVOptions addSubview:gDeclineBtn];
    [gVOptions addSubview:gAcceptBtn];
    if (!gFT) {
        addHandsetIcon(gDeclineBtn, NO);
        addHandsetIcon(gAcceptBtn, YES);
        gReplyMsgBtn = makeButton(@"Reply with Message", 2, @selector(messageTap));
        gRemindBtn = makeButton(@"Remind Me Later", 2, @selector(remind));
        gReplyMsgBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        gRemindBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        addHandsetIcon(gReplyMsgBtn, NO);
        addHandsetIcon(gRemindBtn, NO);
        [gVOptions addSubview:gReplyMsgBtn];
        [gVOptions addSubview:gRemindBtn];
    }

    // in-call screen: button grid (iPhone) and End bar
    if (!gFT) {
        gGridBg = [[[UIView alloc] init] autorelease];
        gGridBg.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        gGridBg.layer.cornerRadius = 10;
        gGridBg.layer.borderWidth = 1;
        gGridBg.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        gGridBg.userInteractionEnabled = NO;
        [gVCall addSubview:gGridBg];
        const char *gt[] = { "mute", "keypad", "speaker", "add call", "FaceTime", "contacts" };
        int i;
        for (i = 0; i < 6; i++) {
            gCell[i] = [[[ONCell alloc] initWithKind:i title:[NSString stringWithUTF8String:gt[i]]] autorelease];
            [gVCall addSubview:gCell[i]];
        }
    }
    gEndBtn = makeButton(@"End", 0, @selector(decline));
    if (gFT) {
        gEndBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 70, 0, 0);
        gEndIcon = [[[ONCamIcon alloc] initWithFrame:CGRectMake(0, 0, 46, 30)] autorelease];
    } else {
        gEndBtn.titleEdgeInsets = UIEdgeInsetsMake(0, 44, 0, 0);
        gEndIcon = [[[ONHandset alloc] initWithFrame:CGRectMake(0, 0, 28, 16)] autorelease];
    }
    [gEndBtn addSubview:gEndIcon];
    [gVCall addSubview:gEndBtn];

    buildReplyView();

    // slide to answer (iPhone) and the handset button that opens the options
    if (!gFT) {
        if (!tryRealSlider(b.size.width, b.size.height))
            buildDragSlider();
        gHandset = [UIButton buttonWithType:UIButtonTypeCustom];
        ONHandset *hi = [[[ONHandset alloc] initWithFrame:CGRectMake(8, 14, 28, 16)] autorelease];
        [gHandset addSubview:hi];
        [gHandset addTarget:gCallHandler action:@selector(handsetTap)
           forControlEvents:UIControlEventTouchUpInside];
        [gCallView addSubview:gHandset];
    }

    [gCallWindow setHidden:NO];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    gOrientOn = YES;
    [[NSNotificationCenter defaultCenter] addObserver:gCallHandler selector:@selector(orient:)
        name:UIDeviceOrientationDidChangeNotification object:nil];
    applyOrientation(NO);
    setMode(gFT ? 1 : 0);

    startRinging();
    ONLog(@"[OpenNotifications] call shown for %@", name);
}

@implementation ONCallHandler
- (void)awake:(NSTimer *)t { keepAwake(); }
- (void)orient:(NSNotification *)n { applyOrientation(YES); }
- (void)ring:(NSTimer *)t {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    if (!gRing && !gRingSID) AudioServicesPlaySystemSound(1007);
}
- (void)timeout:(NSTimer *)t {
    ONLog(@"[OpenNotifications] call timed out (missed)");
    NSString *who = [[gCallerName copy] autorelease];
    dismissCall();
    if (who && prefBool(CFSTR("missed"), YES)) {
        NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:
                           who, @"title",
                           @"Missed call", @"message",
                           @"com.apple.mobilephone", @"sectionID", nil];
        postEvent(e, 15, NO);
    }
}
- (void)decline { dismissCall(); }
- (void)remind {
    ONLog(@"[OpenNotifications] remind me later tapped");
    dismissCall();
}
- (void)messageTap {
    if (gMode == 2) return;
    setMode(3);
}
- (void)handsetTap {
    if (gMode == 0) setMode(1);
    else if (gMode == 1) setMode(0);
}
- (void)replyTap:(UIButton *)b {
    if (b.tag == 4) {
        setMode(1);
        return;
    }
    ONLog(@"[OpenNotifications] replied with message option %d", (int)b.tag);
    dismissCall();
}

// callback from Apple's TPBottomLockBar when the knob reaches the end
- (void)lockBarUnlocked:(id)bar {
    ONLog(@"[OpenNotifications] real slider unlocked");
    [self performSelector:@selector(accept) withObject:nil afterDelay:0.1];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (!gKnob || !gTrack) return;
    CGFloat maxX = gTrack.bounds.size.width - gKnob.bounds.size.width - 4;
    CGFloat x = [g locationInView:gTrack].x - gKnob.bounds.size.width / 2;
    if (x < 4) x = 4;
    if (x > maxX) x = maxX;

    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged) {
        gDragging = YES;
        CGRect f = gKnob.frame;
        f.origin.x = x;
        gKnob.frame = f;
        CGFloat a = 1.0f - 1.5f * ((x - 4) / (maxX - 4));
        if (a < 0) a = 0;
        gSlideLabel.alpha = a;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        gDragging = NO;
        if (g.state == UIGestureRecognizerStateEnded && x >= maxX - 8) {
            [self accept];
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                gKnob.frame = CGRectMake(4, 4, 76, 56);
                gSlideLabel.alpha = 1.0;
            }];
        }
    }
}

- (void)accept {
    if (!gCallView || gMode == 2) return;
    stopRinging();
    gStatus.text = @"0:00";
    gCallStart = [[NSDate date] retain];
    gTickTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                    selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    setMode(2);
    ONLog(@"[OpenNotifications] call accepted");
}
- (void)tick:(NSTimer *)t {
    if (!gCallStart || !gStatus) return;
    int s = (int)[[NSDate date] timeIntervalSinceDate:gCallStart];
    gStatus.text = [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}
@end

static void fireCall(void) {
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    showCall(prefString(CFSTR("caller"), @"Mom"));
}

// ---------- scheduler ----------
@interface ONScheduler : NSObject
- (void)poll:(NSTimer *)t;
- (void)pendingFire:(NSTimer *)t;
- (void)pendingCallFire:(NSTimer *)t;
@end

static ONScheduler *gSched = nil;
static NSTimer *gPending = nil;
static NSTimer *gPendingCall = nil;

static void cancelPending(void) {
    if (gPending) {
        [gPending invalidate]; [gPending release]; gPending = nil;
        ONLog(@"[OpenNotifications] scheduled message cancelled");
    }
    if (gPendingCall) {
        [gPendingCall invalidate]; [gPendingCall release]; gPendingCall = nil;
        ONLog(@"[OpenNotifications] scheduled call cancelled");
    }
}

static void armPending(void) {
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    int mins = prefInt(CFSTR("delay"), 5);
    if (mins < 1) mins = 1;
    if (gPending) { [gPending invalidate]; [gPending release]; gPending = nil; }
    gPending = [[NSTimer scheduledTimerWithTimeInterval:(mins * 60.0)
                    target:gSched selector:@selector(pendingFire:) userInfo:nil repeats:NO] retain];
    ONLog(@"[OpenNotifications] message scheduled in %d minute(s)", mins);
}

static void armPendingCall(void) {
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    int mins = prefInt(CFSTR("delay"), 5);
    if (mins < 1) mins = 1;
    if (gPendingCall) { [gPendingCall invalidate]; [gPendingCall release]; gPendingCall = nil; }
    gPendingCall = [[NSTimer scheduledTimerWithTimeInterval:(mins * 60.0)
                    target:gSched selector:@selector(pendingCallFire:) userInfo:nil repeats:NO] retain];
    ONLog(@"[OpenNotifications] call scheduled in %d minute(s)", mins);
}

@implementation ONScheduler
- (void)pendingFire:(NSTimer *)t {
    [gPending release]; gPending = nil;
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    if (prefBool(CFSTR("enabled"), YES)) postEvent(currentEvent(), 15, YES);
    else ONLog(@"[OpenNotifications] message time reached but tweak is disabled");
}
- (void)pendingCallFire:(NSTimer *)t {
    [gPendingCall release]; gPendingCall = nil;
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    if (prefBool(CFSTR("enabled"), YES)) fireCall();
    else ONLog(@"[OpenNotifications] call time reached but tweak is disabled");
}
- (void)poll:(NSTimer *)t {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:TRIGGER_PATH]) {
        NSString *txt = [NSString stringWithContentsOfFile:TRIGGER_PATH
                                    encoding:NSUTF8StringEncoding error:NULL];
        unsigned int dest = txt ? (unsigned int)[txt intValue] : 0;
        if (dest == 0) dest = 15;
        [fm removeItemAtPath:TRIGGER_PATH error:NULL];
        ONLog(@"[OpenNotifications] file trigger");
        postEvent(currentEvent(), dest, YES);
    }
    if ([fm fileExistsAtPath:CALL_TRIGGER_PATH]) {
        [fm removeItemAtPath:CALL_TRIGGER_PATH error:NULL];
        ONLog(@"[OpenNotifications] call file trigger");
        fireCall();
    }
}
@end

// ---------- notifications from the settings pane ----------
static void onTest(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ONLog(@"[OpenNotifications] test button");
        postEvent(currentEvent(), 15, YES);
    });
}
static void onSchedule(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ armPending(); });
}
static void onCancel(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ cancelPending(); });
}
static void onCall(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ONLog(@"[OpenNotifications] fake call button");
        fireCall();
    });
}
static void onCallSchedule(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ armPendingCall(); });
}

// ---------- startup ----------
static void setupSpringBoard(void) {
    struct utsname u;
    uname(&u);
    ONLog(@"[OpenNotifications] loaded into SpringBoard: %s, iOS %@, idiom %s",
          u.machine, [[UIDevice currentDevice] systemVersion],
          UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? "iPad" : "iPhone");
    gSched = [[ONScheduler alloc] init];

    CFNotificationCenterRef dn = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(dn, NULL, onTest, CFSTR("com.opennotifications.tweak/test"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dn, NULL, onSchedule, CFSTR("com.opennotifications.tweak/schedule"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dn, NULL, onCancel, CFSTR("com.opennotifications.tweak/cancel"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dn, NULL, onCall, CFSTR("com.opennotifications.tweak/call"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(dn, NULL, onCallSchedule, CFSTR("com.opennotifications.tweak/callschedule"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:5.0 target:gSched
                 selector:@selector(poll:) userInfo:nil repeats:YES];
    });
}

%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if ([bid isEqualToString:@"com.apple.springboard"]) {
        setupSpringBoard();
    }
    [pool drain];
}
