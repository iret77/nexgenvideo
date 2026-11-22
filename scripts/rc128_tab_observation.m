// Included before the existing NGVTestRuntimeApplication implementation in the diagnostic build only.
#include <stdint.h>
#include <string.h>

static NSWindow *tabWindow;
static NSDictionary<NSString *, NSTextField *> *tabFields;
static NSEvent *postedDown, *postedUp;
static NSResponder *initialEditor;
static id localObserver;
static BOOL receivedUp, dispatchFinished, followupTab;
static int tabFD = -1;
static unsigned tabRows;

static BOOL isProbeTab(NSEvent *event) {
    return (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) && event.keyCode == 48
        && !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                                    NSEventModifierFlagOption | NSEventModifierFlagShift)) && !event.isARepeat;
}

static NSString *stampBits(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)bits];
}

static NSString *fieldName(NSView *view) {
    for (NSString *key in tabFields) {
        if (view == tabFields[key] || [view isDescendantOf:tabFields[key]]) return key;
    }
    return view ? @"other" : @"none";
}

static NSString *currentOwner(void) {
    NSResponder *first = tabWindow.firstResponder;
    if (![first isKindOfClass:NSTextView.class]) return @"none";
    NSString *owner = nil;
    for (NSString *key in tabFields) {
        if (tabFields[key].currentEditor == first) {
            if (owner) return @"ambiguous";
            owner = key;
        }
    }
    return owner ?: @"none";
}

static void tabRow(NSString *stage, NSEvent *event, NSDictionary *extra) {
    if (tabFD < 0 || tabRows >= 48) return;
    NSMutableDictionary *row = [@{@"stage": stage, @"ordinal": @(++tabRows), @"window": @(tabWindow.windowNumber),
        @"keyWindow": @(NSApp.keyWindow == tabWindow), @"owner": currentOwner(),
        @"sameEditorAsAtPost": @(tabWindow.firstResponder == initialEditor),
        @"uptime": @(NSProcessInfo.processInfo.systemUptime)} mutableCopy];
    if (event) {
        NSEvent *posted = event.type == NSEventTypeKeyDown ? postedDown : postedUp;
        row[@"type"] = event.type == NSEventTypeKeyDown ? @"down" : @"up";
        row[@"eventWindow"] = @(event.windowNumber);
        row[@"stampBits"] = stampBits(event.timestamp);
        if (posted) row[@"originalBitsAtRead"] = stampBits(posted.timestamp);
    }
    [row addEntriesFromDictionary:extra ?: @{}];
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:row options:0 error:NULL];
    if (!bytes || !writeAll(tabFD, bytes.bytes, bytes.length) || !writeAll(tabFD, "\n", 1)) _Exit(74);
}

static BOOL bindForm(NSWindow *window) {
    if (!window.isVisible || NSApp.keyWindow != window || !window.contentView) return NO;
    NSArray *ids = @[@"name", @"fov", @"width", @"untouched", @"height"];
    NSMutableDictionary *markers = [NSMutableDictionary dictionary];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    NSMutableArray<NSView *> *todo = [NSMutableArray arrayWithObject:window.contentView];
    for (unsigned visited = 0; todo.count && visited < 512; visited++) {
        NSView *view = todo.lastObject;
        [todo removeLastObject];
        if (view.identifier && [ids containsObject:view.identifier]) {
            if (markers[view.identifier]) return NO;
            markers[view.identifier] = view;
        }
        if ([view isKindOfClass:NSTextField.class] && ((NSTextField *)view).isEditable) [fields addObject:(NSTextField *)view];
        [todo addObjectsFromArray:view.subviews];
    }
    if (todo.count || markers.count != ids.count) return NO;
    NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
    for (NSString *key in ids) {
        NSView *marker = markers[key];
        NSRect frame = [marker convertRect:marker.bounds toView:window.contentView];
        for (NSTextField *field in fields) {
            NSRect bounds = [field convertRect:field.bounds toView:window.contentView];
            if (NSPointInRect(NSMakePoint(NSMidX(frame), NSMidY(frame)), bounds)) {
                if (mapping[key]) return NO;
                mapping[key] = field;
            }
        }
    }
    if ([NSSet setWithArray:mapping.allValues].count != ids.count ||
        ![window.firstResponder isKindOfClass:NSTextView.class] ||
        ((NSTextField *)mapping[@"name"]).currentEditor != window.firstResponder) return NO;
    tabFields = mapping.copy;
    tabWindow = window;
    return YES;
}

static NSDictionary *nextViews(void) {
    return @{@"nextFromName": fieldName(tabFields[@"name"].nextValidKeyView),
             @"autoLoop": @(tabWindow.autorecalculatesKeyViewLoop)};
}

static void tabPosting(NSEvent *event) {
    if (!NSThread.isMainThread || !isProbeTab(event)) return;
    if (postedDown) {
        if (event.windowNumber != tabWindow.windowNumber) return;
        if (event.type == NSEventTypeKeyUp && !postedUp) {
            postedUp = event;
            tabRow(@"post", event, nil);
        } else if (event.type == NSEventTypeKeyDown && !followupTab) {
            followupTab = YES;
            tabRow(@"next-tab", nil, nil);
        }
        return;
    }
    if (event.type != NSEventTypeKeyDown || event.windowNumber != NSApp.keyWindow.windowNumber || !bindForm(NSApp.keyWindow)) return;
    const char *path = getenv("NGV_RC128_TAB_OBSERVATION");
    if (!path || path[0] != '/') _Exit(74);
    tabFD = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (tabFD < 0) _Exit(74);
    initialEditor = tabWindow.firstResponder;
    postedDown = event;
    tabRow(@"post", event, nil);
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *key in tabFields) {
        [center addObserverForName:NSControlTextDidEndEditingNotification object:tabFields[key] queue:nil
                        usingBlock:^(NSNotification *note) {
            if (followupTab || !tabWindow.isVisible) return;
            NSNumber *movement = note.userInfo[@"NSTextMovement"];
            tabRow(@"end-editing", nil, @{@"source": key, @"movement": movement ?: NSNull.null,
                                         @"tabMovement": @(movement && movement.integerValue == NSTabTextMovement)});
        }];
    }
    localObserver = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
        handler:^NSEvent *(NSEvent *local) {
            if (!followupTab && !receivedUp && isProbeTab(local) && local.windowNumber == tabWindow.windowNumber) {
                tabRow(@"local", local, nil);
                if (local.type == NSEventTypeKeyUp) receivedUp = YES;
            }
            return local;
        }];
    if (!localObserver) _Exit(74);
    if (getenv("NGV_RC128_REBUILD_LOOP")) {
        tabRow(@"before-rebuild", nil, nil);
        [tabWindow recalculateKeyViewLoop];
        tabRow(@"after-rebuild", nil, nil);
    }
}

static BOOL tabDispatch(NSEvent *event) {
    return NSThread.isMainThread && tabWindow && !dispatchFinished && !followupTab &&
        isProbeTab(event) && event.windowNumber == tabWindow.windowNumber;
}

static void tabDispatched(NSEvent *event) {
    tabRow(@"after-super", event, nil);
    if (event.type != NSEventTypeKeyUp) return;
    dispatchFinished = YES;
    // Query navigation only after the unmodified Tab has returned from AppKit.
    tabRow(@"after-up-loop", nil, nextViews());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!followupTab && tabWindow.isVisible && tabWindow.isKeyWindow) tabRow(@"settled", nil, nil);
    });
}
