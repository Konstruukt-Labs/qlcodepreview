//
//  QLCCLogging.h
//  QLCodePreview
//
//  Lightweight debug logging. Enable by building the DEBUG configuration
//  (the Makefile / build.sh pass -DDEBUG=1), then watch Console for lines
//  prefixed with "[QLCodePreview]".
//

#ifndef QLCCLogging_h
#define QLCCLogging_h

#import <Foundation/Foundation.h>

#ifdef DEBUG
#define QLCCLog(fmt, ...) \
    NSLog(@"[QLCodePreview] " fmt, ##__VA_ARGS__)
#else
#define QLCCLog(fmt, ...) ((void)0)
#endif

#endif /* QLCCLogging_h */
