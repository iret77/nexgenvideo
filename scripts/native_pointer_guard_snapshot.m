#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <execinfo.h>

typedef NSView *(*HitFunction)(id, SEL, NSPoint);
static HitFunction originalHit;
static Class hostingClass;
static id notificationToken;
static NSView *boundRoot, *boundProbe;
static NSWindow *boundWindow;
static int output = -1;
static BOOL inspecting;
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
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
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

static NSView *snapshotHit(id receiver, SEL selector, NSPoint location) {
    if (!NSThread.isMainThread) return originalHit(receiver, selector, location);
    if (inspecting || receiver != boundRoot) {
        recursiveCalls++;
        return originalHit(receiver, selector, location);
    }
    inspecting = YES;
    NSView *hit = nil;
    @try {
        originalCalls++;
        hit = originalHit(receiver, selector, location);
    } @catch (NSException *exception) {
        inspecting = NO;
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
            if (marker != boundProbe) { outputErrors++; return hit; }
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
            void *frames[64]; int count = backtrace(frames, 64);
            NSMutableArray *stack = [NSMutableArray array];
            for (int index = 0; index < count; index++) {
                Dl_info info = {0}; dladdr(frames[index], &info);
                [stack addObject:@{@"address": [NSString stringWithFormat:@"%p", frames[index]],
                    @"imageBase": [NSString stringWithFormat:@"%p", info.dli_fbase],
                    @"image": info.dli_fname ? @(info.dli_fname) : @"nil",
                    @"symbol": info.dli_sname ? @(info.dli_sname) : @"nil"}];
            }
            value[@"stack"] = stack;
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
    return hit;
}

__attribute__((constructor)) static void initializeSnapshot(void) {
    @autoreleasepool {
        NSString *folder = NSProcessInfo.processInfo.environment[@"NGV_POINTER_GUARD_SNAPSHOT_DIR"];
        if (!folder.isAbsolutePath) return;
        output = open([[folder stringByAppendingPathComponent:@"snapshots.jsonl"] fileSystemRepresentation],
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (output < 0) return;
        record(@{@"kind": @"loaded", @"pid": @(getpid()), @"parentPID": @(getppid()),
            @"wallTime": @(NSDate.date.timeIntervalSince1970), @"diagnosticOnly": @YES}, NO);
        notificationToken = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeKeyNotification
            object:nil queue:nil usingBlock:^(NSNotification *notification) {
                if (!NSThread.isMainThread || hostingClass) return;
                NSWindow *window = notification.object;
                NSView *root = window.contentView;
                if (!root || fabs(root.bounds.size.width - 390) > 1 || fabs(root.bounds.size.height - 640) > 1) return;
                BOOL hosting = NO;
                for (Class ancestor = object_getClass(root); ancestor; ancestor = class_getSuperclass(ancestor))
                    if ([NSStringFromClass(ancestor) containsString:@"NSHostingView"]) hosting = YES;
                const char *classImage = class_getImageName(object_getClass(root));
                NSString *testImage = NSProcessInfo.processInfo.environment[@"NGV_APPKIT_TEST_BUNDLE"];
                if (!hosting || !classImage || ![testImage isEqualToString:@(classImage)]) return;
                Class type = object_getClass(root);
                SEL selector = @selector(hitTest:);
                unsigned count = 0;
                Method *ownMethods = class_copyMethodList(type, &count);
                BOOL ownsHit = NO;
                for (unsigned index = 0; index < count; index++)
                    if (method_getName(ownMethods[index]) == selector) ownsHit = YES;
                free(ownMethods);
                Method method = class_getInstanceMethod(type, selector);
                char *returnType = method ? method_copyReturnType(method) : NULL;
                char *selfType = method ? method_copyArgumentType(method, 0) : NULL;
                char *selectorType = method ? method_copyArgumentType(method, 1) : NULL;
                char *argumentType = method ? method_copyArgumentType(method, 2) : NULL;
                BOOL abi = method && method_getNumberOfArguments(method) == 3 && returnType && argumentType
                    && selfType && selectorType && strcmp(selfType, @encode(id)) == 0
                    && strcmp(selectorType, @encode(SEL)) == 0
                    && strcmp(returnType, @encode(id)) == 0 && strcmp(argumentType, @encode(NSPoint)) == 0;
                free(returnType); free(argumentType); free(selfType); free(selectorType);
                if (ownsHit || !abi) {
                    record(@{@"kind": @"hook-rejected", @"ownHitOverride": @(ownsHit), @"diagnosticOnly": @YES}, NO);
                    return;
                }
                originalHit = (HitFunction)method_getImplementation(method);
                hostingClass = type; boundRoot = root; boundWindow = window;
                BOOL added = class_addMethod(type, selector, (IMP)snapshotHit, method_getTypeEncoding(method));
                if (!added) { hostingClass = Nil; boundRoot = nil; boundWindow = nil; originalHit = NULL; }
                hookTime = NSDate.date.timeIntervalSince1970;
                Dl_info image = {0}; dladdr((const void *)snapshotHit, &image);
                record(@{@"kind": @"hook-ready", @"installed": @(added), @"pid": @(getpid()),
                    @"rootClass": NSStringFromClass(type), @"rootClassImage": @(classImage),
                    @"root": identity(root), @"windowIdentity": identity(window), @"window": @(window.windowNumber),
                    @"typeEncoding": @(method_getTypeEncoding(method)),
                    @"originalIMP": [NSString stringWithFormat:@"%p", (void *)originalHit],
                    @"inspectorImage": image.dli_fname ? @(image.dli_fname) : @"nil",
                    @"wallTime": @(hookTime), @"mainThread": @(NSThread.isMainThread), @"diagnosticOnly": @YES}, NO);
            }];
    }
}

__attribute__((destructor)) static void finishSnapshot(void) {
    @autoreleasepool {
        BOOL persisted = record(@{@"kind": @"finished", @"pid": @(getpid()), @"samples": @(samples),
            @"originalCalls": @(originalCalls), @"transparentReturns": @(transparentReturns),
            @"recursiveCalls": @(recursiveCalls), @"hookTime": @(hookTime), @"firstHitTime": @(firstHitTime),
            @"outputErrors": @(outputErrors), @"rejectedRecords": @(rejectedRecords),
            @"wallTime": @(NSDate.date.timeIntervalSince1970), @"diagnosticOnly": @YES}, YES);
        BOOL closed = output >= 0 && close(output) == 0; output = -1;
        if (!persisted || !closed) {
            const char *message = "NGV_POINTER_INSPECTOR_FINALIZATION_FAILED\n";
            write(STDERR_FILENO, message, strlen(message));
        }
    }
}
