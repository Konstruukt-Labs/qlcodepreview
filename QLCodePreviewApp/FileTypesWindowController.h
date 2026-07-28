//
//  FileTypesWindowController.h
//  QLCodePreview (host app)
//
//  A small window that lets the user map a file extension to one of
//  QLCCHighlighter's built-in languages. Saves to the same shared
//  preference domain QLCCConfiguration reads from, so the change is picked
//  up by the (already-installed, already-signed) extension immediately
//  no rebuild or re-registration needed.
//
//  This intentionally does NOT let the user register a brand-new file
//  extension that Quick Look doesn't already hand to the extension at all
//  (that requires a UTI declaration + re-signing + re-registration see
//  build.sh). It only changes which language an already-previewed file is
//  highlighted as.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCFileTypesWindowController : NSWindowController

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
