//
//  FileTypesViewController.h
//  QLCodePreview (host app)
//
//  The "Custom File Types" pane of the main window: lets the user map a
//  file extension to one of QLCCHighlighter's built-in languages. Saves
//  to the same shared preference domain QLCCConfiguration reads from, so
//  the change is picked up by the (already-installed, already-signed)
//  extension immediately — no rebuild or re-registration needed.
//
//  This intentionally does NOT let the user register a brand-new file
//  extension that Quick Look doesn't already hand to the extension at all
//  (that requires a UTI declaration + re-signing + re-registration — see
//  build.sh). It only changes which language an already-previewed file is
//  highlighted as.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCFileTypesViewController : NSViewController

/// Builds the pane with fixed-frame layout for the given size.
- (instancetype)initWithSize:(NSSize)size;

/// Writes the current mappings to the shared defaults and returns a short
/// status fragment for the main window's status line.
- (NSString *)save;

@end

NS_ASSUME_NONNULL_END
