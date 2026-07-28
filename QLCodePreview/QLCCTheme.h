//
//  QLCCTheme.h
//  QLCodePreview
//
//  A colour palette for a syntax-highlighted preview. QLCodePreview ships a
//  small, curated set of built-in palettes (seeded from the exact colours of
//  highlight's `edit-xcode` and `darkplus` themes) and resolves any theme
//  name the user configured to the closest available one. This keeps the
//  extension fully self-contained — no external theme files to parse.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QLCCTheme : NSObject

/// Human-readable name (e.g. "edit-xcode").
@property (nonatomic, readonly) NSString *name;

/// `YES` for palettes designed for a dark canvas.
@property (nonatomic, readonly) BOOL isDark;

// Colours as CSS hex strings, e.g. @"#c00000".
@property (nonatomic, readonly) NSString *canvasColor;     // page background
@property (nonatomic, readonly) NSString *defaultColor;    // default text
@property (nonatomic, readonly) NSString *keywordColor;    // language keywords
@property (nonatomic, readonly) NSString *stringColor;     // string literals
@property (nonatomic, readonly) NSString *commentColor;    // comments
@property (nonatomic, readonly) NSString *numberColor;     // numeric literals
@property (nonatomic, readonly) NSString *preprocColor;    // preprocessor / tags
@property (nonatomic, readonly) NSString *variableColor;   // variables (e.g. PHP $foo)
@property (nonatomic, readonly) NSString *lineNumberColor; // line-number gutter

/// Resolve a theme by name. Falls back to a sensible default that matches the
/// requested appearance when the name is unknown.
+ (instancetype)themeNamed:(NSString *)name preferDark:(BOOL)preferDark;

/// The default light palette ("edit-xcode").
+ (instancetype)defaultLightTheme;
/// The default dark palette ("darkplus").
+ (instancetype)defaultDarkTheme;

/// Names of all built-in palettes designed for a light canvas, suitable for
/// populating a theme picker. "edit-xcode" (the default) is listed first.
+ (NSArray<NSString *> *)lightThemeNames;
/// Names of all built-in palettes designed for a dark canvas, suitable for
/// populating a theme picker. "darkplus" (the default) is listed first.
+ (NSArray<NSString *> *)darkThemeNames;

@end

NS_ASSUME_NONNULL_END
