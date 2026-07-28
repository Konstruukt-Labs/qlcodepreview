//
//  QLCCHighlighter.h
//  QLCodePreview
//
//  A small, self-contained, dependency-free syntax highlighter that turns a
//  source file into a themed, standalone HTML document suitable for a
//  Quick Look data-based preview.
//
//  Why built-in (instead of shelling out to `highlight`)?
//  A Quick Look Preview Extension is an App Extension and therefore runs in
//  the macOS sandbox. The sandbox does not reliably allow spawning external
//  processes. Instead it tokenises the file itself with a compact, 
//  per-language regular expression and colours the tokens with a 
//  built-in theme.
//
//  The tokeniser is intentionally simple (comments, strings, numbers,
//  preprocessor / markup, and keywords) but covers the common languages well
//  enough to make previews readable and pleasant.
//

#import <Foundation/Foundation.h>

@class QLCCTheme;
@class QLCCConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface QLCCHighlighter : NSObject

- (instancetype)initWithTheme:(QLCCTheme *)theme
                configuration:(QLCCConfiguration *)configuration;

/// Produce a complete, standalone HTML document for `source` (whose language
/// is inferred from `pathExtension`). Returns nil only if the source is nil.
- (nullable NSString *)htmlPreviewForSource:(NSString *)source
                              pathExtension:(NSString *)pathExtension;

/// The canonical list of language identifiers (e.g. "python", "swift",
/// "css") usable with QLCCConfiguration.customLanguageMap. Sorted,
/// case-insensitively, for direct use in a picker UI.
+ (NSArray<NSString *> *)supportedLanguageNames;

@end

NS_ASSUME_NONNULL_END
