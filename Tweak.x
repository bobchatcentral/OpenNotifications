#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>

#define SETTINGS_DOMAIN CFSTR("com.opennotifications.settings")
#define TRIGGER_PATH @"/var/mobile/on_test_now"
#define CALL_TRIGGER_PATH @"/var/mobile/on_call_now"
#define LOG_PATH "/var/mobile/opennotifications.log"
#define DUMP_PATH "/var/mobile/on_methods.txt"
#define DEFAULT_TONE @"/System/Library/CoreServices/SpringBoard.app/ring.m4r"

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

static void dumpClass(const char *name) {
    Class c = objc_getClass(name);
    FILE *f = fopen(DUMP_PATH, "a");
    if (!f) return;
    if (!c) { fprintf(f, "== %s: NOT FOUND ==\n", name); fclose(f); return; }
    unsigned int n = 0, i;
    Method *m = class_copyMethodList(c, &n);
    fprintf(f, "== %s instance methods (%u) ==\n", name, n);
    for (i = 0; i < n; i++) fprintf(f, "- %s\n", sel_getName(method_getName(m[i])));
    free(m);
    m = class_copyMethodList(object_getClass(c), &n);
    fprintf(f, "== %s class methods (%u) ==\n", name, n);
    for (i = 0; i < n; i++) fprintf(f, "+ %s\n", sel_getName(method_getName(m[i])));
    free(m);
    fclose(f);
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

static NSDictionary *currentEvent(void) {
    CFPreferencesAppSynchronize(SETTINGS_DOMAIN);
    return [NSDictionary dictionaryWithObjectsAndKeys:
            prefString(CFSTR("sender"), @"Alex"), @"title",
            prefString(CFSTR("message"), @"hey, are you free later?"), @"message",
            @"com.apple.MobileSMS", @"sectionID", nil];
}

// ---------- capture the BBServer instance ----------
%hook BBServer
- (id)init {
    id r = %orig;
    if (r) { gServer = r; ONLog(@"[OpenNotifications] captured BBServer via init"); }
    return r;
}
- (void)publishBulletinRequest:(id)req destinations:(unsigned int)d {
    if (!gServer) { gServer = self; ONLog(@"[OpenNotifications] captured BBServer via publish"); }
    %orig;
}
%end

// ---------- posting banners ----------
static void postEvent(NSDictionary *e, unsigned int dest, BOOL tone) {
    if (!gServer) { ONLog(@"[OpenNotifications] server not captured yet, cannot post"); return; }
    Class reqClass = objc_getClass("BBBulletinRequest");
    if (!reqClass) { ONLog(@"[OpenNotifications] BBBulletinRequest class missing"); return; }

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
        ONLog(@"[OpenNotifications] keepAwake: backlight %s, resetLockScreenIdleTimer %d, away %s, undimScreen %d",
              inst ? "found" : "MISSING",
              (inst && [inst respondsToSelector:@selector(resetLockScreenIdleTimer)]),
              ai ? "found" : "MISSING",
              (ai && [ai respondsToSelector:@selector(undimScreen)]));
    }
}

static void wakeScreen(void) {
    id bl = objc_getClass("SBBacklightController");
    id inst = (bl && [bl respondsToSelector:@selector(sharedInstance)]) ? [bl sharedInstance] : nil;
    ONLog(@"[OpenNotifications] wake: backlight controller %s", inst ? "found" : "MISSING");
    if (inst) {
        if ([inst respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)]) {
            ONLog(@"[OpenNotifications] wake: turnOnScreenFullyWithBacklightSource:");
            [inst turnOnScreenFullyWithBacklightSource:1];
        }
        if ([inst respondsToSelector:@selector(turnOnScreenWithBacklightSource:)]) {
            ONLog(@"[OpenNotifications] wake: turnOnScreenWithBacklightSource:");
            [inst turnOnScreenWithBacklightSource:1];
        }
        if ([inst respondsToSelector:@selector(animateBacklightToFactor:duration:source:)]) {
            ONLog(@"[OpenNotifications] wake: animateBacklightToFactor");
            [inst animateBacklightToFactor:1.0f duration:0.0 source:1];
        }
    }
    keepAwake();
}

// ---------- fake call screen ----------
@interface ONCallHandler : NSObject
- (void)accept;
- (void)decline;
- (void)tick:(NSTimer *)t;
- (void)ring:(NSTimer *)t;
- (void)timeout:(NSTimer *)t;
- (void)awake:(NSTimer *)t;
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
static UILabel *gStatus = nil;
static UIButton *gAcceptBtn = nil;
static UIButton *gDeclineBtn = nil;
static UIView *gCallView = nil;
static NSDate *gCallStart = nil;
static NSString *gCallerName = nil;

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
    if (gTickTimer) { [gTickTimer invalidate]; [gTickTimer release]; gTickTimer = nil; }
    if (gAwakeTimer) { [gAwakeTimer invalidate]; [gAwakeTimer release]; gAwakeTimer = nil; }
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    if (gCallWindow) { [gCallWindow setHidden:YES]; [gCallWindow release]; gCallWindow = nil; }
    [gCallStart release]; gCallStart = nil;
    gStatus = nil; gAcceptBtn = nil; gDeclineBtn = nil; gCallView = nil;
    ONLog(@"[OpenNotifications] call dismissed");
}

static UIButton *makeButton(NSString *title, UIColor *color, CGRect f, SEL sel) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f;
    b.backgroundColor = color;
    b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:gCallHandler action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// loops the system sound until the call ends
static void ringDone(SystemSoundID sid, void *ctx) {
    if (gRingSIDActive) AudioServicesPlaySystemSound(sid);
}

static void startRinging(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@"/Library/Ringtones" error:NULL];
    ONLog(@"[OpenNotifications] ringtones available: %@", [files componentsJoinedByString:@", "]);

    NSString *name = prefString(CFSTR("ringtone"), @"Marimba");
    NSString *lname = [name lowercaseString];
    NSString *src = nil;

    if (([lname isEqualToString:@"marimba"] || [lname isEqualToString:@"default"])
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

    NSString *tmp = @"/tmp/on_ring.m4a";
    [fm removeItemAtPath:tmp error:NULL];
    NSError *cerr = nil;
    BOOL copied = [fm copyItemAtPath:src toPath:tmp error:&cerr];
    ONLog(@"[OpenNotifications] ringtone copy: %d %@", copied, cerr ? [cerr localizedDescription] : @"");
    NSString *playPath = copied ? tmp : src;

    // Method 1: system sound (follows ringer volume and silent switch)
    SystemSoundID sid = 0;
    OSStatus st = AudioServicesCreateSystemSoundID((CFURLRef)[NSURL fileURLWithPath:playPath], &sid);
    ONLog(@"[OpenNotifications] system sound create status %d", (int)st);
    if (st == 0 && sid) {
        gRingSID = sid;
        gRingSIDActive = YES;
        AudioServicesAddSystemSoundCompletion(sid, NULL, NULL, ringDone, NULL);
        AudioServicesPlaySystemSound(sid);
        ONLog(@"[OpenNotifications] ringtone playing as system sound");
    } else {
        // Method 2: AVAudioPlayer fallback
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&err];
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        gRing = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:playPath] error:&err];
        if (gRing) {
            gRing.numberOfLoops = -1;
            BOOL ok = [gRing play];
            ONLog(@"[OpenNotifications] ringtone playing via AVAudioPlayer: %d", ok);
        } else {
            ONLog(@"[OpenNotifications] AVAudioPlayer load failed: %@", [err localizedDescription]);
        }
    }

    gRingTimer = [[NSTimer scheduledTimerWithTimeInterval:2.0 target:gCallHandler
                    selector:@selector(ring:) userInfo:nil repeats:YES] retain];
    gTimeoutTimer = [[NSTimer scheduledTimerWithTimeInterval:30.0 target:gCallHandler
                    selector:@selector(timeout:) userInfo:nil repeats:NO] retain];
}

static void showCall(NSString *name) {
    if (gCallWindow) return;
    if (!gCallHandler) gCallHandler = [[ONCallHandler alloc] init];
    [gCallerName release];
    gCallerName = [name copy];

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

    UILabel *sub = [[[UILabel alloc] initWithFrame:CGRectMake(0, 70, b.size.width, 24)] autorelease];
    sub.text = @"mobile";
    sub.textAlignment = UITextAlignmentCenter;
    sub.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    sub.backgroundColor = [UIColor clearColor];
    sub.font = [UIFont systemFontOfSize:18];
    [gCallView addSubview:sub];

    UILabel *nm = [[[UILabel alloc] initWithFrame:CGRectMake(10, 100, b.size.width - 20, 50)] autorelease];
    nm.text = name;
    nm.textAlignment = UITextAlignmentCenter;
    nm.textColor = [UIColor whiteColor];
    nm.backgroundColor = [UIColor clearColor];
    nm.font = [UIFont boldSystemFontOfSize:38];
    nm.adjustsFontSizeToFitWidth = YES;
    [gCallView addSubview:nm];

    gStatus = [[[UILabel alloc] initWithFrame:CGRectMake(0, 160, b.size.width, 24)] autorelease];
    gStatus.text = @"incoming call...";
    gStatus.textAlignment = UITextAlignmentCenter;
    gStatus.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    gStatus.backgroundColor = [UIColor clearColor];
    gStatus.font = [UIFont systemFontOfSize:18];
    [gCallView addSubview:gStatus];

    CGFloat y = b.size.height - 130;
    gDeclineBtn = makeButton(@"Decline", [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0],
                             CGRectMake(30, y, 120, 60), @selector(decline));
    gAcceptBtn = makeButton(@"Accept", [UIColor colorWithRed:0.1 green:0.7 blue:0.25 alpha:1.0],
                            CGRectMake(b.size.width - 150, y, 120, 60), @selector(accept));
    [gCallView addSubview:gDeclineBtn];
    [gCallView addSubview:gAcceptBtn];

    [gCallWindow setHidden:NO];
    startRinging();
    ONLog(@"[OpenNotifications] call shown for %@", name);
}

@implementation ONCallHandler
- (void)awake:(NSTimer *)t { keepAwake(); }
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
- (void)accept {
    stopRinging();
    [gAcceptBtn removeFromSuperview];
    [gDeclineBtn removeFromSuperview];
    gAcceptBtn = nil; gDeclineBtn = nil;
    CGRect b = [[UIScreen mainScreen] bounds];
    UIButton *end = makeButton(@"End", [UIColor colorWithRed:0.85 green:0.15 blue:0.15 alpha:1.0],
                               CGRectMake((b.size.width - 160) / 2, b.size.height - 130, 160, 60),
                               @selector(decline));
    [gCallView addSubview:end];
    gStatus.text = @"0:00";
    gCallStart = [[NSDate date] retain];
    gTickTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                    selector:@selector(tick:) userInfo:nil repeats:YES] retain];
    ONLog(@"[OpenNotifications] call accepted");
}
- (void)tick:(NSTimer *)t {
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
- (void)dumpLater:(NSTimer *)t;
@end

static ONScheduler *gSched = nil;
static NSTimer *gPending = nil;
static NSTimer *gPendingCall = nil;

static void cancelPending(void) {
    if (gPending) { [gPending invalidate]; [gPending release]; gPending = nil;
        ONLog(@"[OpenNotifications] scheduled message cancelled"); }
    if (gPendingCall) { [gPendingCall invalidate]; [gPendingCall release]; gPendingCall = nil;
        ONLog(@"[OpenNotifications] scheduled call cancelled"); }
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
- (void)dumpLater:(NSTimer *)t {
    remove(DUMP_PATH);
    dumpClass("SBBacklightController");
    dumpClass("SBAwayController");
    dumpClass("TLToneManager");
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
%ctor {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ONLog(@"[OpenNotifications] loaded into SpringBoard");
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
        [NSTimer scheduledTimerWithTimeInterval:20.0 target:gSched
                 selector:@selector(dumpLater:) userInfo:nil repeats:NO];
    });
    [pool drain];
}
