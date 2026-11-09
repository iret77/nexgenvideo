#import <AppKit/AppKit.h>
#import <XCTest/XCTest.h>
#import "AppKitTestHostSupport.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

static NSSet<NSString *> *runtimeKinds;
static NSString *runtimeRoot;

static NSArray<NSString *> *RuntimeImages(void) {
    NSMutableArray *images = [NSMutableArray array];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        NSString *path = @(_dyld_get_image_name(index)).stringByResolvingSymlinksInPath;
        if ([runtimeKinds containsObject:path.lastPathComponent] || [path hasPrefix:[runtimeRoot stringByAppendingString:@"/"]])
            [images addObject:path];
    }
    return [images sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL RuntimeIdentity(NSArray *before, NSArray *after, NSString *frameworks) {
    NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
    for (NSString *path in after) {
        NSString *kind = path.lastPathComponent;
        if (kinds[kind] || ![path hasPrefix:[frameworks stringByAppendingString:@"/"]]) return NO;
        kinds[kind] = path;
    }
    return after.count > 0 && [[NSSet setWithArray:before] isSubsetOfSet:[NSSet setWithArray:after]];
}

static BOOL WriteReceipt(NSString *path, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (!data) return NO;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    const unsigned char *cursor = data.bytes;
    NSUInteger remaining = data.length;
    BOOL ok = YES;
    while (remaining) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        cursor += count; remaining -= (NSUInteger)count;
    }
    if (fsync(fd)) ok = NO;
    if (close(fd)) ok = NO;
    return ok;
}

static NSDictionary *CaseObservation(XCTest *test, NSString *expectedImage) {
    Class type = object_getClass(test);
    NSString *className = NSStringFromClass(type) ?: @"";
    const char *raw = class_getImageName(type);
    NSString *image = raw ? @(raw).stringByResolvingSymlinksInPath : @"";
    NSMutableDictionary *observation = [@{@"class": className, @"image": image,
        @"reportedName": NSNull.null, @"invocationPresent": NSNull.null, @"invocationSelector": NSNull.null,
        @"respondsToInvocationSelector": NSNull.null, @"observationError": NSNull.null,
        @"identity": NSNull.null, @"rejectionReason": NSNull.null} mutableCopy];
    @try {
        observation[@"reportedName"] = test.name ?: NSNull.null;
        if (![test isKindOfClass:XCTestCase.class]) {
            observation[@"rejectionReason"] = @"Unsupported XCTest leaf type";
            return observation;
        }
        // Invocation is optional and does not define XCTest's public case name.
        NSInvocation *invocation = ((XCTestCase *)test).invocation;
        SEL selector = invocation.selector;
        observation[@"invocationPresent"] = invocation ? @YES : @NO;
        if (selector) {
            observation[@"invocationSelector"] = NSStringFromSelector(selector);
            observation[@"respondsToInvocationSelector"] = [test respondsToSelector:selector] ? @YES : @NO;
        }
    } @catch (NSException *exception) {
        observation[@"observationError"] = exception.description;
        observation[@"rejectionReason"] = @"XCTest public observation failed";
        return observation;
    }
    NSString *reported = [observation[@"reportedName"] isKindOfClass:NSString.class] ? observation[@"reportedName"] : nil;
    NSRange separator = reported ? [reported rangeOfString:@" "] : NSMakeRange(NSNotFound, 0);
    if (!className.length || !reported || ![reported hasPrefix:@"-["] || ![reported hasSuffix:@"]"] ||
        separator.location == NSNotFound || separator.location <= 2 || separator.location >= reported.length - 1) {
        observation[@"rejectionReason"] = @"XCTest public name is malformed";
        return observation;
    }
    NSString *reportedClass = [reported substringWithRange:NSMakeRange(2, separator.location - 2)];
    NSString *method = [reported substringWithRange:NSMakeRange(separator.location + 1, reported.length - separator.location - 2)];
    NSMutableCharacterSet *invalid = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [invalid addCharactersInString:@"[]"];
    if (![reportedClass isEqual:className] && ![reportedClass isEqual:[className componentsSeparatedByString:@"."].lastObject]) {
        observation[@"rejectionReason"] = @"XCTest reported class differs from the actual runtime class";
    } else if (!method.length || [method rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        observation[@"rejectionReason"] = @"XCTest public method name is malformed";
    } else if (![image isEqual:expectedImage]) {
        observation[@"rejectionReason"] = @"XCTest class image differs from the selected test image";
    } else {
        observation[@"identity"] = @{@"name": [NSString stringWithFormat:@"-[%@ %@]", className, method],
            @"reportedName": reported, @"class": className, @"method": method, @"image": image};
    }
    return observation;
}

static BOOL CollectLeaves(XCTest *test, NSString *image, NSMutableArray *leaves, NSMutableArray *classes, NSMutableArray *observations) {
    if ([test isKindOfClass:XCTestCase.class]) {
        NSDictionary *observation = CaseObservation((XCTestCase *)test, image);
        [observations addObject:observation];
        if (observation[@"rejectionReason"] != NSNull.null) return NO;
        NSDictionary *identity = observation[@"identity"];
        [leaves addObject:identity[@"name"]];
        [classes addObject:identity];
        return YES;
    }
    if (![test isKindOfClass:XCTestSuite.class]) {
        [observations addObject:CaseObservation(test, image)];
        return NO;
    }
    BOOL ok = YES;
    for (XCTest *child in ((XCTestSuite *)test).tests) if (!CollectLeaves(child, image, leaves, classes, observations)) ok = NO;
    return ok;
}

static NSDictionary *IssueDetail(XCTIssue *issue) {
    NSMutableArray *addresses = [NSMutableArray array];
    for (XCTSourceCodeFrame *frame in issue.sourceCodeContext.callStack) [addresses addObject:@(frame.address)];
    XCTSourceCodeLocation *location = issue.sourceCodeContext.location;
    NSError *error = issue.associatedError;
    return @{@"type": @(issue.type), @"severity": @(issue.severity), @"isFailure": @(issue.isFailure),
        @"compactDescription": issue.compactDescription ?: @"", @"detailedDescription": issue.detailedDescription ?: NSNull.null,
        @"file": location.fileURL.path ?: NSNull.null, @"line": location ? @(location.lineNumber) : NSNull.null,
        @"rawStackAddresses": addresses, @"attachmentCount": @(issue.attachments.count),
        @"errorDomain": error.domain ?: NSNull.null, @"errorCode": error ? @(error.code) : NSNull.null,
        @"errorDescription": error.localizedDescription ?: NSNull.null};
}

@interface NativeXCTestObserver : NSObject <XCTestObservation>
@property(nonatomic, strong) XCTestSuite *root;
@property(nonatomic, copy) NSString *caseImage;
@property(nonatomic, strong) NSMutableArray<NSString *> *started;
@property(nonatomic, strong) NSMutableArray<NSString *> *ended;
@property(nonatomic, strong) NSMutableArray<NSString *> *passed;
@property(nonatomic, strong) NSMutableArray<NSString *> *failed;
@property(nonatomic) NSUInteger rootStarted;
@property(nonatomic) NSUInteger rootCompleted;
@property(nonatomic) NSUInteger bundleStarted;
@property(nonatomic) NSUInteger bundleCompleted;
@property(nonatomic) NSUInteger eventCount;
@property(nonatomic) NSUInteger prematureExecutionCount;
@property(nonatomic) NSUInteger issueCount;
@property(nonatomic) NSUInteger expectedFailureCount;
@property(nonatomic) BOOL executing;
@property(nonatomic) FILE *events;
@property(nonatomic, copy) NSString *recordingError;
- (void)record:(NSString *)kind name:(NSString *)name run:(XCTestRun *)run detail:(NSDictionary *)detail;
- (void)recordCase:(NSString *)kind observation:(NSDictionary *)observation run:(XCTestRun *)run detail:(NSDictionary *)detail;
@end

@implementation NativeXCTestObserver
- (instancetype)init {
    self = [super init];
    if (self) {
        _started = [NSMutableArray array]; _ended = [NSMutableArray array];
        _passed = [NSMutableArray array]; _failed = [NSMutableArray array];
    }
    return self;
}
- (void)record:(NSString *)kind name:(NSString *)name run:(XCTestRun *)run detail:(NSDictionary *)detail {
    @synchronized(self) {
        if (!self.executing) self.prematureExecutionCount++;
        NSDictionary *record = @{
            @"schema": @"native-xctest-observation/v1", @"kind": kind, @"name": name ?: @"",
            @"pid": @(getpid()), @"executing": @(self.executing), @"root": @([name isEqual:self.root.name]),
            @"detail": detail ?: @{},
            @"run": run ? @{@"executionCount": @(run.executionCount), @"skipCount": @(run.skipCount),
                @"totalFailureCount": @(run.totalFailureCount), @"hasSucceeded": @(run.hasSucceeded)} : NSNull.null
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
        if (!data || fwrite(data.bytes, 1, data.length, self.events) != data.length ||
            fputc('\n', self.events) == EOF || fflush(self.events) || fsync(fileno(self.events))) {
            self.recordingError = @"XCTest observation output was incomplete";
        } else { self.eventCount++; }
    }
}
- (void)testSuiteWillStart:(XCTestSuite *)suite {
    @synchronized(self) { if (suite == self.root) self.rootStarted++; }
    [self record:@"testSuiteWillStart" name:suite.name run:nil detail:nil];
}
- (void)testSuiteDidFinish:(XCTestSuite *)suite {
    @synchronized(self) { if (suite == self.root) self.rootCompleted++; }
    [self record:@"testSuiteDidFinish" name:suite.name run:suite.testRun detail:nil];
}
- (void)testCaseWillStart:(XCTestCase *)test {
    NSDictionary *observation = CaseObservation(test, self.caseImage);
    NSDictionary *identity = [observation[@"identity"] isKindOfClass:NSDictionary.class] ? observation[@"identity"] : nil;
    @synchronized(self) { [self.started addObject:identity[@"name"] ?: @""]; }
    [self recordCase:@"testCaseWillStart" observation:observation run:nil detail:nil];
}
- (void)testCaseDidFinish:(XCTestCase *)test {
    NSDictionary *observation = CaseObservation(test, self.caseImage);
    NSDictionary *identity = [observation[@"identity"] isKindOfClass:NSDictionary.class] ? observation[@"identity"] : nil;
    @synchronized(self) {
        [self.ended addObject:identity[@"name"] ?: @""];
        XCTestRun *run = test.testRun;
        BOOL ok = run && run.hasSucceeded && run.executionCount == 1 && run.skipCount == 0 && run.totalFailureCount == 0;
        [(ok ? self.passed : self.failed) addObject:identity[@"name"] ?: @""];
    }
    [self recordCase:@"testCaseDidFinish" observation:observation run:test.testRun detail:nil];
}
- (void)recordCase:(NSString *)kind observation:(NSDictionary *)observation run:(XCTestRun *)run detail:(NSDictionary *)detail {
    NSDictionary *identity = [observation[@"identity"] isKindOfClass:NSDictionary.class] ? observation[@"identity"] : nil;
    if (!identity || observation[@"rejectionReason"] != NSNull.null) self.recordingError = @"XCTest case identity was unavailable";
    NSMutableDictionary *value = [NSMutableDictionary dictionaryWithDictionary:detail ?: @{}];
    value[@"caseIdentity"] = identity ?: @{};
    value[@"caseObservation"] = observation;
    [self record:kind name:identity[@"name"] ?: @"" run:run detail:value];
}
- (void)testBundleWillStart:(NSBundle *)bundle {
    @synchronized(self) { self.bundleStarted++; }
    [self record:@"testBundleWillStart" name:bundle.bundlePath run:nil detail:nil];
}
- (void)testBundleDidFinish:(NSBundle *)bundle {
    @synchronized(self) { self.bundleCompleted++; }
    [self record:@"testBundleDidFinish" name:bundle.bundlePath run:nil detail:nil];
}
- (void)issue:(XCTIssue *)issue kind:(NSString *)kind name:(NSString *)name {
    @synchronized(self) { self.issueCount++; }
    [self record:kind name:name run:nil detail:IssueDetail(issue)];
}
- (void)testCase:(XCTestCase *)test didRecordIssue:(XCTIssue *)issue {
    @synchronized(self) { self.issueCount++; }
    [self recordCase:@"testCaseIssue" observation:CaseObservation(test, self.caseImage) run:nil detail:IssueDetail(issue)];
}
- (void)testSuite:(XCTestSuite *)test didRecordIssue:(XCTIssue *)issue {
    [self issue:issue kind:@"testSuiteIssue" name:test.name];
}
- (void)testCase:(XCTestCase *)test didRecordExpectedFailure:(XCTExpectedFailure *)failure {
    @synchronized(self) { self.expectedFailureCount++; }
    [self recordCase:@"testCaseExpectedFailure" observation:CaseObservation(test, self.caseImage) run:nil detail:@{@"failureReason": failure.failureReason ?: NSNull.null, @"issue": IssueDetail(failure.issue)}];
}
- (void)testSuite:(XCTestSuite *)test didRecordExpectedFailure:(XCTExpectedFailure *)failure {
    @synchronized(self) { self.expectedFailureCount++; }
    [self record:@"testSuiteExpectedFailure" name:test.name run:nil detail:@{@"failureReason": failure.failureReason ?: NSNull.null, @"issue": IssueDetail(failure.issue)}];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6) return 64;
        NSString *bundlePath = @(argv[1]).stringByResolvingSymlinksInPath;
        runtimeRoot = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"].stringByResolvingSymlinksInPath;
        NSMutableSet *kinds = [NSMutableSet set];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:runtimeRoot error:NULL]) {
            if ([name.pathExtension isEqual:@"framework"]) [kinds addObject:name.stringByDeletingPathExtension];
            else if ([name.pathExtension isEqual:@"dylib"]) [kinds addObject:name];
        }
        runtimeKinds = kinds;
        NSString *receiptPath = @(argv[3]);
        NSString *eventsPath = @(argv[4]);
        NSString *source = NSProcessInfo.processInfo.environment[@"GITHUB_SHA"] ?: @"";
        NSMutableDictionary *receipt = [@{@"schema": @"native-xctest-host/v1", @"sourceSHA": source,
            @"pid": @(getpid()), @"parentPID": @(getppid()), @"bundlePath": bundlePath, @"passed": @NO,
            @"boundary": @"inputs", @"runtimeKinds": [[runtimeKinds allObjects] sortedArrayUsingSelector:@selector(compare:)],
            @"runtimeImagesBefore": RuntimeImages()} mutableCopy];
        int descriptor = -1;
        __block NativeXCTestObserver *observer = nil;
        __block BOOL registered = NO;
        __block NSMutableArray *leaves = [NSMutableArray array];
        __block NSMutableArray *classes = [NSMutableArray array];
        __block NSMutableArray *observations = [NSMutableArray array];
        void (^finish)(NSString *, NSString *, BOOL) = ^(NSString *boundary, NSString *message, BOOL success) {
            if (registered) [XCTestObservationCenter.sharedTestObservationCenter removeTestObserver:observer];
            if (observer.events) {
                int flushed = fflush(observer.events), synced = fsync(fileno(observer.events)), closed = fclose(observer.events);
                observer.events = NULL;
                if (flushed || synced || closed) observer.recordingError = @"XCTest observations were not fully persisted";
            }
            receipt[@"boundary"] = boundary; receipt[@"error"] = message ?: NSNull.null;
            receipt[@"runtimeImagesAfter"] = RuntimeImages(); receipt[@"inventoryIDs"] = leaves;
            receipt[@"leafClasses"] = classes; receipt[@"caseObservations"] = observations; receipt[@"eventCount"] = @(observer.eventCount);
            receipt[@"startedIDs"] = observer.started ?: @[]; receipt[@"endedIDs"] = observer.ended ?: @[];
            receipt[@"passedIDs"] = observer.passed ?: @[]; receipt[@"failedIDs"] = observer.failed ?: @[];
            receipt[@"rootSuiteStarted"] = @(observer.rootStarted); receipt[@"rootSuiteCompleted"] = @(observer.rootCompleted);
            receipt[@"actualBundleStartedCallbacks"] = @(observer.bundleStarted);
            receipt[@"actualBundleCompletedCallbacks"] = @(observer.bundleCompleted);
            receipt[@"prematureExecutionCount"] = @(observer.prematureExecutionCount); receipt[@"issueCount"] = @(observer.issueCount);
            receipt[@"expectedFailureCount"] = @(observer.expectedFailureCount);
            receipt[@"recordingError"] = observer.recordingError ?: NSNull.null;
            receipt[@"passed"] = success && !observer.recordingError ? @YES : @NO;
            BOOL written = WriteReceipt(receiptPath, receipt);
            if (!written) fprintf(stderr, "Native XCTest receipt could not be persisted\n");
            exit(success && !observer.recordingError && written ? 0 : 1);
        };
        @try {
            char executable[PATH_MAX]; uint32_t size = sizeof(executable);
            if (_NSGetExecutablePath(executable, &size)) finish(@"host-identity", @"Host path unavailable", NO);
            receipt[@"hostPath"] = @((const char *)executable).stringByResolvingSymlinksInPath;
            receipt[@"loadedHostImage"] = @(_dyld_get_image_name(0)).stringByResolvingSymlinksInPath;
            NSData *input = [NSData dataWithContentsOfFile:@(argv[2])];
            id expected = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL] : nil;
            if (![expected isKindOfClass:NSArray.class] || ![expected count]) finish(@"inputs", @"Missing expected XCTest IDs", NO);
            for (id name in expected) if (![name isKindOfClass:NSString.class] || ![name length]) finish(@"inputs", @"Invalid expected XCTest ID", NO);
            NSArray *expectedNames = [expected sortedArrayUsingSelector:@selector(compare:)];
            if ([NSSet setWithArray:expectedNames].count != expectedNames.count || ![bundlePath.pathExtension isEqual:@"xctest"])
                finish(@"inputs", @"Duplicate IDs or invalid bundle", NO);
            descriptor = open(eventsPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (descriptor < 0) finish(@"events-open", @"Observation file unavailable", NO);
            observer = [NativeXCTestObserver new]; observer.events = fdopen(descriptor, "w");
            if (!observer.events) { close(descriptor); finish(@"events-open", @"Observation stream unavailable", NO); }
            [XCTestObservationCenter.sharedTestObservationCenter addTestObserver:observer]; registered = YES;
            NSApplication *application = NGVCreateTestApplication(argv[5], source.UTF8String);
            if (!application) finish(@"application-create", @"Fail-closed AppKit host unavailable", NO);
            [application setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSBundle *bundle = [NSBundle bundleWithPath:bundlePath]; NSError *loadError = nil;
            if (!bundle || ![bundle loadAndReturnError:&loadError]) finish(@"bundle-load", loadError.localizedDescription ?: @"Test bundle could not load", NO);
            NSArray *afterLoad = RuntimeImages(); receipt[@"runtimeImagesAfterLoad"] = afterLoad;
            const char *rawClassImage = class_getImageName(XCTestCase.class);
            NSString *classImage = rawClassImage ? @(rawClassImage).stringByResolvingSymlinksInPath : @"";
            receipt[@"caseRuntimeImage"] = classImage;
            NSString *frameworks = [bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"].stringByResolvingSymlinksInPath;
            if (!RuntimeIdentity(receipt[@"runtimeImagesBefore"], afterLoad, frameworks) || ![afterLoad containsObject:classImage])
                finish(@"runtime-identity", @"XCTest runtime identity differs", NO);
            XCTestSuite *suite = [XCTestSuite testSuiteForBundlePath:bundlePath]; observer.root = suite;
            NSString *bundleImage = bundle.executableURL.path.stringByResolvingSymlinksInPath;
            receipt[@"bundleImagePath"] = bundleImage ?: @"";
            observer.caseImage = bundleImage;
            receipt[@"discoveredTestCaseCount"] = @(suite.testCaseCount);
            if (!suite || !CollectLeaves(suite, bundleImage, leaves, classes, observations) ||
                ![[leaves sortedArrayUsingSelector:@selector(compare:)] isEqual:expectedNames] ||
                [NSSet setWithArray:leaves].count != leaves.count || suite.testCaseCount != expectedNames.count || observer.prematureExecutionCount)
                finish(@"discovery", @"Exact XCTest inventory or class provenance differs", NO);
            receipt[@"suiteName"] = suite.name;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    receipt[@"mainThread"] = @(NSThread.isMainThread); receipt[@"applicationRunningAtStart"] = @(application.isRunning);
                    observer.executing = YES;
                    [suite runTest];
                    observer.executing = NO;
                    XCTestRun *run = suite.testRun;
                    receipt[@"executionCount"] = @(run.executionCount); receipt[@"skipCount"] = @(run.skipCount);
                    receipt[@"totalFailureCount"] = @(run.totalFailureCount); receipt[@"hasSucceeded"] = @(run.hasSucceeded);
                    BOOL ok = NSThread.isMainThread && application.isRunning && observer.rootStarted == 1 && observer.rootCompleted == 1 &&
                        !observer.prematureExecutionCount && !observer.issueCount && !observer.expectedFailureCount && !observer.failed.count &&
                        [[observer.started sortedArrayUsingSelector:@selector(compare:)] isEqual:expectedNames] &&
                        [[observer.ended sortedArrayUsingSelector:@selector(compare:)] isEqual:expectedNames] &&
                        [[observer.passed sortedArrayUsingSelector:@selector(compare:)] isEqual:expectedNames] &&
                        run && run.hasSucceeded && run.executionCount == expectedNames.count && run.skipCount == 0 && run.totalFailureCount == 0 &&
                        [afterLoad isEqual:RuntimeImages()];
                    finish(@"suite-returned", ok ? nil : @"XCTest execution did not qualify", ok);
                } @catch (NSException *exception) { finish(@"suite-exception", exception.description, NO); }
            });
            [application run];
            finish(@"runloop-returned", @"AppKit run loop returned before qualification", NO);
        } @catch (NSException *exception) { finish(@"host-exception", exception.description, NO); }
        return 70;
    }
}
