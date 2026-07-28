//
//  PreferencesWindowController.h
//  QLCodePreview (host app)
//
//  Lets the user change rendering preferences (theme, font, line numbers,
//  tab width, line wrap, max file size) without a rebuild. Writes straight
//  to the same shared preferences domain QLCCConfiguration reads, so changes
//  take effect on the next preview.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCPreferencesWindowController : NSWindowController
@end

NS_ASSUME_NONNULL_END
