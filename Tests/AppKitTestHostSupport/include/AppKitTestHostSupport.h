#ifndef NGV_APPKIT_TEST_HOST_SUPPORT_H
#define NGV_APPKIT_TEST_HOST_SUPPORT_H

#import <AppKit/AppKit.h>

NSApplication * _Nullable NGVCreateTestApplication(const char * _Nonnull evidencePath,
                                                 const char * _Nonnull sourceSHA);
BOOL NGVScheduleHostExceptionProbe(NSApplication * _Nonnull application);

#endif
