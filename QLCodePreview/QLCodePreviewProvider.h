//
//  QLCodePreviewProvider.h
//  QLCodePreview
//
//  The principal class of the Quick Look **Preview Extension**.
//
//  On macOS 12.0+ Quick Look prefers data-based Preview Extensions
//  (QLPreviewProvider + QLPreviewingController) over the legacy
//  GeneratePreviewForURL callback. This class is the modern home of QLColorCode
//  previews: it reads the requested source file, syntax-highlights it with the
//  built-in tokeniser (see QLCCHighlighter), and returns the result as an HTML
//  QLPreviewReply.
//

@import QuickLookUI;

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCodePreviewProvider : QLPreviewProvider

@end

NS_ASSUME_NONNULL_END
