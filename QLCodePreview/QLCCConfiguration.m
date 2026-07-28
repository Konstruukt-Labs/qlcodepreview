//
//  QLCCConfiguration.m
//  QLCodePreview
//

#import "QLCCConfiguration.h"
#import "QLCCLogging.h"

NSString *const kQLCCAppGroup = @"group.com.konstruuktlabs.QLCodePreview";
NSString *const kQLCCCustomLanguageMapKey = @"customLanguageMap";
// Built-in preview byte cap used when the user hasn't set maxFileSize.
// 4 MB: keeps the master-regex pass comfortably sub-second on real source
// while stopping a multi-MB/minified file from hanging the QL thread.
const unsigned long long kQLCCDefaultMaxFileSize = 4ULL * 1024 * 1024;

/// Read a single value from the shared App Group preference suite, returning
/// `fallback` when it is absent or unreadable.
static id QLCCReadDefault(NSString *key, id fallback) {
    id value = [[QLCCConfiguration sharedDefaults] objectForKey:key];
    return value ?: fallback;
}

/// Returns YES when the user is running in Dark Mode. `AppleInterfaceStyle`
/// is a global preference and is readable from the sandbox.
static BOOL QLCCIsDarkMode(void) {
    NSString *style = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"AppleInterfaceStyle"];
    return [style localizedCaseInsensitiveContainsString:@"Dark"];
}

@implementation QLCCConfiguration

+ (NSUserDefaults *)sharedDefaults {
    static NSUserDefaults *suite;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suite = [[NSUserDefaults alloc] initWithSuiteName:kQLCCAppGroup];
    });
    return suite;
}

+ (instancetype)currentConfiguration {
    QLCCConfiguration *c = [[QLCCConfiguration alloc] init];

    c.font = QLCCReadDefault(@"font", @"Menlo");
    CGFloat size = [QLCCReadDefault(@"fontSizePoints", @10) doubleValue];
    c.fontSize = (size > 0) ? size : 10;

    c.lightTheme = QLCCReadDefault(@"lightTheme", @"edit-xcode");
    c.darkTheme = QLCCReadDefault(@"darkTheme", @"darkplus");

    // "hlTheme" is the *resolved* theme the legacy generator ends up using
    // (it already folds light/dark into it). We honour appearance ourselves,
    // but if the user pinned an explicit hlTheme we respect it as a tie-
    // breaker only when both light/dark resolve to it.
    NSString *pinned = QLCCReadDefault(@"hlTheme", nil);
    if (pinned.length > 0) {
        c.lightTheme = pinned;
        c.darkTheme = pinned;
    }

    c.darkMode = QLCCIsDarkMode();

    // Parse the extra highlight flags the user configured. The defaults ship
    // "-t 4 ".
    NSString *extraFlags = QLCCReadDefault(@"extraHLFlags", @"-t 4 ");
    [c parseHighlightFlags:extraFlags];

    NSNumber *gutter = QLCCReadDefault(@"lineNumberGutterWidth", @10);
    CGFloat gutterWidth = [gutter doubleValue];
    c.lineNumberGutterWidth = (gutterWidth >= 0) ? gutterWidth : 10;

    NSNumber *maxSize = QLCCReadDefault(@"maxFileSize", @(kQLCCDefaultMaxFileSize));
    c.maxFileSize = [maxSize unsignedLongLongValue];

    NSDictionary *customMap = QLCCReadDefault(kQLCCCustomLanguageMapKey, @{});
    c.customLanguageMap = [customMap isKindOfClass:[NSDictionary class]] ? customMap : @{};

    QLCCLog(@"config: font=%@ size=%.1f theme=%@ dark=%d lineNumbers=%d "
            @"tabWidth=%lu wrap=%d maxFileSize=%llu customTypes=%lu",
            c.font, (double)c.fontSize, [c effectiveThemeName],
            (int)c.darkMode, (int)c.showLineNumbers, (unsigned long)c.tabWidth,
            (int)c.wrapLines, c.maxFileSize, (unsigned long)c.customLanguageMap.count);

    return c;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _font = @"Menlo";
        _fontSize = 10;
        _lightTheme = @"edit-xcode";
        _darkTheme = @"darkplus";
        _darkMode = NO;
        _showLineNumbers = NO;
        _lineNumberGutterWidth = 10;
        _tabWidth = 4;
        _wrapLines = NO;
        _maxFileSize = 0;
        _customLanguageMap = @{};
    }
    return self;
}

- (NSString *)effectiveThemeName {
    return self.darkMode ? self.darkTheme : self.lightTheme;
}

/// Interpret a subset of the highlight command-line flags, as documented in
/// the classic QLColorCode README. Unknown flags are ignored.
- (void)parseHighlightFlags:(NSString *)flags {
    NSArray<NSString *> *tokens =
        [flags componentsSeparatedByCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];

    NSUInteger i = 0;
    while (i < tokens.count) {
        NSString *tok = tokens[i];
        if ([tok isEqualToString:@"-l"] || [tok isEqualToString:@"--line-numbers"]) {
            self.showLineNumbers = YES;
        } else if ([tok isEqualToString:@"-W"] || [tok isEqualToString:@"--wrap"] ||
                   [tok isEqualToString:@"-V"] || [tok isEqualToString:@"--wrap-simple"]) {
            self.wrapLines = YES;
        } else if ([tok isEqualToString:@"-t"] || [tok isEqualToString:@"--replace-tabs"]) {
            // -t takes an argument: either as the next token ("-t 4") or
            // glued ("-t4").
            NSUInteger n = [self parseUnsignedAfterFlag:tok tokens:tokens index:&i];
            if (n > 0) self.tabWidth = n;
        }
        i++;
    }
}

/// Resolve the numeric argument of a flag such as `-t`. Handles both
/// `-t 4` (separate token) and `-t4` (glued). Advances `*index` past the
/// consumed argument token when applicable.
- (NSUInteger)parseUnsignedAfterFlag:(NSString *)flag
                              tokens:(NSArray<NSString *> *)tokens
                               index:(NSUInteger *)index {
    NSString *glued =
        [flag substringFromIndex:MIN(flag.length, 2)]; // strip "-t"/"--"
    if (glued.length > 0) {
        return (NSUInteger)[glued integerValue];
    }
    NSUInteger next = *index + 1;
    if (next < tokens.count) {
        NSInteger v = [tokens[next] integerValue];
        if (v > 0) {
            *index = next;
            return (NSUInteger)v;
        }
    }
    return 0;
}

@end
