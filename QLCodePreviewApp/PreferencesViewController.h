//
//  PreferencesViewController.h
//  QLCodePreview (host app)
//
//  The "Preview Settings" pane of the main window: font, font size,
//  light/dark themes, line numbers (and gutter gap), line wrap, tab
//  width, and max file size. Saves straight to the shared App-Group
//  preferences domain QLCCConfiguration reads, so changes take effect on
//  the next preview without a rebuild.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCPreferencesViewController : NSViewController

/// Builds the pane with fixed-frame layout for the given size.
- (instancetype)initWithSize:(NSSize)size;

/// Writes the current values to the shared defaults and returns a short
/// status fragment for the main window's status line.
- (NSString *)save;

@end

NS_ASSUME_NONNULL_END
