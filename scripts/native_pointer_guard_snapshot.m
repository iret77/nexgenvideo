#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <execinfo.h>
#import <sys/stat.h>
#import <limits.h>
#import <stdlib.h>
#import <stdatomic.h>

typedef NSView *(*HitFunction)(id, SEL, NSPoint);
static HitFunction originalHit;
static Class hostingClass;
typedef NSRect (*RectFunction)(id, SEL, NSRect, NSView *);
static RectFunction originalRect;
static Class probeClass;
static NSArray *notificationTokens;
static CFRunLoopObserverRef loopObserver;
static NSString *expectedImage;
static NSUInteger discoveryCount, discoverySuppressed, discoveryAttempts, rectSamples, rectCalls, rectReturns;
static NSView *boundRoot, *boundProbe;
static NSWindow *boundWindow;
static int output = -1;
static BOOL inspecting;
static atomic_bool stopping;
static atomic_uint activeObservations;
static NSUInteger samples, originalCalls, transparentReturns, recursiveCalls, bytesWritten;
static NSUInteger outputErrors, rejectedRecords;
static NSTimeInterval hookTime, firstHitTime;

static NSArray *rect(NSRect value) {
    if (!isfinite(value.origin.x) || !isfinite(value.origin.y)
        || !isfinite(value.size.width) || !isfinite(value.size.height)) return @[];
    return @[@(value.origin.x), @(value.origin.y), @(value.size.width), @(value.size.height)];
}

static NSArray *point(NSPoint value) {
    return isfinite(value.x) && isfinite(value.y) ? @[@(value.x), @(value.y)] : @[];
}

static NSString *identity(id value) { return value ? [NSString stringWithFormat:@"%p", (__bridge void *)value] : @"nil"; }

static BOOL record(NSDictionary *value, BOOL terminal) {
    @try {
        if (output < 0) { outputErrors++; return NO; }
        NSMutableDictionary *row = [value mutableCopy];
        row[@"pid"] = @(getpid()); row[@"diagnosticOnly"] = @YES;
        if (!row[@"wallTime"]) row[@"wallTime"] = @(NSDate.date.timeIntervalSince1970);
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:&error];
        NSUInteger limit = terminal ? 1024 * 1024 : 1024 * 1024 - 4096;
        if (!data || error || data.length > (terminal ? 4095 : 65536)
            || bytesWritten + data.length + 1 > limit) { rejectedRecords++; return NO; }
        NSMutableData *line = [data mutableCopy];
        [line appendBytes:"\n" length:1];
        const uint8_t *buffer = line.bytes;
        NSUInteger remaining = line.length;
        while (remaining) {
            ssize_t count = write(output, buffer, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { outputErrors++; return NO; }
            bytesWritten += count; buffer += count; remaining -= count;
        }
        if (fsync(output) != 0) { outputErrors++; return NO; }
        return YES;
    } @catch (NSException *exception) {
        outputErrors++; return NO;
    }
}

static NSDictionary *accessibilityChain(id element) {
    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSString *end = @"nil"; BOOL complete = NO;
    for (NSUInteger depth = 0; element && depth < 32; depth++) {
        NSString *key = identity(element);
        if ([seen containsObject:key]) { end = @"cycle"; break; }
        [seen addObject:key];
        if (![element conformsToProtocol:@protocol(NSAccessibility)]) { end = @"nonProtocol"; break; }
        id<NSAccessibility> accessible = element;
        [result addObject:@{@"class": NSStringFromClass([element class]), @"identity": key,
            @"role": [accessible accessibilityRole] ?: @"nil", @"frame": rect([accessible accessibilityFrame]),
            @"enabled": @([accessible isAccessibilityEnabled])}];
        if (element == boundWindow) { complete = YES; end = @"boundWindow"; break; }
        element = [accessible accessibilityParent];
        end = element ? @"depthLimit" : @"nil";
    }
    return @{@"elements": result, @"end": end, @"completeToBoundWindow": @(complete)};
}

static NSView *probe(NSView *root) {
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:root];
    NSView *found = nil;
    NSUInteger visited = 0;
    while (pending.count && visited++ < 4096) {
        NSView *view = pending.lastObject; [pending removeLastObject];
        if ([view.identifier isEqualToString:@"pointer.field"]) {
            if (found) return nil;
            found = view;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    return pending.count ? nil : found;
}

static NSArray *ancestry(NSView *view) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger depth = 0; view && depth < 32; depth++, view = view.superview)
        [result addObject:@{@"class": NSStringFromClass(view.class), @"identity": identity(view)}];
    return result;
}

static NSArray *classes(id value) {
    NSMutableArray *result = [NSMutableArray array];
    for (Class type = object_getClass(value); type && result.count < 32; type = class_getSuperclass(type))
        [result addObject:NSStringFromClass(type)];
    return result;
}

static NSDictionary *fileIdentity(NSString *path) {
    if (!path.isAbsolutePath) return @{};
    char resolved[PATH_MAX]; struct stat value;
    if (!realpath(path.fileSystemRepresentation, resolved) || stat(resolved, &value) != 0) return @{};
    return @{@"path": @(resolved), @"device": @((unsigned long long)value.st_dev),
        @"inode": @((unsigned long long)value.st_ino)};
}

static BOOL sameImage(NSString *path) {
    NSDictionary *actual = fileIdentity(path), *wanted = fileIdentity(expectedImage);
    return actual.count && wanted.count && [actual isEqual:wanted];
}

static BOOL owns(Class type, SEL selector) {
    unsigned count = 0; Method *methods = class_copyMethodList(type, &count); BOOL found = NO;
    for (unsigned index = 0; index < count; index++) if (method_getName(methods[index]) == selector) found = YES;
    free(methods); return found;
}

static BOOL abi(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count) return NO;
    char *returned = method_copyReturnType(method); BOOL matches = returned && strcmp(returned, result) == 0;
    free(returned);
    for (unsigned index = 0; index < arguments.count; index++) {
        char *value = method_copyArgumentType(method, index);
        matches = matches && value && strcmp(value, arguments[index].UTF8String) == 0; free(value);
    }
    return matches;
}

static NSArray *stackTrace(void) {
    void *frames[64]; int count = backtrace(frames, 64); NSMutableArray *result = [NSMutableArray array];
    for (int index = 0; index < count; index++) {
        Dl_info info = {0}; dladdr(frames[index], &info);
        [result addObject:@{@"address": [NSString stringWithFormat:@"%p", frames[index]],
            @"imageBase": [NSString stringWithFormat:@"%p", info.dli_fbase],
            @"image": info.dli_fname ? @(info.dli_fname) : @"nil", @"symbol": info.dli_sname ? @(info.dli_sname) : @"nil"}];
    }
    return result;
}

static NSArray *clipStates(NSView *marker) {
    NSMutableArray *result = [NSMutableArray array];
    NSUInteger depth = 0;
    for (NSView *view = marker.superview; view && depth++ < 32; view = view.superview) {
        if (![view isKindOfClass:NSClipView.class]) continue;
        NSClipView *clip = (NSClipView *)view;
        NSScrollView *scroll = clip.enclosingScrollView;
        if (!scroll || scroll.contentView != clip) continue;
        NSRect frame = [marker.superview convertRect:marker.frame toView:clip];
        [result addObject:@{@"scroll": identity(scroll), @"clip": identity(clip), @"bounds": rect(clip.bounds),
            @"probeFrame": rect(frame), @"isFlipped": @(clip.isFlipped),
            @"widthFits": @(frame.size.width <= clip.bounds.size.width),
            @"heightFits": @(frame.size.height <= clip.bounds.size.height),
            @"contains": @(NSContainsRect(clip.bounds, frame))}];
    }
    return result;
}

static NSView *snapshotHit(id receiver, SEL selector, NSPoint location);

static BOOL bindProbe(NSView *marker) {
    NSWindow *window = marker.window; NSView *root = window.contentView;
    if (boundRoot) return boundRoot == root && boundWindow == window && boundProbe == marker && probe(root) == marker;
    BOOL hosting = NO;
    for (Class type = object_getClass(root); type; type = class_getSuperclass(type))
        if ([NSStringFromClass(type) containsString:@"NSHostingView"]) hosting = YES;
    Class type = object_getClass(root); Method ax = class_getInstanceMethod(type, @selector(accessibilityHitTest:));
    Dl_info axInfo = {0}; if (ax) dladdr((void *)method_getImplementation(ax), &axInfo);
    const char *classImage = type ? class_getImageName(type) : NULL;
    BOOL classMatches = !classImage || sameImage(@(classImage));
    BOOL axMatches = axInfo.dli_fname && sameImage(@(axInfo.dli_fname));
    BOOL eligible = window && root && hosting && classMatches && axMatches
        && owns(type, @selector(accessibilityHitTest:)) && probe(root) == marker;
    if (discoveryCount < 32) {
        discoveryCount++;
        record(@{@"kind": @"eligibility", @"eligible": @(eligible), @"hosting": @(hosting),
            @"classImageMatches": @(classMatches), @"ownAXImageMatches": @(axMatches),
            @"uniqueProbeMatches": @(root && probe(root) == marker),
            @"root": identity(root), @"probe": identity(marker), @"windowIdentity": identity(window),
            @"rootClass": root ? NSStringFromClass(type) : @"nil", @"rootBounds": root ? rect(root.bounds) : @[],
            @"classImage": classImage ? @(classImage) : @"nil", @"axImage": axInfo.dli_fname ? @(axInfo.dli_fname) : @"nil"}, NO);
    } else discoverySuppressed++;
    if (!eligible) return NO;
    Method hit = class_getInstanceMethod(type, @selector(hitTest:));
    BOOL compatible = !owns(type, @selector(hitTest:)) && abi(hit, @encode(id), @[@(@encode(id)), @(@encode(SEL)), @(@encode(NSPoint))]);
    if (!compatible) { outputErrors++; record(@{@"kind": @"hook-rejected", @"phase": @"hit-ABI"}, NO); return NO; }
    originalHit = (HitFunction)method_getImplementation(hit); hostingClass = type;
    boundRoot = root; boundWindow = window; boundProbe = marker;
    BOOL added = class_addMethod(type, @selector(hitTest:), (IMP)snapshotHit, method_getTypeEncoding(hit));
    hookTime = NSDate.date.timeIntervalSince1970;
    Dl_info image = {0}; dladdr((void *)snapshotHit, &image);
    record(@{@"kind": @"hook-ready", @"installed": @(added), @"mainThread": @YES,
        @"root": identity(root), @"probe": identity(marker), @"windowIdentity": identity(window), @"window": @(window.windowNumber),
        @"rootClassImage": classImage ? @(classImage) : @"nil", @"rootAXImageIdentity": fileIdentity(@(axInfo.dli_fname)),
        @"expectedImageIdentity": fileIdentity(expectedImage), @"typeEncoding": @(method_getTypeEncoding(hit)),
        @"originalIMP": [NSString stringWithFormat:@"%p", (void *)originalHit],
        @"inspectorImage": image.dli_fname ? @(image.dli_fname) : @"nil", @"wallTime": @(hookTime)}, NO);
    if (!added) outputErrors++;
    return added;
}

static NSRect snapshotRect(id receiver, SEL selector, NSRect value, NSView *destination) {
    if (!NSThread.isMainThread || inspecting || atomic_load(&stopping)) return originalRect(receiver, selector, value, destination);
    atomic_fetch_add(&activeObservations, 1);
    if (atomic_load(&stopping)) { atomic_fetch_sub(&activeObservations, 1); return originalRect(receiver, selector, value, destination); }
    inspecting = YES; NSRect returned;
    @try { rectCalls++; returned = originalRect(receiver, selector, value, destination); }
    @catch (NSException *exception) { inspecting = NO; atomic_fetch_sub(&activeObservations, 1); @throw; }
    @try {
        NSView *marker = receiver;
        if ([marker.identifier isEqualToString:@"pointer.field"] && bindProbe(marker)) {
            NSArray *clips = clipStates(marker);
            BOOL ancestor = NO;
            for (NSDictionary *clip in clips) if ([clip[@"clip"] isEqual:identity(destination)]) ancestor = YES;
            if (ancestor && rectSamples < 32) {
                NSRect bounds = destination.bounds;
                if (record(@{@"kind": @"viewport-convert", @"sample": @(rectSamples + 1),
                    @"root": identity(boundRoot), @"window": @(boundWindow.windowNumber), @"windowIdentity": identity(boundWindow),
                    @"probe": identity(marker), @"clip": identity(destination), @"inputRect": rect(value),
                    @"returnedRect": rect(returned), @"clipBounds": rect(bounds), @"rootBounds": rect(boundRoot.bounds),
                    @"probeVisibleRect": rect(marker.visibleRect), @"hidden": @(marker.isHiddenOrHasHiddenAncestor),
                    @"widthFits": @(returned.size.width <= bounds.size.width),
                    @"heightFits": @(returned.size.height <= bounds.size.height), @"ancestorClips": clips,
                    @"stack": stackTrace()}, NO)) rectSamples++;
            }
        }
    } @catch (NSException *exception) {
        outputErrors++; record(@{@"kind": @"inspector-exception", @"phase": @"rect", @"name": exception.name}, NO);
    } @finally { inspecting = NO; }
    rectReturns++; atomic_fetch_sub(&activeObservations, 1); return returned;
}

static void discover(NSString *reason, NSWindow *window) {
    if (!NSThread.isMainThread || atomic_load(&stopping)) return;
    atomic_fetch_add(&activeObservations, 1);
    @try {
        if (atomic_load(&stopping) || probeClass) return;
        if ([reason isEqualToString:@"main-loop-before-sources"] && discoveryAttempts++ >= 64) return;
        Class type = NSClassFromString(@"NexGenVideo.AppRelaunchClickProbeView");
        const char *path = type ? class_getImageName(type) : NULL;
        BOOL matches = path && sameImage(@(path));
        if (discoveryCount < 32) {
            discoveryCount++;
            record(@{@"kind": @"discovery", @"reason": reason, @"classFound": @(type != Nil),
                @"imageMatches": @(matches), @"classImage": path ? @(path) : @"nil",
                @"expectedImageIdentity": fileIdentity(expectedImage), @"windowIdentity": identity(window),
                @"rootBounds": window.contentView ? rect(window.contentView.bounds) : @[]}, NO);
        } else discoverySuppressed++;
        if (!matches || ![type isSubclassOfClass:NSView.class]) return;
        SEL selector = @selector(convertRect:toView:); Method method = class_getInstanceMethod(type, selector);
        BOOL valid = !owns(type, selector) && abi(method, @encode(NSRect),
            @[@(@encode(id)), @(@encode(SEL)), @(@encode(NSRect)), @(@encode(id))]);
        if (!valid) { outputErrors++; record(@{@"kind": @"hook-rejected", @"phase": @"rect-ABI"}, NO); return; }
        originalRect = (RectFunction)method_getImplementation(method); probeClass = type;
        BOOL added = class_addMethod(type, selector, (IMP)snapshotRect, method_getTypeEncoding(method));
        record(@{@"kind": @"probe-hook-ready", @"installed": @(added), @"class": NSStringFromClass(type),
            @"classImageIdentity": fileIdentity(@(path)), @"expectedImageIdentity": fileIdentity(expectedImage),
            @"typeEncoding": @(method_getTypeEncoding(method)), @"mainThread": @YES}, NO);
        if (!added) outputErrors++;
    } @catch (NSException *exception) {
        outputErrors++; record(@{@"kind": @"inspector-exception", @"phase": @"discovery", @"name": exception.name}, NO);
    } @finally { atomic_fetch_sub(&activeObservations, 1); }
}

static NSView *snapshotHit(id receiver, SEL selector, NSPoint location) {
    if (!NSThread.isMainThread || atomic_load(&stopping)) return originalHit(receiver, selector, location);
    if (receiver != boundRoot) return originalHit(receiver, selector, location);
    if (inspecting) {
        recursiveCalls++;
        return originalHit(receiver, selector, location);
    }
    atomic_fetch_add(&activeObservations, 1);
    if (atomic_load(&stopping)) { atomic_fetch_sub(&activeObservations, 1); return originalHit(receiver, selector, location); }
    inspecting = YES;
    NSView *hit = nil;
    @try {
        originalCalls++;
        hit = originalHit(receiver, selector, location);
    } @catch (NSException *exception) {
        inspecting = NO;
        atomic_fetch_sub(&activeObservations, 1);
        @throw;
    }
    @try {
        NSView *root = receiver;
        NSView *marker = probe(root);
        NSPoint local = [root convertPoint:location fromView:root.superview];
        NSPoint windowPoint = [root convertPoint:local toView:nil];
        NSRect markerFrame = marker ? [marker convertRect:marker.bounds toView:root] : NSZeroRect;
        if (root.window == boundWindow && marker && hit && CGRectContainsPoint(markerFrame, local) && samples < 16) {
            if (!boundProbe) boundProbe = marker;
            if (marker != boundProbe) @throw [NSException exceptionWithName:@"ChangedProbeIdentity" reason:nil userInfo:nil];
            if (!firstHitTime) firstHitTime = NSDate.date.timeIntervalSince1970;

            NSRect hitBounds = [hit convertRect:hit.bounds toView:root];
            NSPoint hitPoint = [hit convertPoint:windowPoint fromView:nil];
            BOOL nativeType = [hit isKindOfClass:NSControl.class] || [hit isKindOfClass:NSTextView.class];
            BOOL shown = !hit.isHiddenOrHasHiddenAncestor;
            BOOL visibleArea = !NSIsEmptyRect(hit.visibleRect);
            BOOL contained = CGRectContainsRect(NSInsetRect(markerFrame, -1, -1), hitBounds);
            BOOL visiblePoint = CGRectContainsPoint(hit.visibleRect, hitPoint);
            BOOL enabled = [hit isAccessibilityEnabled];
            NSString *role = [hit accessibilityRole];
            BOOL knownRole = role.length && ![role isEqualToString:NSAccessibilityUnknownRole];
            NSPoint screen = [root.window convertPointToScreen:windowPoint];
            NSMutableDictionary *value = [@{@"kind": @"guard-snapshot", @"pid": @(getpid()),
                @"wallTime": @(NSDate.date.timeIntervalSince1970), @"sample": @(samples + 1),
                @"window": @(root.window.windowNumber), @"windowIdentity": identity(boundWindow), @"root": identity(root), @"hit": identity(hit),
                @"probe": identity(marker), @"hitClass": NSStringFromClass(hit.class), @"hitClasses": classes(hit),
                @"hitAncestry": ancestry(hit), @"probeAncestry": ancestry(marker),
                @"rootPoint": point(local), @"windowPoint": point(windowPoint), @"screenPoint": point(screen),
                @"probeFrame": rect(markerFrame), @"hitBoundsInRoot": rect(hitBounds),
                @"hitVisibleRect": rect(hit.visibleRect), @"hitPoint": point(hitPoint),
                @"nativeRole": role ?: @"nil", @"nativeControlType": @(nativeType),
                @"notHidden": @(shown), @"visibleArea": @(visibleArea), @"probeContainsHitBounds": @(contained),
                @"visibleRectContainsPoint": @(visiblePoint), @"nativeAccessibilityEnabled": @(enabled),
                @"nativeKnownRole": @(knownRole), @"nativeGuardResult": @(nativeType && shown && visibleArea
                    && contained && visiblePoint && enabled && knownRole), @"diagnosticOnly": @YES} mutableCopy];
            value[@"stack"] = stackTrace();
            value[@"hostingAXChain"] = accessibilityChain([root accessibilityHitTest:screen]);
            value[@"hitAXChain"] = accessibilityChain([hit accessibilityHitTest:screen]);
            value[@"hitOwnAXChain"] = accessibilityChain(hit);
            if (record(value, NO)) samples++;
        }
    } @catch (NSException *exception) {
        outputErrors++;
        record(@{@"kind": @"inspector-exception", @"name": exception.name ?: @"unknown", @"diagnosticOnly": @YES}, NO);
    } @finally {
        inspecting = NO;
    }
    transparentReturns++;
    atomic_fetch_sub(&activeObservations, 1);
    return hit;
}

__attribute__((constructor)) static void initializeSnapshot(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *folder = environment[@"NGV_POINTER_GUARD_SNAPSHOT_DIR"];
        expectedImage = environment[@"NGV_POINTER_GUARD_EXPECTED_IMAGE"];
        if (!folder.isAbsolutePath || !expectedImage.isAbsolutePath) return;
        output = open([[folder stringByAppendingPathComponent:@"snapshots.jsonl"] fileSystemRepresentation],
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (output < 0) return;
        record(@{@"kind": @"loaded", @"parentPID": @(getppid()), @"expectedImageIdentity": fileIdentity(expectedImage)}, NO);
        NSMutableArray *tokens = [NSMutableArray array];
        for (NSString *name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                NSWindowDidUpdateNotification, NSWindowWillCloseNotification]) {
            [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(NSNotification *notification) { discover(name, notification.object); }]];
        }
        notificationTokens = tokens;
        dispatch_async(dispatch_get_main_queue(), ^{ discover(@"initial-main-queue", nil); });
        loopObserver = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeSources, true, 0,
            ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) { discover(@"main-loop-before-sources", nil); });
        if (loopObserver) CFRunLoopAddObserver(CFRunLoopGetMain(), loopObserver, kCFRunLoopCommonModes);
    }
}

__attribute__((destructor)) static void finishSnapshot(void) {
    @autoreleasepool {
        atomic_store(&stopping, true);
        for (id token in notificationTokens) [NSNotificationCenter.defaultCenter removeObserver:token];
        notificationTokens = nil;
        if (loopObserver) { CFRunLoopRemoveObserver(CFRunLoopGetMain(), loopObserver, kCFRunLoopCommonModes); CFRelease(loopObserver); }
        for (unsigned attempt = 0; atomic_load(&activeObservations) && attempt < 100; attempt++) usleep(1000);
        if (atomic_load(&activeObservations)) {
            const char *message = "NGV_POINTER_INSPECTOR_FINALIZATION_FAILED\n";
            write(STDERR_FILENO, message, strlen(message)); return;
        }
        BOOL persisted = record(@{@"kind": @"finished", @"samples": @(samples), @"rectSamples": @(rectSamples),
            @"originalCalls": @(originalCalls), @"transparentReturns": @(transparentReturns),
            @"rectCalls": @(rectCalls), @"rectReturns": @(rectReturns), @"recursiveCalls": @(recursiveCalls),
            @"hookTime": @(hookTime), @"firstHitTime": @(firstHitTime), @"discoveryCount": @(discoveryCount),
            @"discoverySuppressed": @(discoverySuppressed), @"outputErrors": @(outputErrors), @"rejectedRecords": @(rejectedRecords)}, YES);
        BOOL closed = output >= 0 && close(output) == 0; output = -1;
        if (!persisted || !closed) {
            const char *message = "NGV_POINTER_INSPECTOR_FINALIZATION_FAILED\n";
            write(STDERR_FILENO, message, strlen(message));
        }
    }
}
