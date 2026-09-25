#ifndef AE_EXCEPTION_CATCHER_H
#define AE_EXCEPTION_CATCHER_H

#import <Foundation/Foundation.h>

// Returns YES if block executed without throwing, NO if an ObjC exception was caught
BOOL AERunWithExceptionHandler(void (^block)(void));

#endif
