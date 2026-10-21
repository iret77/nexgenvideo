#import "AppKitTestHostSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int exceptionFD = -1;
static NSString *testSourceSHA;
static atomic_flag reporting = ATOMIC_FLAG_INIT;

static BOOL writeAll(int fd, const void *bytes, size_t count) {
    const unsigned char *cursor = bytes;
    while (count) {
        ssize_t written = write(fd, cursor, count);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        count -= (size_t)written;
    }
    return YES;
}

static void diagnosticFailure(void) {
    static const char message[] = "AppKit exception diagnostic unavailable or incomplete\n";
    writeAll(STDERR_FILENO, message, sizeof(message) - 1);
}

@interface NGVTestRuntimeApplication : NSApplication
- (void)ngv_raiseProbeException __attribute__((disable_tail_calls));
@end

@implementation NGVTestRuntimeApplication
- (void)reportException:(NSException *)exception {
    if (atomic_flag_test_and_set(&reporting)) {
        diagnosticFailure();
        _Exit(EXIT_FAILURE);
    }
    @try {
        NSDictionary *record = @{
            @"schema": @1, @"event": @"appkit-exception",
            @"pid": @(getpid()), @"parentPID": @(getppid()),
            @"sourceSHA": testSourceSHA ?: @"",
            @"timestamp": @([NSDate date].timeIntervalSince1970),
            @"name": exception.name, @"reason": exception.reason ?: [NSNull null],
            @"throwStackSymbols": exception.callStackSymbols,
            @"throwStackReturnAddresses": exception.callStackReturnAddresses,
            @"reportStackSymbols": [NSThread callStackSymbols]
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
        if (!data || !writeAll(exceptionFD, data.bytes, data.length)
            || !writeAll(exceptionFD, "\n", 1) || fsync(exceptionFD) != 0) diagnosticFailure();
    } @catch (NSException *diagnosticException) {
        diagnosticFailure();
    }
    [super reportException:exception];
    _Exit(EXIT_FAILURE);
}

- (void)ngv_raiseProbeException {
    [NSException raise:@"NGVHostDiagnosticProbe" format:@"Native AppKit exception capture probe"];
}
@end

NSApplication *NGVCreateTestApplication(const char *evidencePath, const char *sourceSHA) {
    if (![NSThread isMainThread] || NSApp != nil || exceptionFD != -1 || evidencePath[0] != '/') return nil;
    NSString *source = [[NSString alloc] initWithUTF8String:sourceSHA];
    if (!source) return nil;
    int fd = open(evidencePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return nil;
    struct stat identity;
    if (fstat(fd, &identity) != 0 || !S_ISREG(identity.st_mode)) {
        close(fd);
        return nil;
    }
    exceptionFD = fd;
    testSourceSHA = source;
    NSApplication *application = [NGVTestRuntimeApplication sharedApplication];
    if (application.class != NGVTestRuntimeApplication.class) {
        close(exceptionFD);
        exceptionFD = -1;
        return nil;
    }
    return application;
}

BOOL NGVScheduleHostExceptionProbe(NSApplication *application) {
    if (![NSThread isMainThread] || application.class != NGVTestRuntimeApplication.class) return NO;
    [application performSelector:@selector(ngv_raiseProbeException) withObject:nil afterDelay:0];
    return YES;
}
