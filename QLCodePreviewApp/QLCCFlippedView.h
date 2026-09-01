//
//  QLCCFlippedView.h
//  QLCodePreview (host app)
//
//  Plain, non-Auto-Layout container with a flipped (top-down) coordinate
//  system, so the settings panes can lay out rows with simple fixed
//  frames (y grows downward) instead of Auto Layout constraints.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCFlippedView : NSView
@end

NS_ASSUME_NONNULL_END
