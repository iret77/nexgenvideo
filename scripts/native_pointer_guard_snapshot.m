#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
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
#import <mach-o/dyld.h>

typedef NSView *(*HitFunction)(id, SEL, NSPoint);
static HitFunction originalHit;
static Class hostingClass;
static Class runtimeHostingClass;
static IMP boundAX;
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
static void traceInitialize(NSDictionary *environment, NSString *folder);
static void traceFinish(void);
static void traceSelftest(void);
static void traceLifecycle(NSString *reason, NSWindow *window);

static NSArray *rect(NSRect value) {
    if (!isfinite(value.origin.x) || !isfinite(value.origin.y)
        || !isfinite(value.size.width) || !isfinite(value.size.height)) return @[];
    return @[@(value.origin.x), @(value.origin.y), @(value.size.width), @(value.size.height)];
}

static NSArray *point(NSPoint value) {
    return isfinite(value.x) && isfinite(value.y) ? @[@(value.x), @(value.y)] : @[];
}

static NSString *identity(id value) { return value ? [NSString stringWithFormat:@"%p", (__bridge void *)value] : @"nil"; }
static NSNumber *wireBool(BOOL value) { return value ? @YES : @NO; }

static id windowCoordinate(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NSNull.null;
    double number = [value doubleValue];
    if (isfinite(number)) return @(number);
    return @{@"nonfinite": isnan(number) ? @"nan" : (number > 0 ? @"+inf" : @"-inf")};
}

static NSDictionary *windowState(NSWindow *window, NSPoint screenPoint) {
    NSScreen *screen = NSScreen.screens.firstObject;
    NSPoint quartz = NSMakePoint(screenPoint.x, screen ? NSMaxY(screen.frame) - screenPoint.y : NAN);
    NSInteger atPoint = [NSWindow windowNumberAtPoint:screenPoint belowWindowWithWindowNumber:0];
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *rows = [NSMutableArray array], *matches = [NSMutableArray array];
    for (NSDictionary *entry in windows) {
        id raw = entry[(__bridge NSString *)kCGWindowBounds];
        BOOL readable = [raw isKindOfClass:NSDictionary.class];
        NSMutableDictionary *bounds = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"X", @"Y", @"Width", @"Height"])
            bounds[key] = readable ? windowCoordinate(raw[key]) : NSNull.null;
        id owner = entry[(__bridge NSString *)kCGWindowOwnerPID];
        id number = entry[(__bridge NSString *)kCGWindowNumber];
        [rows addObject:@{@"ownerPID": owner ?: NSNull.null, @"number": number ?: NSNull.null,
            @"boundsAvailable": wireBool(readable), @"bounds": bounds}];
        if ([owner isKindOfClass:NSNumber.class] && [number isKindOfClass:NSNumber.class]
            && [owner intValue] == getpid() && [number integerValue] == window.windowNumber)
            [matches addObject:entry];
    }
    id raw = matches.count == 1 ? matches[0][(__bridge NSString *)kCGWindowBounds] : nil;
    BOOL readable = [raw isKindOfClass:NSDictionary.class];
    CGRect frame = CGRectZero;
    BOOL decoded = readable && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)raw, &frame);
    BOOL finite = decoded && isfinite(frame.origin.x) && isfinite(frame.origin.y)
        && isfinite(frame.size.width) && isfinite(frame.size.height);
    BOOL width = decoded && CGRectGetWidth(frame) > 0, height = decoded && CGRectGetHeight(frame) > 0;
    BOOL contains = finite && screen && CGRectContainsPoint(frame, quartz);
    BOOL sameWindow = atPoint == window.windowNumber, unique = matches.count == 1;
    return @{@"windowAtPoint": @(atPoint), @"ownerPID": @(getpid()), @"windowNumber": @(window.windowNumber),
        @"screenAvailable": wireBool(screen != nil), @"firstScreenFrame": screen ? rect(screen.frame) : @[],
        @"quartzPoint": point(quartz), @"cgWindowListAvailable": wireBool(windows != nil), @"cgWindows": rows,
        @"matchingWindowCount": @(matches.count), @"cgFrame": finite ? rect(frame) : @[],
        @"predicates": @{@"windowAtPointMatches": wireBool(sameWindow), @"uniqueOwnWindow": wireBool(unique),
            @"boundsAvailable": wireBool(readable), @"boundsDecoded": wireBool(decoded), @"frameFinite": wireBool(finite),
            @"positiveWidth": wireBool(width), @"positiveHeight": wireBool(height), @"containsQuartzPoint": wireBool(contains)},
        @"result": wireBool(sameWindow && unique && readable && decoded && finite && width && height && contains)};
}

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

static IMP implementation(Class type, SEL selector) {
    Method method = class_getInstanceMethod(type, selector);
    return method ? method_getImplementation(method) : NULL;
}

static BOOL privateLineage(Class runtime, Class declared) {
    for (NSUInteger depth = 0; runtime && depth < 32; depth++, runtime = class_getSuperclass(runtime)) {
        if (runtime == declared) return YES;
        const char *image = class_getImageName(runtime);
        if ((image && !sameImage(@(image))) || owns(runtime, @selector(accessibilityHitTest:))
            || owns(runtime, @selector(hitTest:))) return NO;
    }
    return NO;
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
            @"widthFits": wireBool(frame.size.width <= clip.bounds.size.width),
            @"heightFits": wireBool(frame.size.height <= clip.bounds.size.height),
            @"contains": @(NSContainsRect(clip.bounds, frame))}];
    }
    return result;
}

static NSView *snapshotHit(id receiver, SEL selector, NSPoint location);

static BOOL boundClassMatches(void) {
    const char *image = class_getImageName(hostingClass);
    return [boundRoot class] == hostingClass && object_getClass(boundRoot) == runtimeHostingClass
        && image && sameImage(@(image))
        && privateLineage(runtimeHostingClass, hostingClass)
        && implementation(hostingClass, @selector(accessibilityHitTest:)) == boundAX
        && implementation(runtimeHostingClass, @selector(accessibilityHitTest:)) == boundAX
        && implementation(hostingClass, @selector(hitTest:)) == (IMP)snapshotHit
        && implementation(runtimeHostingClass, @selector(hitTest:)) == (IMP)snapshotHit;
}

static BOOL bindProbe(NSView *marker) {
    NSWindow *window = marker.window; NSView *root = window.contentView;
    if (boundRoot) {
        BOOL sameScope = boundRoot == root && boundWindow == window && root.window == boundWindow
            && boundProbe == marker && probe(root) == marker;
        BOOL related = boundRoot == root || boundWindow == window || boundProbe == marker;
        if (related && !sameScope && (window || boundWindow.contentView || boundRoot.window)) {
            outputErrors++; record(@{@"kind": @"scope-changed", @"phase": @"root-window-probe"}, NO);
            return NO;
        }
        if (sameScope && !boundClassMatches()) {
            outputErrors++; record(@{@"kind": @"scope-changed", @"phase": @"root-class"}, NO);
            return NO;
        }
        return sameScope;
    }
    BOOL hosting = NO;
    for (Class type = object_getClass(root); type; type = class_getSuperclass(type))
        if ([NSStringFromClass(type) containsString:@"NSHostingView"]) hosting = YES;
    Class type = [root class], runtime = object_getClass(root);
    Method ax = class_getInstanceMethod(type, @selector(accessibilityHitTest:));
    Dl_info axInfo = {0}; if (ax) dladdr((void *)method_getImplementation(ax), &axInfo);
    const char *classImage = type ? class_getImageName(type) : NULL;
    BOOL classMatches = classImage && sameImage(@(classImage));
    BOOL axMatches = axInfo.dli_fname && sameImage(@(axInfo.dli_fname));
    BOOL lineage = privateLineage(runtime, type);
    BOOL effectiveAX = ax && implementation(runtime, @selector(accessibilityHitTest:)) == method_getImplementation(ax);
    BOOL eligible = window && root && hosting && classMatches && axMatches
        && owns(type, @selector(accessibilityHitTest:)) && lineage && effectiveAX && probe(root) == marker;
    if (discoveryCount < 32) {
        discoveryCount++;
        record(@{@"kind": @"eligibility", @"eligible": @(eligible), @"hosting": @(hosting),
            @"classImageMatches": @(classMatches), @"ownAXImageMatches": @(axMatches),
            @"uniqueProbeMatches": wireBool(root && probe(root) == marker),
            @"runtimeLineageMatches": wireBool(lineage), @"effectiveAXMatches": wireBool(effectiveAX),
            @"declaredOwnAX": wireBool(owns(type, @selector(accessibilityHitTest:))),
            @"root": identity(root), @"probe": identity(marker), @"windowIdentity": identity(window),
            @"rootClass": root ? NSStringFromClass(type) : @"nil", @"runtimeRootClass": root ? NSStringFromClass(runtime) : @"nil",
            @"rootBounds": root ? rect(root.bounds) : @[],
            @"classImage": classImage ? @(classImage) : @"nil", @"axImage": axInfo.dli_fname ? @(axInfo.dli_fname) : @"nil"}, NO);
    } else discoverySuppressed++;
    if (!eligible) return NO;
    Method hit = class_getInstanceMethod(type, @selector(hitTest:));
    BOOL compatible = hit && !owns(type, @selector(hitTest:))
        && implementation(runtime, @selector(hitTest:)) == method_getImplementation(hit)
        && abi(hit, @encode(id), @[@(@encode(id)), @(@encode(SEL)), @(@encode(NSPoint))]);
    if (!compatible) { outputErrors++; record(@{@"kind": @"hook-rejected", @"phase": @"hit-ABI"}, NO); return NO; }
    originalHit = (HitFunction)method_getImplementation(hit); hostingClass = type; runtimeHostingClass = runtime;
    boundAX = method_getImplementation(ax);
    boundRoot = root; boundWindow = window; boundProbe = marker;
    BOOL added = class_addMethod(type, @selector(hitTest:), (IMP)snapshotHit, method_getTypeEncoding(hit));
    if (added && !boundClassMatches()) { outputErrors++; added = NO; }
    hookTime = NSDate.date.timeIntervalSince1970;
    Dl_info image = {0}; dladdr((void *)snapshotHit, &image);
    record(@{@"kind": @"hook-ready", @"installed": @(added), @"mainThread": @YES,
        @"root": identity(root), @"probe": identity(marker), @"windowIdentity": identity(window), @"window": @(window.windowNumber),
        @"rootClass": NSStringFromClass(type), @"runtimeRootClass": NSStringFromClass(runtime),
        @"runtimeLineageMatches": wireBool(lineage), @"effectiveAXMatches": wireBool(effectiveAX), @"declaredOwnAX": @YES,
        @"originalAXIMP": [NSString stringWithFormat:@"%p", (void *)boundAX],
        @"rootClassImage": classImage ? @(classImage) : @"nil", @"rootAXImageIdentity": fileIdentity(@(axInfo.dli_fname)),
        @"rootDeclaredImageIdentity": classImage ? fileIdentity(@(classImage)) : @{},
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
                    @"widthFits": wireBool(returned.size.width <= bounds.size.width),
                    @"heightFits": wireBool(returned.size.height <= bounds.size.height), @"ancestorClips": clips,
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
            record(@{@"kind": @"discovery", @"reason": reason, @"classFound": wireBool(type != Nil),
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
    if (receiver != boundRoot && ((NSView *)receiver).window != boundWindow) return originalHit(receiver, selector, location);
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
        BOOL detached = !root.window && !boundWindow.contentView && !boundRoot.window;
        if (!detached && (root != boundRoot || root.window != boundWindow || boundWindow.contentView != boundRoot
            || marker != boundProbe || !boundClassMatches()))
            @throw [NSException exceptionWithName:@"ChangedHostingScope" reason:nil userInfo:nil];
        if (!detached) {
            NSPoint local = [root convertPoint:location fromView:root.superview];
            NSPoint windowPoint = [root convertPoint:local toView:nil];
            NSRect markerFrame = marker ? [marker convertRect:marker.bounds toView:root] : NSZeroRect;
            if (root.window == boundWindow && marker && hit && CGRectContainsPoint(markerFrame, local) && samples < 16) {
                if (!boundProbe) boundProbe = marker;
                if (marker != boundProbe) @throw [NSException exceptionWithName:@"ChangedProbeIdentity" reason:nil userInfo:nil];
                if (!firstHitTime) firstHitTime = NSDate.date.timeIntervalSince1970;

                NSRect hitBounds = [hit convertRect:hit.bounds toView:root];
                NSPoint hitPoint = [hit convertPoint:windowPoint fromView:nil];
                BOOL controlType = [hit isKindOfClass:NSControl.class], textType = [hit isKindOfClass:NSTextView.class];
                BOOL nativeType = controlType || textType;
                BOOL hidden = hit.isHiddenOrHasHiddenAncestor, shown = !hidden;
                BOOL visibleArea = !CGRectIsEmpty(hit.visibleRect);
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
                    @"nativeRole": role ?: @"nil", @"nativeControlType": wireBool(nativeType),
                    @"hitNSControl": wireBool(controlType), @"hitNSTextView": wireBool(textType),
                    @"hitHidden": wireBool(hidden),
                    @"rolePresent": wireBool(role != nil), @"roleNonEmpty": wireBool(role.length > 0),
                    @"roleNotUnknown": wireBool(role != nil && ![role isEqualToString:NSAccessibilityUnknownRole]),
                    @"notHidden": @(shown), @"visibleArea": @(visibleArea), @"probeContainsHitBounds": @(contained),
                    @"visibleRectContainsPoint": @(visiblePoint), @"nativeAccessibilityEnabled": @(enabled),
                    @"nativeKnownRole": @(knownRole), @"nativeGuardResult": wireBool(nativeType && shown && visibleArea
                        && contained && visiblePoint && enabled && knownRole), @"diagnosticOnly": @YES} mutableCopy];
                value[@"stack"] = stackTrace();
                value[@"windowGuard"] = windowState(root.window, screen);
                value[@"hostingAXChain"] = accessibilityChain([root accessibilityHitTest:screen]);
                value[@"hitAXChain"] = accessibilityChain([hit accessibilityHitTest:screen]);
                value[@"hitOwnAXChain"] = accessibilityChain(hit);
                if (record(value, NO)) samples++;
            }
        }
    } @catch (NSException *exception) {
        outputErrors++;
        record(@{@"kind": @"inspector-exception", @"name": exception.name ?: @"unknown", @"diagnosticOnly": @YES}, NO);
    } @finally {
        inspecting = NO;
    }
    transparentReturns++;
    traceSelftest();
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
        traceInitialize(environment, folder);
        NSMutableArray *tokens = [NSMutableArray array];
        for (NSString *name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                NSWindowDidUpdateNotification, NSWindowWillCloseNotification,
                                NSWindowDidMoveNotification, NSWindowDidResizeNotification,
                                NSWindowDidChangeScreenNotification, NSWindowDidChangeOcclusionStateNotification]) {
            [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(NSNotification *notification) { traceLifecycle(name, notification.object); discover(name, notification.object); }]];
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
        traceFinish();
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

static int traceFD = -1;
static NSRecursiveLock *traceLock;
static NSString *expectedHost;
static BOOL traceEnabled, selftestMode, selftestRunning, selftestDone;
static _Thread_local unsigned traceDepth;
static NSUInteger traceSequence, traceCallSequence, traceContextSequence, traceBytes, traceErrors;
static NSMutableDictionary<NSString *, NSNumber *> *traceCalls, *traceReturns, *traceAdditionalQueries;
static NSMutableArray<NSDictionary *> *traceHooks;
static id traceMonitor;

static void traceWrite(NSDictionary *value) {
    if (traceFD < 0) return;
    [traceLock lock];
    @try {
        NSMutableDictionary *row = [value mutableCopy];
        row[@"sequence"] = @(++traceSequence); row[@"pid"] = @(getpid()); row[@"parentPID"] = @(getppid());
        row[@"wallTime"] = @(NSDate.date.timeIntervalSince1970);
        row[@"uptime"] = @(NSProcessInfo.processInfo.systemUptime); row[@"mainThread"] = wireBool(NSThread.isMainThread);
        row[@"diagnosticOnly"] = @YES;
        NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:NULL];
        if (!data || data.length > 256 * 1024 || traceBytes + data.length + 1 > 32 * 1024 * 1024) { traceErrors++; return; }
        const uint8_t *bytes = data.bytes; NSUInteger remaining = data.length;
        while (remaining) {
            ssize_t n = write(traceFD, bytes, remaining);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { traceErrors++; return; }
            remaining -= n; bytes += n;
        }
        if (write(traceFD, "\n", 1) != 1 || fsync(traceFD) != 0) traceErrors++;
        traceBytes += data.length + 1;
    } @catch (NSException *exception) { traceErrors++; }
    @finally { [traceLock unlock]; }
}

static BOOL traceCaller(void) {
    if (!traceEnabled || traceDepth || (NSThread.isMainThread && inspecting) || atomic_load(&stopping)) return NO;
    if (selftestRunning) return YES;
    void *frames[64]; int count = backtrace(frames, 64);
    for (int index = 0; index < count; index++) {
        Dl_info info = {0};
        if (dladdr(frames[index], &info) && info.dli_fname && sameImage(@(info.dli_fname))) return YES;
    }
    return NO;
}

static void traceAdditional(NSString *method) {
    if (!traceEnabled || !(traceDepth || (NSThread.isMainThread && inspecting))) return;
    [traceLock lock]; traceAdditionalQueries[method] = @([traceAdditionalQueries[method] unsignedIntegerValue] + 1); [traceLock unlock];
}

static BOOL traceWindow(NSWindow *window) {
    if (!traceEnabled || !NSThread.isMainThread || !window) return NO;
    if (selftestRunning) return YES;
    NSMutableArray *pending = [NSMutableArray array];
    if (window.contentView) [pending addObject:window.contentView];
    for (NSUInteger count = 0; pending.count && count < 4096; count++) {
        NSView *view = pending.lastObject; [pending removeLastObject];
        const char *image = class_getImageName([view class]);
        if (image && sameImage(@(image))) return YES;
        [pending addObjectsFromArray:view.subviews];
    }
    return NO;
}

static NSDictionary *traceRange(NSResponder *responder) {
    traceDepth++;
    @try {
    if (![responder isKindOfClass:NSTextView.class]) return @{@"available": @NO, @"identity": identity(responder)};
    NSTextView *text = (NSTextView *)responder; NSRange range = text.selectedRange;
    return @{@"available": @YES, @"identity": identity(text), @"class": NSStringFromClass(text.class),
        @"selection": @[@(range.location), @(range.length)], @"UTF16Length": @((text.string ?: @"").length),
        @"text": text.string ?: @"", @"editable": wireBool(text.isEditable), @"fieldEditor": wireBool(text.isFieldEditor)};
    } @finally { traceDepth--; }
}

static NSArray *traceMenu(NSMenu *menu, NSUInteger depth) {
    if (!menu || depth > 4) return @[];
    NSMutableArray *values = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (values.count >= 128) break;
        [values addObject:@{@"title": item.title ?: @"", @"key": item.keyEquivalent ?: @"",
            @"modifiers": @(item.keyEquivalentModifierMask), @"action": item.action ? NSStringFromSelector(item.action) : @"nil",
            @"target": identity(item.target), @"enabledWithoutValidation": wireBool(item.isEnabled),
            @"children": traceMenu(item.submenu, depth + 1)}];
    }
    return values;
}

static NSDictionary *traceContext(NSWindow *window) {
    if (!NSThread.isMainThread) return @{@"queryOrigin": @"ADDITIONAL_CONTEXT", @"AppKitNotQueriedOffMainThread": @YES};
    [traceLock lock]; NSUInteger contextNumber = ++traceContextSequence; [traceLock unlock];
    NSMutableDictionary *value = [@{@"queryOrigin": @"ADDITIONAL_CONTEXT", @"contextOrdinal": @(contextNumber), @"active": wireBool(NSApp.isActive),
        @"keyWindow": @(NSApp.keyWindow.windowNumber), @"keyWindowIdentity": identity(NSApp.keyWindow), @"firstResponder": traceRange(window.firstResponder),
        @"mainMenuPresent": wireBool(NSApp.mainMenu != nil), @"mainMenu": traceMenu(NSApp.mainMenu, 0),
        @"currentGlobalMouse": point(NSEvent.mouseLocation), @"currentRunLoopMode": NSRunLoop.currentRunLoop.currentMode ?: @"nil"} mutableCopy];
    NSMutableArray *screens = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) [screens addObject:@{@"frame": rect(screen.frame), @"visibleFrame": rect(screen.visibleFrame), @"backingScale": @(screen.backingScaleFactor)}];
    value[@"screens"] = screens;
    if (window) {
        value[@"window"] = @(window.windowNumber); value[@"windowIdentity"] = identity(window);
        value[@"modelFrame"] = rect(window.frame); value[@"visible"] = wireBool(window.isVisible);
        value[@"key"] = wireBool(window.isKeyWindow); value[@"ignoresMouseEvents"] = wireBool(window.ignoresMouseEvents);
        value[@"animationBehavior"] = @(window.animationBehavior); value[@"occlusionState"] = @(window.occlusionState);
        value[@"screenFrame"] = window.screen ? rect(window.screen.frame) : @[];
        value[@"modelGlobalFromCurrentMouse"] = point([window convertPointFromScreen:NSEvent.mouseLocation]);
    }
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    value[@"onScreenWindows"] = windows ?: @[];
    value[@"additionalQueryCounts"] = @{@"CGWindowListCopyWindowInfo": @1, @"screenObjects": @(screens.count), @"windowObjects": window ? @1 : @0};
    return value;
}

static NSDictionary *traceEvent(NSEvent *event) {
    traceDepth++;
    @try {
    if (!event) return @{};
    NSMutableDictionary *value = [@{@"identity": identity(event), @"type": @(event.type), @"timestamp": @(event.timestamp),
        @"timestampUnits": @"seconds-since-startup",
        @"window": @(event.windowNumber), @"windowIdentity": identity(event.window), @"flags": @(event.modifierFlags)} mutableCopy];
    value[@"getterOrigin"] = @"ADDITIONAL_OBSERVATION";
    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged) {
        value[@"keyCode"] = @(event.keyCode);
        if (event.type != NSEventTypeFlagsChanged) { value[@"characters"] = event.characters ?: @""; value[@"charactersIgnoringModifiers"] = event.charactersIgnoringModifiers ?: @""; }
    } else if (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp) {
        CGEventRef cg = event.CGEvent;
        if (cg) { value[@"CGPosition"] = point(CGEventGetLocation(cg)); value[@"CGTimestamp"] = @(CGEventGetTimestamp(cg)); value[@"CGTimestampUnits"] = @"nanoseconds-since-startup"; value[@"tag"] = @(CGEventGetIntegerValueField(cg, kCGEventSourceUserData)); }
        value[@"localPosition"] = point(event.locationInWindow);
        value[@"eventGlobalThroughModel"] = event.window ? point([event.window convertPointToScreen:event.locationInWindow]) : @[];
    }
    return value;
    } @finally { traceDepth--; }
}

static NSUInteger traceBegin(NSString *method, NSDictionary *arguments, NSWindow *window) {
    NSUInteger call;
    atomic_fetch_add(&activeObservations, 1);
    [traceLock lock]; call = ++traceCallSequence; traceCalls[method] = @([traceCalls[method] unsignedIntegerValue] + 1); [traceLock unlock];
    traceDepth++;
    @try { traceWrite(@{@"kind": @"call", @"call": @(call), @"method": method, @"arguments": arguments,
        @"context": traceContext(window), @"stack": stackTrace(), @"queryOrigin": @"ORIGINAL_EXECUTION"}); }
    @catch (NSException *exception) { traceErrors++; }
    @finally { traceDepth--; }
    return call;
}

static void traceEnd(NSString *method, NSUInteger call, id returned, NSWindow *window) {
    traceDepth++;
    @try {
        [traceLock lock]; traceReturns[method] = @([traceReturns[method] unsignedIntegerValue] + 1); [traceLock unlock];
        traceWrite(@{@"kind": @"return", @"call": @(call), @"method": method, @"returned": returned ?: NSNull.null,
            @"context": traceContext(window), @"queryOrigin": @"ORIGINAL_EXECUTION"});
    } @catch (NSException *exception) { traceErrors++; }
    @finally { traceDepth--; atomic_fetch_sub(&activeObservations, 1); }
}

static IMP traceOriginal(id receiver, SEL selector) {
    Class type = object_getClass(receiver);
    [traceLock lock]; NSArray *entries = [traceHooks copy]; [traceLock unlock];
    for (; type; type = class_getSuperclass(type))
        for (NSDictionary *entry in entries)
            if ([entry[@"class"] pointerValue] == (__bridge const void *)type && [entry[@"selector"] pointerValue] == selector)
                return (IMP)[entry[@"original"] pointerValue];
    abort();
}

static void traceFieldHooks(NSResponder *responder);
static void tracedPost(id receiver, SEL selector, NSEvent *event, BOOL atStart) {
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = traceCaller() || (!traceDepth && !atomic_load(&stopping) && traceWindow(event.window));
        if (NSThread.isMainThread && observe) traceFieldHooks(event.window.firstResponder);
        if (observe) call = traceBegin(@"postEvent:atStart:", @{@"event": traceEvent(event), @"atStart": @(atStart)}, event.window);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    ((void (*)(id, SEL, NSEvent *, BOOL))traceOriginal(receiver, selector))(receiver, selector, event, atStart);
    if (observe) traceEnd(@"postEvent:atStart:", call, @{@"eventIdentity": identity(event)}, event.window);
}

static void tracedSend(id receiver, SEL selector, NSEvent *event) {
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = !traceDepth && !atomic_load(&stopping) && traceWindow(event.window);
        if (observe) traceFieldHooks(event.window.firstResponder);
        if (observe) call = traceBegin(@"sendEvent:", @{@"event": traceEvent(event)}, event.window);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    ((void (*)(id, SEL, NSEvent *))traceOriginal(receiver, selector))(receiver, selector, event);
    if (observe) traceEnd(@"sendEvent:", call, @{@"eventIdentity": identity(event)}, event.window);
}

static NSDictionary *traceRouteScope(id target, NSEvent *event, NSWindow *keyWindow) {
    NSWindow *targetWindow = nil;
    if (NSThread.isMainThread) {
        if ([target isKindOfClass:NSWindow.class]) targetWindow = target;
        else if ([target isKindOfClass:NSView.class]) targetWindow = [(NSView *)target window];
    }
    NSWindow *eventWindow = NSThread.isMainThread ? event.window : nil;
    BOOL keyOwned = traceWindow(keyWindow);
    BOOL targetOwned = targetWindow == keyWindow ? keyOwned : traceWindow(targetWindow);
    BOOL eventOwned = eventWindow == keyWindow ? keyOwned : (eventWindow == targetWindow ? targetOwned : traceWindow(eventWindow));
    return @{@"queryOrigin": @"ADDITIONAL_SCOPE_OBSERVATION", @"ownedCaller": wireBool(traceCaller()),
        @"ownedKeyWindow": wireBool(keyOwned), @"ownedTargetWindow": wireBool(targetOwned),
        @"ownedEventWindow": wireBool(eventOwned), @"actualKeyWindowIdentity": identity(keyWindow),
        @"targetWindowIdentity": identity(targetWindow), @"eventWindowIdentity": identity(eventWindow)};
}

static BOOL traceAdmitted(NSDictionary *scope) {
    return [scope[@"ownedCaller"] boolValue] || [scope[@"ownedKeyWindow"] boolValue]
        || [scope[@"ownedTargetWindow"] boolValue] || [scope[@"ownedEventWindow"] boolValue];
}

static BOOL tracedAction(id receiver, SEL selector, SEL action, id target, id sender) {
    NSWindow *window = NSThread.isMainThread ? NSApp.keyWindow : nil;
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        if (!traceDepth && !atomic_load(&stopping)) {
            NSDictionary *scope = traceRouteScope(target, [sender isKindOfClass:NSEvent.class] ? sender : nil, window);
            observe = traceAdmitted(scope);
            if (observe) call = traceBegin(@"sendAction:to:from:", @{@"action": action ? NSStringFromSelector(action) : @"nil",
                @"target": identity(target), @"sender": identity(sender), @"scope": scope}, window);
        }
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    BOOL result = ((BOOL (*)(id, SEL, SEL, id, id))traceOriginal(receiver, selector))(receiver, selector, action, target, sender);
    if (observe) traceEnd(@"sendAction:to:from:", call, wireBool(result), window);
    return result;
}

static BOOL tracedEquivalent(id receiver, SEL selector, NSEvent *event) {
    NSWindow *window = NSThread.isMainThread ? NSApp.keyWindow : nil;
    NSString *name = [receiver isKindOfClass:NSWindow.class] ? @"window.performKeyEquivalent:" : @"menu.performKeyEquivalent:";
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        if (!traceDepth && !atomic_load(&stopping)) {
            NSDictionary *scope = traceRouteScope(receiver, event, window);
            observe = traceAdmitted(scope);
            if (observe) call = traceBegin(name, @{@"receiver": identity(receiver), @"event": traceEvent(event), @"scope": scope}, window);
        }
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    BOOL returned = ((BOOL (*)(id, SEL, NSEvent *))traceOriginal(receiver, selector))(receiver, selector, event);
    if (observe) traceEnd(name, call, wireBool(returned), window);
    return returned;
}

static NSInteger tracedWindowAt(id receiver, SEL selector, NSPoint location, NSInteger below) {
    traceAdditional(@"windowNumberAtPoint:belowWindowWithWindowNumber:");
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = traceCaller();
        if (observe) call = traceBegin(@"windowNumberAtPoint:belowWindowWithWindowNumber:", @{@"point": point(location), @"below": @(below)}, NSThread.isMainThread ? NSApp.keyWindow : nil);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    NSInteger result = ((NSInteger (*)(id, SEL, NSPoint, NSInteger))traceOriginal(receiver, selector))(receiver, selector, location, below);
    if (observe) traceEnd(@"windowNumberAtPoint:belowWindowWithWindowNumber:", call, @(result), NSThread.isMainThread ? NSApp.keyWindow : nil);
    return result;
}

static NSInteger tracedWindowNumber(id receiver, SEL selector) {
    traceAdditional(@"windowNumber");
    BOOL observe = traceCaller();
    NSUInteger call = observe ? traceBegin(@"windowNumber", @{@"receiver": identity(receiver)}, nil) : 0;
    NSInteger result = ((NSInteger (*)(id, SEL))traceOriginal(receiver, selector))(receiver, selector);
    if (observe) traceEnd(@"windowNumber", call, @(result), nil);
    return result;
}

static void tracedTextEvent(id receiver, SEL selector, id argument) {
    NSTextView *text = receiver; NSWindow *window = text.window;
    NSString *name = NSStringFromSelector(selector);
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = !traceDepth && !atomic_load(&stopping) && traceWindow(window);
        NSDictionary *argumentValue = [argument isKindOfClass:NSEvent.class] ? traceEvent(argument) : @{@"identity": identity(argument)};
        if (observe) call = traceBegin(name, @{@"receiver": identity(receiver), @"argument": argumentValue}, window);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    ((void (*)(id, SEL, id))traceOriginal(receiver, selector))(receiver, selector, argument);
    if (observe) traceEnd(name, call, @{@"receiver": identity(receiver), @"range": traceRange(text)}, window);
}

static void tracedCommand(id receiver, SEL selector, SEL command) {
    NSTextView *text = receiver; BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = !traceDepth && !atomic_load(&stopping) && traceWindow(text.window);
        if (observe) call = traceBegin(@"doCommandBySelector:", @{@"receiver": identity(text), @"command": command ? NSStringFromSelector(command) : @"nil"}, text.window);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    ((void (*)(id, SEL, SEL))traceOriginal(receiver, selector))(receiver, selector, command);
    if (observe) traceEnd(@"doCommandBySelector:", call, @{@"range": traceRange(text)}, text.window);
}

static void traceAXHooks(id element);
static id tracedAXHit(id receiver, SEL selector, NSPoint location) {
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = traceCaller();
        if (observe) call = traceBegin(@"accessibilityHitTest:", @{@"receiver": identity(receiver), @"point": point(location)}, nil);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    id returned = ((id (*)(id, SEL, NSPoint))traceOriginal(receiver, selector))(receiver, selector, location);
    if (observe) {
        @try { traceAXHooks(returned); traceEnd(@"accessibilityHitTest:", call, @{@"identity": identity(returned), @"class": returned ? NSStringFromClass([returned class]) : @"nil"}, nil); }
        @catch (NSException *exception) { traceErrors++; }
    }
    return returned;
}

static id tracedAXObject(id receiver, SEL selector) {
    BOOL observe = traceCaller(); NSString *name = NSStringFromSelector(selector);
    NSUInteger call = observe ? traceBegin(name, @{@"receiver": identity(receiver)}, nil) : 0;
    id returned = ((id (*)(id, SEL))traceOriginal(receiver, selector))(receiver, selector);
    if (observe) {
        @try { traceEnd(name, call, @{@"identity": identity(returned), @"class": returned ? NSStringFromClass([returned class]) : @"nil",
            @"value": [returned isKindOfClass:NSString.class] ? returned : NSNull.null}, nil); }
        @catch (NSException *exception) { traceErrors++; }
    }
    return returned;
}

static BOOL tracedAXEnabled(id receiver, SEL selector) {
    BOOL observe = traceCaller(); NSUInteger call = observe ? traceBegin(@"isAccessibilityEnabled", @{@"receiver": identity(receiver)}, nil) : 0;
    BOOL returned = ((BOOL (*)(id, SEL))traceOriginal(receiver, selector))(receiver, selector);
    if (observe) traceEnd(@"isAccessibilityEnabled", call, wireBool(returned), nil);
    return returned;
}

static NSRect tracedAXFrame(id receiver, SEL selector) {
    BOOL observe = traceCaller(); NSUInteger call = observe ? traceBegin(@"accessibilityFrame", @{@"receiver": identity(receiver)}, nil) : 0;
    NSRect returned = ((NSRect (*)(id, SEL))traceOriginal(receiver, selector))(receiver, selector);
    if (observe) traceEnd(@"accessibilityFrame", call, @{@"finiteRect": rect(returned), @"raw": NSStringFromRect(returned),
        @"components": @[windowCoordinate(@(returned.origin.x)), windowCoordinate(@(returned.origin.y)),
            windowCoordinate(@(returned.size.width)), windowCoordinate(@(returned.size.height))]}, nil);
    return returned;
}

static NSRange tracedRange(id receiver, SEL selector) {
    traceAdditional(@"selectedRange");
    BOOL observe = traceCaller(); NSUInteger call = observe ? traceBegin(@"selectedRange", @{@"receiver": identity(receiver)}, nil) : 0;
    NSRange returned = ((NSRange (*)(id, SEL))traceOriginal(receiver, selector))(receiver, selector);
    if (observe) traceEnd(@"selectedRange", call, @[@(returned.location), @(returned.length)], nil);
    return returned;
}

static BOOL traceInstall(Class type, SEL selector, IMP replacement, const char *result, NSArray *arguments) {
    [traceLock lock];
    @try {
    for (NSDictionary *entry in traceHooks) if ([entry[@"class"] pointerValue] == (__bridge const void *)type && [entry[@"selector"] pointerValue] == selector) return YES;
    Method method = class_getInstanceMethod(type, selector);
    if (!abi(method, result, arguments)) { traceErrors++; return NO; }
    IMP original = method_getImplementation(method);
    for (NSDictionary *entry in traceHooks) if ([entry[@"replacement"] pointerValue] == original) { traceErrors++; return NO; }
    [traceHooks addObject:@{@"class": [NSValue valueWithPointer:(__bridge const void *)type], @"selector": [NSValue valueWithPointer:selector],
        @"original": [NSValue valueWithPointer:(const void *)original], @"replacement": [NSValue valueWithPointer:(const void *)replacement]}];
    if (!class_addMethod(type, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(class_getInstanceMethod(type, selector), replacement);
    traceWrite(@{@"kind": @"hook", @"class": NSStringFromClass(type), @"selector": NSStringFromSelector(selector),
        @"installed": wireBool(method_getImplementation(class_getInstanceMethod(type, selector)) == replacement),
        @"typeEncoding": @(method_getTypeEncoding(method)), @"original": [NSString stringWithFormat:@"%p", (void *)original], @"replacement": [NSString stringWithFormat:@"%p", (void *)replacement]});
    return YES;
    } @finally { [traceLock unlock]; }
}

static void traceFieldHooks(NSResponder *responder) {
    if (![responder isKindOfClass:NSTextView.class]) return;
    Class type = object_getClass(responder);
    traceInstall(type, @selector(keyDown:), (IMP)tracedTextEvent, @encode(void), @[@(@encode(id)), @(@encode(SEL)), @(@encode(id))]);
    traceInstall(type, @selector(selectAll:), (IMP)tracedTextEvent, @encode(void), @[@(@encode(id)), @(@encode(SEL)), @(@encode(id))]);
    traceInstall(type, @selector(doCommandBySelector:), (IMP)tracedCommand, @encode(void), @[@(@encode(id)), @(@encode(SEL)), @(@encode(SEL))]);
    traceInstall(type, @selector(selectedRange), (IMP)tracedRange, @encode(NSRange), @[@(@encode(id)), @(@encode(SEL))]);
}

static void traceAXHooks(id element) {
    if (!element || !NSThread.isMainThread) return;
    Class type = [element class], runtime = object_getClass(element); const char *image = class_getImageName(type);
    if (!image || !sameImage(@(image)) || ![element conformsToProtocol:@protocol(NSAccessibility)]) return;
    NSArray *objectArguments = @[@(@encode(id)), @(@encode(SEL))];
    for (NSString *name in @[@"accessibilityRole", @"accessibilityParent", @"accessibilityFrame", @"isAccessibilityEnabled"])
        if (owns(type, NSSelectorFromString(name)) && implementation(runtime, NSSelectorFromString(name)) != implementation(type, NSSelectorFromString(name))) { traceErrors++; return; }
    for (NSString *name in @[@"accessibilityRole", @"accessibilityParent"])
        if (owns(type, NSSelectorFromString(name))) traceInstall(type, NSSelectorFromString(name), (IMP)tracedAXObject, @encode(id), objectArguments);
    if (owns(type, @selector(accessibilityFrame))) traceInstall(type, @selector(accessibilityFrame), (IMP)tracedAXFrame, @encode(NSRect), objectArguments);
    if (owns(type, @selector(isAccessibilityEnabled))) traceInstall(type, @selector(isAccessibilityEnabled), (IMP)tracedAXEnabled, @encode(BOOL), objectArguments);
}

static void traceWindowHooks(NSWindow *window) {
    if (!traceWindow(window)) return;
    NSMutableArray *pending = [NSMutableArray array]; if (window.contentView) [pending addObject:window.contentView];
    for (NSUInteger count = 0; pending.count && count < 4096; count++) {
        NSView *view = pending.lastObject; [pending removeLastObject];
        Class type = [view class], runtime = object_getClass(view); const char *image = class_getImageName(type);
        if ([view isKindOfClass:NSControl.class] && image && sameImage(@(image)) && owns(type, @selector(accessibilityHitTest:))) {
            if (implementation(runtime, @selector(accessibilityHitTest:)) != implementation(type, @selector(accessibilityHitTest:))) { traceErrors++; continue; }
            traceInstall(type, @selector(accessibilityHitTest:), (IMP)tracedAXHit, @encode(id), @[@(@encode(id)), @(@encode(SEL)), @(@encode(NSPoint))]);
            traceAXHooks(view);
        }
        [pending addObjectsFromArray:view.subviews];
    }
}

static void traceLifecycle(NSString *reason, NSWindow *window) {
    if (traceDepth || atomic_load(&stopping) || !traceEnabled) return;
    @try {
        if (!traceWindow(window)) return;
        traceWindowHooks(window);
        traceDepth++;
        @try { traceWrite(@{@"kind": @"lifecycle", @"reason": reason, @"context": traceContext(window), @"stack": stackTrace()}); }
        @finally { traceDepth--; }
    } @catch (NSException *exception) { traceErrors++; }
}

static CFArrayRef tracedWindows(CGWindowListOption options, CGWindowID relative) {
    traceAdditional(@"CGWindowListCopyWindowInfo");
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = traceCaller();
        if (observe) call = traceBegin(@"CGWindowListCopyWindowInfo", @{@"options": @(options), @"relative": @(relative)}, nil);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    CFArrayRef result = CGWindowListCopyWindowInfo(options, relative);
    if (observe) traceEnd(@"CGWindowListCopyWindowInfo", call, result ? (__bridge NSArray *)result : NSNull.null, nil);
    return result;
}

static void tracedCGPost(CGEventTapLocation tap, CGEventRef event) {
    BOOL observe = NO; NSUInteger call = 0;
    @try {
        observe = traceCaller();
        if (observe) call = traceBegin(@"CGEventPost", @{@"tap": @(tap), @"eventIdentity": [NSString stringWithFormat:@"%p", event],
            @"eventGetterOrigin": @"ADDITIONAL_OBSERVATION_OF_ORIGINAL_ARGUMENT", @"type": @(CGEventGetType(event)),
            @"position": point(CGEventGetLocation(event)), @"timestamp": @(CGEventGetTimestamp(event)),
            @"timestampUnits": @"nanoseconds-since-startup",
            @"tag": @(CGEventGetIntegerValueField(event, kCGEventSourceUserData))}, nil);
    } @catch (NSException *exception) { traceErrors++; observe = NO; }
    CGEventPost(tap, event);
    if (observe) traceEnd(@"CGEventPost", call, NSNull.null, nil);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement, *original; } traceInterpose[] = {
    {(const void *)tracedWindows, (const void *)CGWindowListCopyWindowInfo},
    {(const void *)tracedCGPost, (const void *)CGEventPost}
};

@interface NGVTraceSelftestTextView : NSTextView @end
@implementation NGVTraceSelftestTextView @end

static NSDictionary *traceReadiness(NSWindow *window, NSTextView *text, BOOL accepted) {
    return @{@"queryOrigin": @"SELFTEST_ONLY", @"active": wireBool(NSApp.isActive),
        @"visible": wireBool(window.isVisible), @"key": wireBool(window.isKeyWindow),
        @"keyWindowIdentity": identity(NSApp.keyWindow), @"windowIdentity": identity(window),
        @"responderIdentity": identity(window.firstResponder), @"textIdentity": identity(text),
        @"acceptsFirstResponder": wireBool(text.acceptsFirstResponder), @"makeFirstResponderReturn": wireBool(accepted)};
}

static BOOL traceReady(NSDictionary *value) {
    return [value[@"active"] boolValue] && [value[@"visible"] boolValue] && [value[@"key"] boolValue]
        && [value[@"acceptsFirstResponder"] boolValue] && [value[@"makeFirstResponderReturn"] boolValue]
        && [value[@"keyWindowIdentity"] isEqual:value[@"windowIdentity"]]
        && [value[@"responderIdentity"] isEqual:value[@"textIdentity"]];
}

static void traceSelftest(void) {
    if (!selftestMode || selftestDone || !boundRoot || !NSThread.isMainThread) return;
    selftestDone = YES; selftestRunning = YES;
    NSWindow *previous = NSApp.keyWindow; NSWindow *window = nil, *empty = nil;
    NSMutableDictionary *witness = [@{@"kind": @"selftest", @"complete": @NO, @"queryOrigin": @"SELFTEST_ONLY", @"timeUnits": @"seconds-since-startup"} mutableCopy];
    @try {
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(30, 30, 160, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        NGVTraceSelftestTextView *text = [[NGVTraceSelftestTextView alloc] initWithFrame:NSMakeRect(0, 0, 160, 100)];
        text.string = @"ab"; window.contentView = text; traceFieldHooks(text);
        witness[@"beforeActivation"] = traceReadiness(window, text, NO);
        witness[@"activationRequest"] = @"activate";
        [NSApp activate]; [window makeKeyAndOrderFront:nil];
        BOOL accepted = text.acceptsFirstResponder && [window makeFirstResponder:text];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime, readyLimit = start + 2;
        NSMutableArray *readinessEvents = [NSMutableArray array];
        NSDictionary *ready = traceReadiness(window, text, accepted);
        while (!traceReady(ready) && NSProcessInfo.processInfo.systemUptime < readyLimit && readinessEvents.count < 128) {
            NSTimeInterval requestedAt = NSProcessInfo.processInfo.systemUptime;
            NSDate *expiration = [NSDate dateWithTimeIntervalSinceNow:fmin(0.02, fmax(0, readyLimit - requestedAt))];
            NSEvent *pending = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:expiration inMode:NSDefaultRunLoopMode dequeue:YES];
            [readinessEvents addObject:@{@"event": pending ? traceEvent(pending) : NSNull.null,
                @"requestedAt": @(requestedAt), @"expiration": @(expiration.timeIntervalSince1970), @"mask": @(NSEventMaskAny), @"mode": NSDefaultRunLoopMode, @"dequeue": @YES,
                @"dequeuedAt": @(NSProcessInfo.processInfo.systemUptime), @"dispatched": wireBool(pending != nil)}];
            if (pending) [NSApp sendEvent:pending];
            ready = traceReadiness(window, text, accepted);
        }
        witness[@"readiness"] = ready; witness[@"readinessEvents"] = readinessEvents;
        witness[@"readinessStart"] = @(start); witness[@"readinessDeadline"] = @(readyLimit);
        witness[@"readinessEnd"] = @(NSProcessInfo.processInfo.systemUptime);
        BOOL wasReady = traceReady(ready) && NSProcessInfo.processInfo.systemUptime <= readyLimit; witness[@"ready"] = wireBool(wasReady);
        text.selectedRange = NSMakeRange(0, 1);
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7];
        witness[@"createdEvent"] = traceEvent(event); witness[@"posted"] = wireBool(wasReady);
        NSTimeInterval queueStart = NSProcessInfo.processInfo.systemUptime, queueLimit = queueStart + 2;
        witness[@"queueStart"] = @(queueStart); witness[@"queueDeadline"] = @(queueLimit);
        witness[@"dequeueMask"] = @(NSEventMaskKeyDown); witness[@"dequeueMode"] = NSDefaultRunLoopMode; witness[@"dequeue"] = @YES;
        NSMutableArray *dequeues = [NSMutableArray array]; NSEvent *queued = nil; BOOL dispatchReady = NO;
        if (wasReady) {
            witness[@"postedEvent"] = traceEvent(event);
            [NSApp postEvent:event atStart:YES];
            while (NSProcessInfo.processInfo.systemUptime < queueLimit && dequeues.count < 128) {
                NSTimeInterval requestedAt = NSProcessInfo.processInfo.systemUptime;
                NSDate *expiration = [NSDate dateWithTimeIntervalSinceNow:fmax(0, queueLimit - requestedAt)];
                NSEvent *candidate = [NSApp nextEventMatchingMask:NSEventMaskKeyDown untilDate:expiration inMode:NSDefaultRunLoopMode dequeue:YES];
                NSTimeInterval dequeuedAt = NSProcessInfo.processInfo.systemUptime;
                NSDictionary *dispatchState = traceReadiness(window, text, accepted);
                [dequeues addObject:@{@"event": candidate ? traceEvent(candidate) : NSNull.null,
                    @"requestedAt": @(requestedAt), @"dequeuedAt": @(dequeuedAt), @"readiness": dispatchState, @"expiration": @(expiration.timeIntervalSince1970),
                    @"sameIdentity": wireBool(candidate == event), @"dispatched": wireBool(candidate != nil)}];
                if (candidate) [NSApp sendEvent:candidate];
                if (!candidate || candidate == event) { queued = candidate; dispatchReady = traceReady(dispatchState) && dequeuedAt <= queueLimit; break; }
            }
        }
        witness[@"dequeues"] = dequeues; witness[@"queueEnd"] = @(NSProcessInfo.processInfo.systemUptime);
        witness[@"queueIdentityUnchanged"] = wireBool(queued == event);
        witness[@"queueResult"] = queued == event ? @"IDENTICAL_EVENT" : (!wasReady ? @"READINESS_REFUSED" :
            (dequeues.count && dequeues.lastObject[@"event"] == NSNull.null ? @"DEQUEUE_NIL" :
            (dequeues.count >= 128 ? @"DEQUEUE_LIMIT" : @"DEADLINE_EXPIRED")));
        NSString *inserted = [text.string copy]; NSRange after = text.selectedRange;
        BOOL action = [NSApp sendAction:@selector(selectAll:) to:text from:nil]; NSRange selected = text.selectedRange;
        text.selectedRange = NSMakeRange(0, 1); [text doCommandBySelector:@selector(selectAll:)]; NSRange commanded = text.selectedRange;
        NSEvent *equivalent = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
        empty = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 40, 40) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        empty.releasedWhenClosed = NO; empty.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)];
        BOOL windowEquivalent = [empty performKeyEquivalent:equivalent];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Trace witness"];
        NSMenuItem *item = [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        item.target = text; item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        text.selectedRange = NSMakeRange(0, 1);
        BOOL menuEquivalent = [menu performKeyEquivalent:equivalent]; NSRange menuSelection = text.selectedRange;
        [witness addEntriesFromDictionary:@{@"inserted": inserted, @"selectionAfterKey": @[@(after.location), @(after.length)],
            @"actionReturn": wireBool(action), @"selectionAfterAction": @[@(selected.location), @(selected.length)],
            @"selectionAfterCommand": @[@(commanded.location), @(commanded.length)],
            @"expectedInserted": @"xb", @"expectedSelectionAfterKey": @[@1, @0], @"expectedSelectionAfterAction": @[@0, @2],
            @"windowEquivalentReturn": wireBool(windowEquivalent), @"menuEquivalentReturn": wireBool(menuEquivalent),
            @"selectionAfterMenu": @[@(menuSelection.location), @(menuSelection.length)],
            @"complete": wireBool(wasReady && dispatchReady && queued == event && [inserted isEqual:@"xb"] && after.location == 1 && after.length == 0
                && action && selected.location == 0 && selected.length == 2 && commanded.location == 0 && commanded.length == 2
                && !windowEquivalent && menuEquivalent && menuSelection.location == 0 && menuSelection.length == 2)}];
    } @catch (NSException *exception) { traceErrors++; witness[@"exception"] = exception.name; }
    @finally {
        @try { [empty close]; [window close]; [previous makeKeyWindow]; witness[@"cleanupComplete"] = @YES; }
        @catch (NSException *exception) { traceErrors++; witness[@"cleanupComplete"] = @NO; witness[@"cleanupException"] = exception.name; }
        traceWrite(witness); selftestRunning = NO;
    }
}

static void traceInitialize(NSDictionary *environment, NSString *folder) {
    expectedHost = environment[@"NGV_POINTER_TRACE_EXPECTED_HOST"];
    if (![environment[@"NGV_POINTER_EVENT_TRACE"] isEqual:@"1"]) return;
    NSString *actualHost = NSProcessInfo.processInfo.arguments.firstObject;
    if (!expectedHost.isAbsolutePath || !fileIdentity(actualHost).count || ![fileIdentity(actualHost) isEqual:fileIdentity(expectedHost)]) return;
    traceLock = [NSRecursiveLock new]; traceCalls = [NSMutableDictionary new]; traceReturns = [NSMutableDictionary new]; traceAdditionalQueries = [NSMutableDictionary new]; traceHooks = [NSMutableArray new];
    traceFD = open([[folder stringByAppendingPathComponent:@"event-trace.jsonl"] fileSystemRepresentation], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (traceFD < 0) { outputErrors++; return; }
    traceEnabled = YES; selftestMode = [environment[@"NGV_POINTER_TRACE_SELFTEST"] isEqual:@"1"];
    traceWrite(@{@"kind": @"loaded", @"expectedImageIdentity": fileIdentity(expectedImage), @"expectedHostIdentity": fileIdentity(expectedHost), @"actualHostIdentity": fileIdentity(actualHost), @"selftestMode": wireBool(selftestMode)});
    NSArray *objectEvent = @[@(@encode(id)), @(@encode(SEL)), @(@encode(id))];
    Class applicationClass = objc_getClass("NSApplication"), windowClass = objc_getClass("NSWindow");
    traceInstall(applicationClass, @selector(postEvent:atStart:), (IMP)tracedPost, @encode(void), @[@(@encode(id)), @(@encode(SEL)), @(@encode(id)), @(@encode(BOOL))]);
    traceInstall(applicationClass, @selector(sendEvent:), (IMP)tracedSend, @encode(void), objectEvent);
    traceInstall(applicationClass, @selector(sendAction:to:from:), (IMP)tracedAction, @encode(BOOL), @[@(@encode(id)), @(@encode(SEL)), @(@encode(SEL)), @(@encode(id)), @(@encode(id))]);
    traceInstall(windowClass, @selector(performKeyEquivalent:), (IMP)tracedEquivalent, @encode(BOOL), objectEvent);
    traceInstall(objc_getClass("NSMenu"), @selector(performKeyEquivalent:), (IMP)tracedEquivalent, @encode(BOOL), objectEvent);
    traceInstall(object_getClass(windowClass), @selector(windowNumberAtPoint:belowWindowWithWindowNumber:), (IMP)tracedWindowAt, @encode(NSInteger), @[@(@encode(id)), @(@encode(SEL)), @(@encode(NSPoint)), @(@encode(NSInteger))]);
    traceInstall(windowClass, @selector(windowNumber), (IMP)tracedWindowNumber, @encode(NSInteger), @[@(@encode(id)), @(@encode(SEL))]);
    dispatch_async(dispatch_get_main_queue(), ^{
        traceMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
            if (!traceDepth && !atomic_load(&stopping) && traceWindow(event.window)) {
                traceDepth++;
                @try { traceWrite(@{@"kind": @"receive", @"event": traceEvent(event), @"context": traceContext(event.window), @"stack": stackTrace()}); }
                @catch (NSException *exception) { traceErrors++; }
                @finally { traceDepth--; }
            }
            return event;
        }];
    });
}

static void traceFinish(void) {
    if (!traceEnabled) return;
    if (traceMonitor) [NSEvent removeMonitor:traceMonitor];
    traceWrite(@{@"kind": @"finished", @"calls": traceCalls, @"returns": traceReturns, @"additionalGetterQueryCounts": traceAdditionalQueries,
        @"contextCount": @(traceContextSequence), @"errors": @(traceErrors), @"selftestMode": wireBool(selftestMode), @"selftestCompleted": wireBool(selftestDone)});
    for (NSDictionary *entry in traceHooks.reverseObjectEnumerator) {
        Class type = (__bridge Class)[entry[@"class"] pointerValue]; SEL selector = [entry[@"selector"] pointerValue];
        Method method = class_getInstanceMethod(type, selector);
        if (method_getImplementation(method) == (IMP)[entry[@"replacement"] pointerValue]) method_setImplementation(method, (IMP)[entry[@"original"] pointerValue]);
    }
    if (close(traceFD) != 0 || traceErrors) { const char *message = "NGV_POINTER_INSPECTOR_FINALIZATION_FAILED\n"; write(STDERR_FILENO, message, strlen(message)); }
    traceFD = -1; traceEnabled = NO;
}
