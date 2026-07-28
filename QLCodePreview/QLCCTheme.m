//
//  QLCCTheme.m
//  QLCodePreview
//

#import "QLCCTheme.h"
#import <dispatch/dispatch.h>

/// A concrete palette described purely with CSS hex strings.
@interface QLCCTheme ()
@end

@implementation QLCCTheme {
    NSString *_name;
    BOOL _isDark;
    NSString *_canvas;
    NSString *_default;
    NSString *_keyword;
    NSString *_string;
    NSString *_comment;
    NSString *_number;
    NSString *_preproc;
    NSString *_variable;
    NSString *_lineNumber;
}

- (instancetype)initWithName:(NSString *)name
                       isDark:(BOOL)isDark
                      canvas:(NSString *)canvas
                      deflt:(NSString *)deflt
                     keyword:(NSString *)keyword
                      string:(NSString *)string
                     comment:(NSString *)comment
                      number:(NSString *)number
                     preproc:(NSString *)preproc
                    variable:(NSString *)variable
                  lineNumber:(NSString *)lineNumber {
    self = [super init];
    if (self) {
        _name = [name copy];
        _isDark = isDark;
        _canvas = [canvas copy];
        _default = [deflt copy];
        _keyword = [keyword copy];
        _string = [string copy];
        _comment = [comment copy];
        _number = [number copy];
        _preproc = [preproc copy];
        _variable = [variable copy];
        _lineNumber = [lineNumber copy];
    }
    return self;
}

- (NSString *)name { return _name; }
- (BOOL)isDark { return _isDark; }
- (NSString *)canvasColor { return _canvas; }
- (NSString *)defaultColor { return _default; }
- (NSString *)keywordColor { return _keyword; }
- (NSString *)stringColor { return _string; }
- (NSString *)commentColor { return _comment; }
- (NSString *)numberColor { return _number; }
- (NSString *)preprocColor { return _preproc; }
- (NSString *)variableColor { return _variable; }
- (NSString *)lineNumberColor { return _lineNumber; }

#pragma mark - Built-in palettes

/// Exact colours lifted from highlight's `edit-xcode.theme` (light).
+ (instancetype)defaultLightTheme {
    return [[QLCCTheme alloc]
        initWithName:@"edit-xcode"
              isDark:NO
             canvas:@"#ffffff"
              deflt:@"#000000"
             keyword:@"#8f0055"
              string:@"#c00000"
             comment:@"#007f1c"
              number:@"#2300ff"
             preproc:@"#733710"
            variable:@"#267f99"
          lineNumber:@"#808080"];
}

/// Exact colours lifted from highlight's `darkplus.theme` (VS Code Dark+).
+ (instancetype)defaultDarkTheme {
    return [[QLCCTheme alloc]
        initWithName:@"darkplus"
              isDark:YES
             canvas:@"#1e1e1e"
              deflt:@"#d4d4d4"
             keyword:@"#569cd6"
              string:@"#d7ba7d"
             comment:@"#6a9955"
              number:@"#b5cea8"
             preproc:@"#007acc"
            variable:@"#9cdcfe"
          lineNumber:@"#858585"];
}

// File-scope (not function-local) so +lightThemeNames/+darkThemeNames can
// also read the palette table without duplicating it.
static NSDictionary<NSString *, NSArray *> *gLightPalettes;
static NSDictionary<NSString *, NSArray *> *gDarkPalettes;
static dispatch_once_t gPalettesOnce;

static void QLCCBuildPalettesOnce(void) {
    dispatch_once(&gPalettesOnce, ^{
        gLightPalettes = @{
            @"edit-xcode" : @[ @"edit-xcode" ], // sentinel handled below
            @"solarized-light" : @[
                @"#fdf6e3", @"#657b83", @"#859900", @"#2aa198", @"#93a1a1",
                @"#d33682", @"#cb4b16", @"#93a1a1", @"#268bd2"
            ],
            @"github" : @[
                @"#ffffff", @"#24292e", @"#d73a49", @"#032f62", @"#6a737d",
                @"#005cc5", @"#6f42c1", @"#959da5", @"#e36209"
            ],
            @"tomorrow" : @[
                @"#ffffff", @"#4d4d4c", @"#8959a8", @"#718c00", @"#8e908c",
                @"#f5871f", @"#4271ae", @"#b4b4b4", @"#c82829"
            ],
        };
        gDarkPalettes = @{
            @"darkplus" : @[ @"darkplus" ],
            @"solarized-dark" : @[
                @"#002b36", @"#93a1a1", @"#859900", @"#2aa198", @"#586e75",
                @"#d33682", @"#268bd2", @"#586e75", @"#6c71c4"
            ],
            @"monokai" : @[
                @"#272822", @"#f8f8f2", @"#f92672", @"#e6db74", @"#75715e",
                @"#ae81ff", @"#66d9ef", @"#90908a", @"#fd971f"
            ],
            @"nord" : @[
                @"#2e3440", @"#d8dee9", @"#81a1c1", @"#a3be8c", @"#616e88",
                @"#b48ead", @"#88c0d0", @"#4c566a", @"#d08770"
            ],
            @"dracula" : @[
                @"#282a36", @"#f8f8f2", @"#ff79c6", @"#f1fa8c", @"#6272a4",
                @"#bd93f9", @"#50fa7b", @"#6272a4", @"#8be9fd"
            ],
            @"tomorrow-night" : @[
                @"#1d1f21", @"#c5c8c6", @"#b294bb", @"#b5bd68", @"#969896",
                @"#de935f", @"#81a2be", @"#969896", @"#cc6666"
            ],
            @"zenburn" : @[
                @"#3f3f3f", @"#dcdccc", @"#dfaf8f", @"#cc9393", @"#7f9f7f",
                @"#8cd0d3", @"#f0dfaf", @"#7f8f8f", @"#94bff3"
            ],
            @"onedark" : @[
                @"#282c34", @"#abb2bf", @"#c678dd", @"#98c379", @"#5c6370",
                @"#d19a66", @"#61afef", @"#5c6370", @"#e06c75"
            ],
        };
    });
}

/// Curated set of additional popular palettes so a user's existing
/// `lightTheme` / `darkTheme` setting resolves to something pleasant instead
/// of falling all the way back to the default.
+ (nullable instancetype)builtinThemeNamed:(NSString *)name {
    QLCCBuildPalettesOnce();
    NSString *n = [name lowercaseString];
    NSDictionary<NSString *, NSArray *> *lights = gLightPalettes;
    NSDictionary<NSString *, NSArray *> *darks = gDarkPalettes;

    NSArray *l = lights[n];
    if (l) {
        if ([n isEqualToString:@"edit-xcode"]) return [self defaultLightTheme];
        return [[QLCCTheme alloc] initWithName:n isDark:NO
            canvas:l[0] deflt:l[1] keyword:l[2] string:l[3] comment:l[4]
            number:l[5] preproc:l[6] variable:l[8] lineNumber:l[7]];
    }
    NSArray *d = darks[n];
    if (d) {
        if ([n isEqualToString:@"darkplus"]) return [self defaultDarkTheme];
        return [[QLCCTheme alloc] initWithName:n isDark:YES
            canvas:d[0] deflt:d[1] keyword:d[2] string:d[3] comment:d[4]
            number:d[5] preproc:d[6] variable:d[8] lineNumber:d[7]];
    }
    return nil;
}

+ (NSArray<NSString *> *)lightThemeNames {
    QLCCBuildPalettesOnce();
    NSMutableArray<NSString *> *names = [gLightPalettes.allKeys mutableCopy];
    [names removeObject:@"edit-xcode"];
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    [names insertObject:@"edit-xcode" atIndex:0];
    return [names copy];
}

+ (NSArray<NSString *> *)darkThemeNames {
    QLCCBuildPalettesOnce();
    NSMutableArray<NSString *> *names = [gDarkPalettes.allKeys mutableCopy];
    [names removeObject:@"darkplus"];
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    [names insertObject:@"darkplus" atIndex:0];
    return [names copy];
}

+ (instancetype)themeNamed:(NSString *)name preferDark:(BOOL)preferDark {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length > 0) {
        QLCCTheme *t = [self builtinThemeNamed:trimmed];
        if (t) return t;
    }
    return preferDark ? [self defaultDarkTheme] : [self defaultLightTheme];
}

@end
