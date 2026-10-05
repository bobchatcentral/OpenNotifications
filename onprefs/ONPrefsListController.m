#import <UIKit/UIKit.h>

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface ONPrefsListController : PSListController
- (void)sendTest;
- (void)scheduleMessage;
- (void)cancelScheduled;
- (void)fakeCallNow;
- (void)scheduleCall;
@end

static void postNote(CFStringRef name) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(), name, NULL, NULL, true);
}

@implementation ONPrefsListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"ONPrefs" target:self] retain];
    }
    return _specifiers;
}

- (void)sendTest        { postNote(CFSTR("com.opennotifications.tweak/test")); }
- (void)scheduleMessage { postNote(CFSTR("com.opennotifications.tweak/schedule")); }
- (void)cancelScheduled { postNote(CFSTR("com.opennotifications.tweak/cancel")); }
- (void)fakeCallNow     { postNote(CFSTR("com.opennotifications.tweak/call")); }
- (void)scheduleCall    { postNote(CFSTR("com.opennotifications.tweak/callschedule")); }

@end
