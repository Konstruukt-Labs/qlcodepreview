//
//  QLCCHighlighter.m
//  QLCodePreview
//

#import "QLCCHighlighter.h"
#import "QLCCTheme.h"
#import "QLCCConfiguration.h"
#import "QLCCLogging.h"

#import <objc/runtime.h>   // objc_setAssociatedObject (kind->regex mapping)

@import UniformTypeIdentifiers;

// ---------------------------------------------------------------------------
// Token kinds
// ---------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, QLCCTokenKind) {
    QLCCTokenDefault = 0,
    QLCCTokenComment,
    QLCCTokenString,
    QLCCTokenPreproc,
    QLCCTokenNumber,
    QLCCTokenKeyword,
    QLCCTokenVariable,
};

/// Streaming token sink: every tokenizer hands the runs of text it finds,
/// plus their colour category, to an emit block in strict document order.
/// The renderers consume tokens front-to-back, so nothing ever
/// materialises the whole file as ~200k intermediate segment objects
/// (measured: +11 MB retained and ~273k live malloc blocks for a 2 MB
/// source under the previous build-an-array design).
typedef void (^QLCCEmitBlock)(NSString *text, QLCCTokenKind kind);

// Forward declaration so the language-config builder below can derive one
// config from another inline. Implementation is at the bottom of this file.
@interface NSDictionary (QLCCMerge)
- (NSDictionary *)mtl_setValue:(id)value forKey:(NSString *)key;
@end

// ---------------------------------------------------------------------------
// Ready-made regex fragments (heavily escaped because they live in ObjC strings)
// ---------------------------------------------------------------------------

// Line comments (terminate at the end of the line).
static NSString *const kPatSlashLineComment = @"\\/\\/[^\\n]*";     // //...
static NSString *const kPatHashLineComment  = @"#[^\\n]*";          // #...
static NSString *const kPatDashLineComment  = @"--[^\\n]*";         // --...
static NSString *const kPatSemiLineComment  = @";[^\\n]*";          // ;...
static NSString *const kPatRemLineComment   = @"(?:REM|')[^\\n]*";   // BASIC / VB
//   (non-capturing group: a bare (REM|') here would add an extra capture
//   group and desync the kind->group invariant in cachedRegexForConfig: —
//   see the DEBUG assert below.)

// Block comments (may span lines — non-greedy).
static NSString *const kPatCBlockComment    = @"\\/\\*[\\s\\S]*?\\*\\/";   // /* */
static NSString *const kPatXmlComment        = @"<\\!--[\\s\\S]*?-->";      // <!-- -->
static NSString *const kPatLuaBlockComment  = @"--\\[\\[[\\s\\S]*?\\]\\]"; // --[[ ]]
static NSString *const kPatHaskellBlock     = @"\\{-[\\s\\S]*?-\\}";       // {- -}
static NSString *const kPatFSharpBlock      = @"\\(\\*[\\s\\S]*?\\*\\)";   // (* ... *)

// String literals.
static NSString *const kPatDoubleString = @"\"(?:\\\\.|[^\"\\\\\\n])*\"";
static NSString *const kPatSingleString = @"'(?:\\\\.|[^'\\\\\\n])*'";
static NSString *const kPatBacktickString = @"`(?:\\\\.|[^`\\\\\\n])*`";
static NSString *const kPatPythonTriple =
    @"\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''";
// Swift extended raw string literals: #"…"#, ##"…"##, … — one or more '#'
// pairs around a double-quoted body. Narrow on purpose: it requires a real
// opening quote, so it cannot swallow Swift compiler directives (#if,
// #available, #selector, …) the way kPatHashLineComment did.
static NSString *const kPatSwiftRawString = @"#+\"[\\s\\S]*?\"#+";

// Numeric literals (hex / binary / float / exponent, optional type suffix).
static NSString *const kPatNumber =
    @"\\b(?:0[xX][0-9a-fA-F'_]+|0[bB][01'_]+|(?:\\d[\\d'_]*\\.?\\d*|\\.\\d+)"
    @"(?:[eE][+-]?\\d+)?)[fFlLuUdD]*\\b";

// C preprocessor line: a line whose first non-whitespace char is '#'.
static NSString *const kPatCPreproc = @"^[ \\t]*#[^\\n]*";

// Variable references inside an interpolating double-quoted string (e.g.
// PHP): "{$expr}" braces, or a bare "$var", optionally chained with
// "->prop" / "[index]" (PHP's simple- and curly-interpolation syntaxes). A
// leading "(?<!\\)" keeps an escaped "\$"/"\{" from being mistaken for
// interpolation. Used only for a secondary, standalone sub-tokenisation
// pass over already-matched string segments — NOT one of the
// cachedRegexForConfig: pieces, so it is exempt from that mechanism's
// "exactly one capturing group per piece" invariant.
static NSString *const kPatInterpVar =
    @"(?<!\\\\)\\{\\$[^{}]*\\}"
    @"|(?<!\\\\)\\$[A-Za-z_][A-Za-z0-9_]*(?:->[A-Za-z_][A-Za-z0-9_]*|\\[[^\\]\\n]*\\])*";

// ---------------------------------------------------------------------------
// QLCCHighlighter
// ---------------------------------------------------------------------------

@interface QLCCHighlighter ()
@property (nonatomic, strong) QLCCTheme *theme;
@property (nonatomic, strong) QLCCConfiguration *config;
@end

@implementation QLCCHighlighter

- (instancetype)initWithTheme:(QLCCTheme *)theme
                configuration:(QLCCConfiguration *)configuration {
    self = [super init];
    if (self) {
        _theme = theme;
        _config = configuration;
    }
    return self;
}

#pragma mark - Public

- (nullable NSString *)htmlPreviewForSource:(NSString *)source
                              pathExtension:(NSString *)pathExtension {
    if (source.length == 0) return nil;

    // User-defined overrides (set via the host app's "Custom File Types"
    // window) win over the built-in extension map; an unrecognised override
    // value just falls back to the "text" config, so this is always safe.
    NSString *extKey = [pathExtension lowercaseString];
    NSString *lang = self.config.customLanguageMap[extKey];
    if (lang.length == 0) {
        lang = [QLCCHighlighter languageForExtension:pathExtension];
    }
    NSDictionary *cfg = [QLCCHighlighter languageConfig:lang];

    // PHP files routinely mix literal HTML with "<?php ... ?>" blocks. If
    // an opening tag is actually present, split the source into HTML/PHP
    // runs and tokenise each with its own existing tokenizer instead of
    // running the whole file through the PHP config alone (which has no
    // idea what to do with surrounding markup). A .php file that is pure
    // PHP with no literal "<?php"/"<?=" anywhere (the common case for our
    // own test fixtures, and for modern short-open-tag-less snippets) skips
    // this entirely and is tokenised exactly as before — zero behaviour
    // change for that case.
    // Tokenisation is streamed straight into the renderer (see
    // -emitTokensForSource:language:config:emit:): PHP files with a real
    // opening tag route through the embedded-HTML tokenizer, markdown
    // through the fence splitter, everything else through the language's
    // master regex — all behind one emit-block API.
    NSString *body =
        self.config.showLineNumbers
            ? [self renderLineNumbersTableWithSource:source language:lang config:cfg]
            : [self renderPlainPreWithSource:source language:lang config:cfg];

    return [self wrapBody:body];
}

#pragma mark - Language detection

/// Map a file extension to a canonical language name understood by
/// +languageConfig:. Returns @"text" as a harmless fallback.
+ (NSString *)languageForExtension:(NSString *)ext {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // C family
            @"c" : @"c", @"h" : @"objc",
            @"m" : @"objc", @"mm" : @"objcpp",
            @"cpp" : @"cpp", @"cc" : @"cpp", @"cxx" : @"cpp", @"c++" : @"cpp",
            @"hpp" : @"cpp", @"hh" : @"cpp", @"hxx" : @"cpp", @"h++" : @"cpp",
            @"ino" : @"cpp",
            // Apple / systems
            @"swift" : @"swift",
            @"rs" : @"rust",
            @"go" : @"go",
            @"zig" : @"zig", @"nim" : @"nim",
            // JVM
            @"java" : @"java", @"kt" : @"kotlin", @"kts" : @"kotlin",
            @"scala" : @"scala", @"sc" : @"scala", @"groovy" : @"groovy",
            @"gradle" : @"groovy",
            @"clj" : @"clojure", @"cljs" : @"clojure",
            // .NET
            @"cs" : @"csharp", @"fs" : @"fsharp", @"vb" : @"vb",
            // Web
            @"js" : @"javascript", @"mjs" : @"javascript", @"cjs" : @"javascript",
            @"jsx" : @"javascript",
            @"ts" : @"typescript", @"tsx" : @"typescript",
            @"php" : @"php",
            @"install" : @"php", @"module" : @"php", @"engine" : @"php",
            @"css" : @"css", @"scss" : @"css", @"sass" : @"css", @"less" : @"css",
            @"styl" : @"css",
            @"html" : @"html", @"htm" : @"html", @"xhtml" : @"html",
            @"vue" : @"html", @"svelte" : @"html",
            @"xml" : @"xml", @"xsl" : @"xml", @"xslt" : @"xml", @"xsd" : @"xml",
            @"rss" : @"xml", @"svg" : @"xml", @"resx" : @"xml", @"csproj" : @"xml",
            @"plist" : @"xml", @"iml" : @"xml", @"fxml" : @"xml", @"rdf" : @"xml",
            // Scripting
            @"py" : @"python", @"pyw" : @"python", @"pyi" : @"python",
            @"rb" : @"ruby", @"rbw" : @"ruby", @"gemspec" : @"ruby",
            @"pl" : @"perl", @"pm" : @"perl", @"t" : @"perl",
            @"lua" : @"lua",
            @"tcl" : @"tcl",
            @"sh" : @"shell", @"bash" : @"shell", @"zsh" : @"shell",
            @"ksh" : @"shell", @"csh" : @"shell", @"tcsh" : @"shell",
            @"fish" : @"shell", @"command" : @"shell", @"bashrc" : @"shell",
            @"zshrc" : @"shell", @"bash_profile" : @"shell", @"profile" : @"shell",
            @"bats" : @"shell", @"ebuild" : @"shell", @"eclass" : @"shell",
            @"ps1" : @"powershell", @"psm1" : @"powershell",
            // Data / config
            @"json" : @"json", @"json5" : @"json", @"jsonl" : @"json",
            @"yaml" : @"yaml", @"yml" : @"yaml",
            @"toml" : @"toml",
            @"ini" : @"ini", @"cfg" : @"ini", @"conf" : @"ini", @"properties" : @"ini",
            @"editorconfig" : @"ini", @"gitconfig" : @"ini",
            // DB
            @"sql" : @"sql", @"psql" : @"sql", @"ddl" : @"sql",
            // Build
            @"mk" : @"make", @"makefile" : @"make", @"gnumakefile" : @"make", @"am" : @"make",
            @"cmake" : @"cmake",
            @"graphql" : @"graphql", @"gql" : @"graphql",
            @"tf" : @"terraform", @"tfvars" : @"terraform",
            // Docs / markup
            @"md" : @"markdown", @"markdown" : @"markdown",
            @"adoc" : @"markdown", @"asciidoc" : @"markdown",
            @"rst" : @"markdown",
            // Misc
            @"r" : @"r",
            @"dart" : @"dart",
            @"ex" : @"elixir", @"exs" : @"elixir",
            @"erl" : @"erlang", @"hrl" : @"erlang",
            @"hs" : @"haskell", @"lhs" : @"haskell",
            @"pas" : @"pascal", @"pp" : @"pascal", @"dpr" : @"pascal",
            @"jl" : @"julia",
            @"cr" : @"crystal",
            @"diff" : @"diff", @"patch" : @"diff", @"rej" : @"diff",
            @"tex" : @"tex", @"latex" : @"tex",
            @"txt" : @"text", @"log" : @"text",
            // FILE_ID.DIZ (BBS archive descriptions), NFO (release info),
            // SFV (CRC32 checksum listings), and .readme (install/usage
            // notes): all plain text, but mapped explicitly so the intent
            // is documented rather than relying on the unknown-extension
            // fallback. "readme" also catches a dotless README filename
            // via the provider's filename fallback.
            @"diz" : @"text", @"nfo" : @"text", @"sfv" : @"text",
            @"readme" : @"text",
        };
    });
    NSString *key = [ext lowercaseString];
    return map[key] ?: @"text";
}

/// Resolve a Markdown fenced-code-block language tag (the word right after
/// the opening ``` /~~~, e.g. "js" in "```js") to one of our canonical
/// language names. Most tags already match either a canonical name
/// (```python, ```javascript, ```html) or a file extension we already know
/// (```go, ```swift, ```lua) — this only needs an alias table for the
/// handful of common tags that match neither.
+ (NSString *)languageForFenceTag:(NSString *)tag {
    NSString *t = [[tag lowercaseString]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0) return @"text";

    static NSDictionary *aliases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        aliases = @{
            @"js" : @"javascript", @"jsx" : @"javascript", @"node" : @"javascript",
            @"ts" : @"typescript", @"tsx" : @"typescript",
            @"py" : @"python", @"py3" : @"python", @"python3" : @"python",
            @"rb" : @"ruby", @"ruby" : @"ruby",
            @"sh" : @"shell", @"bash" : @"shell", @"zsh" : @"shell",
            @"shell-script" : @"shell", @"console" : @"shell", @"terminal" : @"shell",
            @"yml" : @"yaml",
            @"objective-c" : @"objc", @"objectivec" : @"objc",
            @"objective-c++" : @"objcpp", @"objectivecpp" : @"objcpp",
            @"c++" : @"cpp", @"cxx" : @"cpp",
            @"cs" : @"csharp", @"c#" : @"csharp", @"csharp" : @"csharp",
            @"f#" : @"fsharp",
            @"kt" : @"kotlin", @"kts" : @"kotlin",
            @"rs" : @"rust",
            @"golang" : @"go",
            @"json5" : @"json", @"jsonc" : @"json",
            @"dockerfile" : @"shell", // best-effort; no dedicated config
            @"plaintext" : @"text", @"text" : @"text", @"txt" : @"text",
        };
    });
    NSString *alias = aliases[t];
    if (alias) return alias;

    // The tag used directly as a canonical language name (```python, etc).
    if ([[self supportedLanguageNames] containsObject:t]) return t;

    // Fall back to the extension map (```go, ```swift, ```lua, ...).
    return [self languageForExtension:t];
}

#pragma mark - Language configuration

// File-scope (not function-local) so +supportedLanguageNames can also read
// the fully-built config table without duplicating it.
static NSDictionary *gLanguageConfigs;
static dispatch_once_t gLanguageConfigsOnce;

/// Returns a language configuration dictionary. Recognised keys:
///   lineComments : NSArray<NSString*> of ready regex fragments
///   blockComments: NSArray<NSString*> of ready regex fragments (or absent)
///   strings      : NSArray<NSString*> of ready regex fragments
///   preproc      : NSNumber bool — include the C preprocessor fragment
///   keywords     : NSArray<NSString*> of bare keywords
+ (NSDictionary *)languageConfig:(NSString *)lang {
    static NSArray *cKeywords;
    dispatch_once(&gLanguageConfigsOnce, ^{
        cKeywords = @[
            @"auto", @"break", @"case", @"char", @"const", @"continue", @"default",
            @"do", @"double", @"else", @"enum", @"extern", @"float", @"for",
            @"goto", @"if", @"inline", @"int", @"long", @"register", @"restrict",
            @"return", @"short", @"signed", @"sizeof", @"static", @"struct",
            @"switch", @"typedef", @"union", @"unsigned", @"void", @"volatile",
            @"while", @"_Bool", @"_Complex", @"_Imaginary", @"NULL",
        ];

        // The C-family shell: // and /* */ comments, " and ' strings.
        NSDictionary *cBase = @{
            @"lineComments" : @[ kPatSlashLineComment ],
            @"blockComments" : @[ kPatCBlockComment ],
            @"strings" : @[ kPatDoubleString, kPatSingleString ],
            // #import/#include/#define/#ifdef/#pragma lines coloured as
            // preprocessor. cBase is shared by c, cpp, objc and objcpp, so
            // all four C-family configs pick this up.
            @"preproc" : @YES,
        };

        gLanguageConfigs = @{
            @"c" : [cBase mtl_setValue:cKeywords forKey:@"keywords"],
            @"cpp" : [[cBase mtl_setValue:@[
                @"alignas", @"alignof", @"and", @"asm", @"auto", @"bool", @"break",
                @"case", @"catch", @"char", @"class", @"compl", @"concept",
                @"const", @"constexpr", @"const_cast", @"continue", @"decltype",
                @"default", @"delete", @"do", @"double", @"dynamic_cast", @"else",
                @"enum", @"explicit", @"export", @"extern", @"false", @"final",
                @"float", @"for", @"friend", @"goto", @"if", @"inline", @"int",
                @"long", @"mutable", @"namespace", @"new", @"noexcept", @"nullptr",
                @"operator", @"or", @"override", @"private", @"protected",
                @"public", @"register", @"reinterpret_cast", @"requires",
                @"return", @"short", @"signed", @"sizeof", @"static",
                @"static_assert", @"static_cast", @"struct", @"switch", @"template",
                @"this", @"throw", @"true", @"try", @"typedef", @"typeid",
                @"typename", @"union", @"unsigned", @"using", @"virtual", @"void",
                @"volatile", @"wchar_t", @"while",
            ] forKey:@"keywords"]
              // See the php config below for the full rationale.
              mtl_setValue:
                  @"(?<=\\b(?:class|struct|new|typename)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                  @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                  @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b"
              forKey:@"typeOrCallPattern"],

            @"objc" : [cBase mtl_setValue:@[
                @"@interface", @"@implementation", @"@end", @"@class",
                @"@protocol", @"@property", @"@synthesize", @"@dynamic",
                @"@selector", @"@encode", @"@try", @"@catch", @"@finally",
                @"@throw", @"@autoreleasepool", @"@synchronized", @"@public",
                @"@private", @"@protected", @"@package", @"@required",
                @"@optional", @"@defs", @"@compatibility_alias",
                @"IBAction", @"IBOutlet", @"IBOutletCollection", @"NS_ENUM",
                @"NS_OPTIONS", @"self", @"super", @"nil", @"YES", @"NO", @"id",
                @"instancetype", @"BOOL", @"YES", @"NO", @"NSString", @"NSArray",
                @"NSDictionary", @"NSObject",
            ] forKey:@"keywords"],
            @"objcpp" : [cBase mtl_setValue:@[
                @"@interface", @"@implementation", @"@end", @"@class",
                @"@property", @"@autoreleasepool", @"@selector", @"@synthesize",
                @"class", @"namespace", @"template", @"typename", @"public",
                @"private", @"protected", @"virtual", @"override", @"const",
                @"constexpr", @"static_cast", @"dynamic_cast", @"reinterpret_cast",
                @"auto", @"self", @"super", @"nil", @"nullptr", @"instancetype",
                @"BOOL", @"YES", @"NO", @"IBAction", @"IBOutlet",
            ] forKey:@"keywords"],

            @"swift" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                // kPatSwiftRawString covers #"…"# raw literals only; ordinary
                // compiler directives (#if/#available/#selector/…) are left as
                // plain text rather than swallowed whole as "strings". The old
                // kPatHashLineComment ("#[^\\n]*") here painted every # line as
                // a string.
                @"strings" : @[ kPatPythonTriple, kPatDoubleString,
                                kPatSingleString, kPatSwiftRawString ],
                @"keywords" : @[
                    @"associatedtype", @"async", @"await", @"break", @"case",
                    @"catch", @"class", @"continue", @"default", @"defer", @"do",
                    @"else", @"enum", @"extension", @"fallthrough", @"false",
                    @"fileprivate", @"final", @"for", @"func", @"get", @"guard",
                    @"if", @"import", @"in", @"inout", @"internal", @"is", @"lazy",
                    @"let", @"mutating", @"nil", @"open", @"operator", @"private",
                    @"protocol", @"public", @"repeat", @"rethrows", @"return",
                    @"self", @"Self", @"set", @"static", @"struct", @"subscript",
                    @"super", @"switch", @"throw", @"throws", @"true", @"try",
                    @"typealias", @"var", @"weak", @"where", @"while", @"yield",
                ],
                // Swift has no "new"/"extends"/"implements" — a type
                // (class/struct/enum/protocol) name after those
                // declaration keywords, or after "as"/"is" (casts and
                // type-checks), is the closest equivalent. See the php
                // config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|struct|enum|protocol|as|is)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"rust" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"as", @"async", @"await", @"break", @"const", @"continue",
                    @"crate", @"dyn", @"else", @"enum", @"extern", @"false", @"fn",
                    @"for", @"if", @"impl", @"in", @"let", @"loop", @"match", @"mod",
                    @"move", @"mut", @"pub", @"ref", @"return", @"self", @"Self",
                    @"static", @"struct", @"super", @"trait", @"true", @"type",
                    @"unsafe", @"use", @"where", @"while",
                ],
            },

            @"go" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString, kPatBacktickString ],
                @"keywords" : @[
                    @"break", @"case", @"chan", @"const", @"continue", @"default",
                    @"defer", @"else", @"fallthrough", @"for", @"func", @"go",
                    @"goto", @"if", @"import", @"interface", @"map", @"package",
                    @"range", @"return", @"select", @"struct", @"switch", @"type",
                    @"var",
                ],
                // A type name right after "type" (e.g. "type Foo struct")
                // pins precisely; the PascalCase fallback pairs naturally
                // with Go's own convention that exported identifiers are
                // capitalised. See the php config above for the full
                // rationale of this three-alternative pattern.
                @"typeOrCallPattern" :
                    @"(?<=\\btype[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"java" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"abstract", @"assert", @"boolean", @"break", @"byte", @"case",
                    @"catch", @"char", @"class", @"const", @"continue", @"default",
                    @"do", @"double", @"else", @"enum", @"extends", @"final",
                    @"finally", @"float", @"for", @"goto", @"if", @"implements",
                    @"import", @"instanceof", @"int", @"interface", @"long",
                    @"native", @"new", @"package", @"private", @"protected",
                    @"public", @"return", @"short", @"static", @"strictfp",
                    @"super", @"switch", @"synchronized", @"this", @"throw",
                    @"throws", @"transient", @"try", @"void", @"volatile", @"while",
                    @"true", @"false", @"null",
                ],
                // See the php config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|extends|implements|instanceof|interface)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"kotlin" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString ],
                @"keywords" : @[
                    @"as", @"break", @"by", @"class", @"continue", @"data", @"do",
                    @"else", @"false", @"for", @"fun", @"if", @"in", @"interface",
                    @"is", @"object", @"override", @"package", @"private",
                    @"protected", @"public", @"return", @"sealed", @"super",
                    @"suspend", @"this", @"throw", @"true", @"try", @"typealias",
                    @"val", @"var", @"when", @"while",
                ],
                // See the php config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|interface|object|is|as)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"scala" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"abstract", @"case", @"catch", @"class", @"def", @"do", @"else",
                    @"extends", @"false", @"final", @"finally", @"for", @"forSome",
                    @"if", @"implicit", @"import", @"lazy", @"match", @"new",
                    @"null", @"object", @"override", @"package", @"private",
                    @"protected", @"return", @"sealed", @"super", @"this", @"throw",
                    @"trait", @"true", @"try", @"type", @"val", @"var", @"while",
                    @"with", @"yield",
                ],
                // See the php config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|extends|with|trait)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"groovy" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"as", @"assert", @"break", @"case", @"catch", @"class",
                    @"const", @"continue", @"def", @"default", @"do", @"else",
                    @"enum", @"extends", @"false", @"finally", @"for", @"goto",
                    @"if", @"implements", @"import", @"in", @"instanceof",
                    @"interface", @"new", @"null", @"package", @"return", @"super",
                    @"switch", @"this", @"throw", @"throws", @"trait", @"true",
                    @"try", @"while",
                ],
            },

            @"clojure" : @{
                @"lineComments" : @[ kPatSemiLineComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"def", @"defn", @"defn-", @"defmacro", @"defmulti", @"defmethod",
                    @"defprotocol", @"defrecord", @"deftype", @"fn", @"let", @"loop",
                    @"recur", @"if", @"when", @"cond", @"case", @"do", @"and", @"or",
                    @"not", @"nil", @"true", @"false", @"ns", @"require", @"import",
                ],
            },

            @"csharp" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"preproc" : @YES,
                @"keywords" : @[
                    @"abstract", @"as", @"base", @"bool", @"break", @"byte", @"case",
                    @"catch", @"char", @"checked", @"class", @"const", @"continue",
                    @"decimal", @"default", @"delegate", @"do", @"double", @"else",
                    @"enum", @"event", @"explicit", @"extern", @"false", @"finally",
                    @"fixed", @"float", @"for", @"foreach", @"goto", @"if",
                    @"implicit", @"in", @"int", @"interface", @"internal", @"is",
                    @"lock", @"long", @"namespace", @"new", @"null", @"object",
                    @"operator", @"out", @"override", @"params", @"private",
                    @"protected", @"public", @"readonly", @"ref", @"return", @"sbyte",
                    @"sealed", @"short", @"sizeof", @"stackalloc", @"static",
                    @"string", @"struct", @"switch", @"this", @"throw", @"true",
                    @"try", @"typeof", @"uint", @"ulong", @"unchecked", @"unsafe",
                    @"ushort", @"using", @"virtual", @"void", @"volatile", @"while",
                    @"var", @"async", @"await", @"yield",
                ],
                // See the php config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|struct|interface|is|as)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"fsharp" : @{
                // F# line comments are //; block comments are (* … *). The old
                // config matched the literal three chars "(*)" (not a comment at
                // all) and used Haskell's {- -} for blocks, so neither F# comment
                // style was ever coloured.
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatFSharpBlock ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"abstract", @"and", @"as", @"assert", @"base", @"begin",
                    @"class", @"default", @"delegate", @"do", @"done", @"downcast",
                    @"downto", @"elif", @"else", @"end", @"exception", @"extern",
                    @"false", @"finally", @"fixed", @"for", @"fun", @"function",
                    @"global", @"if", @"in", @"inherit", @"inline", @"interface",
                    @"internal", @"lazy", @"let", @"match", @"member", @"module",
                    @"mutable", @"namespace", @"new", @"null", @"of", @"open", @"or",
                    @"override", @"private", @"public", @"rec", @"return", @"select",
                    @"static", @"struct", @"then", @"to", @"true", @"try", @"type",
                    @"upcast", @"use", @"val", @"void", @"when", @"while", @"with",
                    @"yield",
                ],
            },

            @"vb" : @{
                @"lineComments" : @[ kPatRemLineComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"AddHandler", @"AddressOf", @"Alias", @"And", @"AndAlso",
                    @"As", @"Boolean", @"ByRef", @"Byte", @"ByVal", @"Call",
                    @"Case", @"Catch", @"CBool", @"CByte", @"CChar", @"CDate",
                    @"CDbl", @"CDec", @"Char", @"CInt", @"Class", @"CLng",
                    @"CObj", @"Const", @"Continue", @"CSByte", @"CShort", @"CSng",
                    @"CStr", @"CType", @"CUInt", @"CULng", @"CUShort", @"Date",
                    @"Decimal", @"Declare", @"Default", @"Delegate", @"Dim",
                    @"DirectCast", @"Do", @"Double", @"Each", @"Else", @"ElseIf",
                    @"End", @"EndIf", @"Enum", @"Erase", @"Error", @"Event",
                    @"Exit", @"False", @"Finally", @"For", @"Friend", @"Function",
                    @"Get", @"GetType", @"Global", @"GoSub", @"GoTo", @"Handles",
                    @"If", @"Implements", @"Imports", @"In", @"Inherits", @"Integer",
                    @"Interface", @"Is", @"IsNot", @"Let", @"Lib", @"Like", @"Long",
                    @"Loop", @"Me", @"Mod", @"Module", @"MustInherit",
                    @"MustOverride", @"MyBase", @"MyClass", @"Namespace", @"Narrowing",
                    @"New", @"Next", @"Not", @"Nothing", @"NotInheritable",
                    @"NotOverridable", @"Object", @"Of", @"On", @"Operator", @"Option",
                    @"Optional", @"Or", @"OrElse", @"Overloads", @"Overridable",
                    @"Overrides", @"ParamArray", @"Partial", @"Private", @"Property",
                    @"Protected", @"Public", @"RaiseEvent", @"ReadOnly", @"ReDim",
                    @"REM", @"RemoveHandler", @"Resume", @"Return", @"SByte",
                    @"Select", @"Set", @"Shadows", @"Shared", @"Short", @"Single",
                    @"Static", @"Step", @"Stop", @"String", @"Structure", @"Sub",
                    @"SyncLock", @"Then", @"Throw", @"To", @"True", @"Try", @"TryCast",
                    @"TypeOf", @"UInteger", @"ULong", @"UShort", @"Using", @"Variant",
                    @"Wend", @"When", @"While", @"Widening", @"With", @"WithEvents",
                    @"WriteOnly", @"Xor", @"Yield",
                ],
            },

            @"javascript" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatBacktickString, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"break", @"case", @"catch", @"class", @"const", @"continue",
                    @"debugger", @"default", @"delete", @"do", @"else", @"export",
                    @"extends", @"finally", @"for", @"function", @"if", @"import",
                    @"in", @"instanceof", @"let", @"new", @"of", @"return", @"super",
                    @"switch", @"this", @"throw", @"try", @"typeof", @"var", @"void",
                    @"while", @"with", @"yield", @"async", @"await", @"null",
                    @"undefined", @"true", @"false",
                ],
                // See the php config above for the full rationale. JS
                // identifiers may start with "$"/"_" (jQuery, Angular
                // conventions), so the character classes include both.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|extends|instanceof)[ \t])[A-Za-z_$][A-Za-z0-9_$]*"
                    @"|\\b[A-Za-z_$][A-Za-z0-9_$]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_$]*\\b",
                // Only template literals (`...`) interpolate in JS/TS —
                // "..."/'...' strings never do — so the delimiter that
                // gates the sub-tokenisation pass is the backtick, not the
                // double-quote PHP/Ruby/Perl/shell use. Non-nested "${...}"
                // only (same limitation as PHP's "{$...}" — no attempt to
                // balance nested braces).
                @"interpolates" : @YES,
                @"interpDelimiter" : @"`",
                @"interpPattern" : @"(?<!\\\\)\\$\\{[^{}]*\\}",
            },

            @"typescript" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatBacktickString, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"break", @"case", @"catch", @"class", @"const", @"continue",
                    @"debugger", @"default", @"delete", @"do", @"else", @"enum",
                    @"export", @"extends", @"finally", @"for", @"function", @"if",
                    @"import", @"in", @"instanceof", @"interface", @"let", @"new",
                    @"namespace", @"of", @"private", @"protected", @"public",
                    @"readonly", @"return", @"static", @"super", @"switch", @"this",
                    @"throw", @"try", @"type", @"typeof", @"var", @"void", @"while",
                    @"with", @"yield", @"async", @"await", @"abstract", @"as",
                    @"implements", @"module", @"declare", @"null", @"undefined",
                    @"true", @"false",
                ],
                // See the javascript config above for the full rationale.
                @"interpolates" : @YES,
                @"interpDelimiter" : @"`",
                @"interpPattern" : @"(?<!\\\\)\\$\\{[^{}]*\\}",
                // See the php config below for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|extends|implements|instanceof|interface)[ \t])[A-Za-z_$][A-Za-z0-9_$]*"
                    @"|\\b[A-Za-z_$][A-Za-z0-9_$]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_$]*\\b",
            },

            @"php" : @{
                @"lineComments" : @[ kPatSlashLineComment, kPatHashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"abstract", @"and", @"array", @"as", @"break", @"callable",
                    @"case", @"catch", @"class", @"clone", @"const", @"continue",
                    @"declare", @"default", @"die", @"do", @"echo", @"else",
                    @"elseif", @"empty", @"enddeclare", @"endfor", @"endforeach",
                    @"endif", @"endswitch", @"endwhile", @"eval", @"exit", @"extends",
                    @"final", @"finally", @"fn", @"for", @"foreach", @"function",
                    @"global", @"goto", @"if", @"implements", @"include",
                    @"include_once", @"instanceof", @"insteadof", @"interface",
                    @"isset", @"list", @"match", @"namespace", @"new", @"or", @"print",
                    @"private", @"protected", @"public", @"readonly", @"require",
                    @"require_once", @"return", @"static", @"switch", @"throw",
                    @"trait", @"try", @"unset", @"use", @"var", @"while", @"xor",
                    @"yield", @"true", @"false", @"null",
                ],
                // $foo, $this, $_GET, etc.
                @"variablePattern" : @"\\$[A-Za-z_][A-Za-z0-9_]*",
                // PHP double-quoted (but not single-quoted) strings
                // interpolate $variables — sub-tokenise them after the
                // fact via kPatInterpVar rather than baking that into the
                // master regex above.
                @"interpolates" : @YES,
                @"interpDelimiter" : @"\"",
                @"interpPattern" : kPatInterpVar,
                // Three cases sharing one colour, most-precise first:
                //  1. An identifier immediately after "class"/"new"/
                //     "extends"/"implements"/"instanceof" — a lookbehind
                //     pins this to an actual type-name position, so this
                //     never misfires on an ALL_CAPS constant or any other
                //     capitalised identifier that just happens to appear
                //     elsewhere.
                //  2. Any identifier immediately followed by "("
                //     (function/method calls and definitions).
                //  3. A fallback PascalCase heuristic for everything else
                //     (e.g. a type-hint like "function f(Exception $e)"
                //     that isn't after one of the keywords above) —
                //     requires a lowercase second character so it doesn't
                //     also catch ALL_CAPS constants (MY_CONST, TRUE-style
                //     defines), which real class names essentially never
                //     collide with in practice.
                // Listed after "keywords" above so reserved words like
                // "if (" / "for (" stay keyword-coloured rather than being
                // caught by case 2 here.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|new|extends|implements|instanceof)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"python" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"False", @"None", @"True", @"and", @"as", @"assert", @"async",
                    @"await", @"break", @"class", @"continue", @"def", @"del", @"elif",
                    @"else", @"except", @"finally", @"for", @"from", @"global", @"if",
                    @"import", @"in", @"is", @"lambda", @"nonlocal", @"not", @"or",
                    @"pass", @"raise", @"return", @"try", @"while", @"with", @"yield",
                ],
                // See the php config above for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\bclass[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"ruby" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"blockComments" : @[ @"=begin[\\s\\S]*?=end" ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"BEGIN", @"END", @"alias", @"and", @"begin", @"break", @"case",
                    @"class", @"def", @"defined?", @"do", @"else", @"elsif", @"end",
                    @"ensure", @"false", @"for", @"if", @"in", @"module", @"next",
                    @"nil", @"not", @"or", @"redo", @"rescue", @"retry", @"return",
                    @"self", @"super", @"then", @"true", @"undef", @"unless", @"until",
                    @"when", @"while", @"yield", @"__FILE__", @"__LINE__",
                    @"__ENCODING__",
                ],
                // @foo (instance var), @@foo (class var), $foo (global).
                @"variablePattern" : @"@@?[A-Za-z_][A-Za-z0-9_]*|\\$[A-Za-z_][A-Za-z0-9_]*",
                // See the php config above for the full rationale. Ruby
                // method names may end in "?"/"!" (e.g. "empty?", "save!"),
                // so the call-pattern alternative allows an optional
                // trailing one before the "(".
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|module)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*[?!]?(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
                // Ruby double-quoted (but not single-quoted) strings
                // interpolate via "#{expr}" (non-nested-brace, same
                // limitation as PHP's "{$...}").
                @"interpolates" : @YES,
                @"interpDelimiter" : @"\"",
                @"interpPattern" : @"(?<!\\\\)\\#\\{[^{}]*\\}",
            },

            @"perl" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"if", @"unless", @"while", @"until", @"for", @"foreach", @"do",
                    @"last", @"next", @"redo", @"return", @"goto", @"sub", @"my",
                    @"our", @"local", @"use", @"no", @"package", @"require", @"eval",
                    @"print", @"printf", @"defined", @"undef", @"else", @"elsif",
                    @"eq", @"ne", @"lt", @"gt", @"le", @"ge", @"and", @"or", @"not",
                ],
                // $scalar, @array, %hash sigils.
                @"variablePattern" :
                    @"\\$[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\@[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\%[A-Za-z_][A-Za-z0-9_]*",
                // Perl double-quoted (but not single-quoted) strings
                // interpolate $scalars and @arrays.
                @"interpolates" : @YES,
                @"interpDelimiter" : @"\"",
                @"interpPattern" :
                    @"(?<!\\\\)\\$\\{[^{}]*\\}"
                    @"|(?<!\\\\)\\$[A-Za-z_][A-Za-z0-9_]*"
                    @"|(?<!\\\\)\\@[A-Za-z_][A-Za-z0-9_]*",
            },

            @"lua" : @{
                @"lineComments" : @[ kPatDashLineComment ],
                @"blockComments" : @[ kPatLuaBlockComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"and", @"break", @"do", @"else", @"elseif", @"end", @"false",
                    @"for", @"function", @"goto", @"if", @"in", @"local", @"nil",
                    @"not", @"or", @"repeat", @"return", @"then", @"true", @"until",
                    @"while",
                ],
            },

            @"tcl" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"proc", @"global", @"set", @"if", @"else", @"elseif", @"while",
                    @"for", @"foreach", @"return", @"break", @"continue", @"switch",
                    @"catch", @"error", @"upvar", @"uplevel", @"namespace", @"eval",
                ],
            },

            @"shell" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString, kPatBacktickString ],
                @"keywords" : @[
                    @"if", @"then", @"else", @"elif", @"fi", @"case", @"esac", @"for",
                    @"in", @"do", @"done", @"while", @"until", @"function",
                    @"select", @"time", @"return", @"exit", @"export", @"local",
                    @"readonly", @"declare", @"typeset", @"unset", @"trap", @"alias",
                    @"echo", @"printf", @"read", @"source",
                ],
                // $VAR, ${VAR}, and the single-character positional/special
                // parameters ($1, $@, $#, $?, $*, $$, $!, $-, $0).
                @"variablePattern" :
                    @"\\$\\{[^{}]*\\}"
                    @"|\\$[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\$[0-9@#?*$!-]",
                // Double-quoted (but not single-quoted) strings interpolate
                // $VAR/${VAR} — backtick strings are command substitution,
                // not string interpolation, so they're deliberately not
                // included here.
                @"interpolates" : @YES,
                @"interpDelimiter" : @"\"",
                @"interpPattern" :
                    @"(?<!\\\\)\\$\\{[^{}]*\\}"
                    @"|(?<!\\\\)\\$[A-Za-z_][A-Za-z0-9_]*"
                    @"|(?<!\\\\)\\$[0-9@#?*$!-]",
            },

            @"powershell" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"begin", @"break", @"catch", @"class", @"continue", @"data",
                    @"define", @"do", @"dynamicparam", @"else", @"elseif", @"end",
                    @"exit", @"filter", @"finally", @"for", @"foreach", @"from",
                    @"function", @"if", @"in", @"param", @"process", @"return",
                    @"switch", @"throw", @"try", @"until", @"using", @"var", @"while",
                    @"workflow", @"yield",
                ],
                // $var, ${var}, and namespaced $env:PATH / $global:x forms.
                @"variablePattern" :
                    @"\\$\\{[^{}]*\\}"
                    @"|\\$[A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z_][A-Za-z0-9_]*)?",
            },

            @"sql" : @{
                @"lineComments" : @[ kPatDashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatSingleString, kPatDoubleString ],
                @"keywords" : @[
                    @"SELECT", @"FROM", @"WHERE", @"INSERT", @"INTO", @"VALUES",
                    @"UPDATE", @"SET", @"DELETE", @"CREATE", @"TABLE", @"ALTER",
                    @"DROP", @"INDEX", @"VIEW", @"JOIN", @"INNER", @"LEFT", @"RIGHT",
                    @"OUTER", @"FULL", @"ON", @"GROUP", @"BY", @"ORDER", @"HAVING",
                    @"ASC", @"DESC", @"LIMIT", @"OFFSET", @"DISTINCT", @"UNION",
                    @"ALL", @"AS", @"AND", @"OR", @"NOT", @"NULL", @"IS", @"IN",
                    @"BETWEEN", @"LIKE", @"CASE", @"WHEN", @"THEN", @"ELSE", @"END",
                    @"PRIMARY", @"KEY", @"FOREIGN", @"REFERENCES", @"DEFAULT",
                    @"CONSTRAINT", @"UNIQUE", @"CHECK", @"BEGIN", @"COMMIT",
                    @"ROLLBACK", @"TRANSACTION",
                ],
            },

            @"json" : @{
                // JSON has no comments; highlight strings + numbers + the
                // structural punctuation implicitly through them.
                @"strings" : @[ kPatDoubleString ],
            },

            @"yaml" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                // The piece must contain no capturing groups of its own —
                // cachedRegexForConfig wraps it in exactly one group and
                // relies on a strict one-group-per-piece count to look up
                // each match's kind, so any "(...)" here (including inside
                // a look-around) must be "(?:...)" instead. Leading
                // indentation is consumed as part of the match (like
                // kPatCPreproc does) rather than via look-behind — harmless
                // since whitespace renders with no visible color anyway.
                @"keyPattern" : @"^[ \t]*[A-Za-z0-9_.\\-]+(?=[ \t]*:(?:[ \t]|$))",
                @"booleanPattern" : @"\\b(?i:true|false|yes|no|on|off|null)\\b|~",
                @"valuePattern" : @"[^\\s:#=\\[\\]{}\",']+",
            },

            @"toml" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"keyPattern" : @"^[ \t]*[A-Za-z0-9_.\\-]+(?=[ \t]*=)",
                @"booleanPattern" : @"\\b(?:true|false)\\b",
            },

            @"ini" : @{
                @"lineComments" : @[ kPatSemiLineComment, kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keyPattern" : @"^[ \t]*[A-Za-z0-9_.\\-]+(?=[ \t]*=)",
                @"booleanPattern" : @"\\b(?i:true|false|yes|no|on|off)\\b",
                @"valuePattern" : @"[^\\s#;=\\[\\]\",']+",
            },

            @"make" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[ @".PHONY", @".SILENT", @".SUFFIXES", @".DEFAULT",
                                 @".PRECIOUS", @".INTERMEDIATE", @".DELETE_ON_ERROR" ],
            },

            @"cmake" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"cmake_minimum_required", @"project", @"set", @"unset",
                    @"message", @"if", @"elseif", @"else", @"endif", @"foreach",
                    @"endforeach", @"while", @"endwhile", @"function", @"endfunction",
                    @"macro", @"endmacro", @"add_executable", @"add_library",
                    @"target_link_libraries", @"target_include_directories",
                    @"include_directories", @"find_package", @"include", @"option",
                    @"install", @"configure_file",
                ],
            },

            @"graphql" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString ],
                @"keywords" : @[
                    @"type", @"input", @"interface", @"union", @"enum", @"scalar",
                    @"schema", @"directive", @"extend", @"implements", @"fragment",
                    @"query", @"mutation", @"subscription", @"on", @"true", @"false",
                    @"null",
                ],
            },

            @"terraform" : @{
                @"lineComments" : @[ kPatHashLineComment, kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"resource", @"data", @"provider", @"variable", @"output",
                    @"locals", @"module", @"terraform", @"for_each", @"count", @"if",
                    @"else", @"true", @"false", @"null",
                ],
            },

            @"css" : @{
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                // CSS custom properties ("CSS variables") — --main-color,
                // both at their "--main-color: ..." declaration and at
                // every "var(--main-color)" use site. Reuses the same
                // variableColor role PHP/Ruby/Perl use for $/@ variables;
                // the name fits.
                @"variablePattern" : @"--[A-Za-z_-][A-Za-z0-9_-]*",
                // CSS has no reserved words in the language-grammar sense, so
                // "keywords" here is a curated list of common at-rules,
                // properties, and value tokens — without it, a typical CSS
                // file (selectors/properties/hex colors, no comments or
                // quoted strings) renders with no highlighting at all.
                @"keywords" : @[
                    @"@charset", @"@import", @"@media", @"@supports", @"@page",
                    @"@font-face", @"@keyframes", @"@namespace", @"@document",
                    @"@layer", @"@container", @"@property",
                    @"align-items", @"align-content", @"align-self",
                    @"animation", @"background", @"background-color",
                    @"background-image", @"background-position",
                    @"background-repeat", @"background-size", @"border",
                    @"border-radius", @"border-color", @"border-width",
                    @"border-style", @"border-top", @"border-right",
                    @"border-bottom", @"border-left", @"border-top-width",
                    @"border-right-width", @"border-bottom-width",
                    @"border-left-width", @"border-top-color",
                    @"border-right-color", @"border-bottom-color",
                    @"border-left-color", @"border-top-style",
                    @"border-right-style", @"border-bottom-style",
                    @"border-left-style", @"box-shadow", @"box-sizing",
                    @"bottom", @"color",
                    @"content", @"cursor", @"display", @"filter", @"flex",
                    @"flex-direction", @"flex-wrap", @"float", @"font",
                    @"font-family", @"font-size", @"font-style",
                    @"font-weight", @"gap", @"grid", @"grid-template-columns",
                    @"grid-template-rows", @"height", @"justify-content",
                    @"left", @"letter-spacing", @"line-height", @"margin",
                    @"margin-top", @"margin-right", @"margin-bottom",
                    @"margin-left", @"padding-top", @"padding-right",
                    @"padding-bottom", @"padding-left",
                    @"max-height", @"max-width", @"min-height", @"min-width",
                    @"opacity", @"outline", @"overflow", @"padding",
                    @"position", @"right", @"text-align", @"text-decoration",
                    @"text-overflow", @"text-transform", @"top", @"transform",
                    @"transition", @"vertical-align", @"visibility",
                    @"white-space", @"width", @"z-index",
                    @"absolute", @"auto", @"block", @"bold", @"border-box",
                    @"center", @"contain", @"cover", @"dashed", @"dotted",
                    @"fixed", @"flex-end", @"flex-start", @"grid", @"hidden",
                    @"important", @"inherit", @"initial", @"inline",
                    @"inline-block", @"inline-flex", @"italic", @"none",
                    @"normal", @"nowrap", @"relative", @"revert", @"solid",
                    @"space-between", @"static", @"sticky", @"underline",
                    @"unset", @"uppercase", @"visible",
                ],
                // Vendor-prefixed properties/values (-webkit-*, -moz-*,
                // -ms-*, -o-*, -khtml-*) are effectively open-ended — no
                // fixed list could cover them all — so this is a PATTERN,
                // not a literal-string list like "keywords" above.
                // "(?<!:)" excludes vendor-prefixed PSEUDO-ELEMENTS like
                // "::-webkit-scrollbar-thumb" — the generic identifier
                // boundary this piece is wrapped in (see
                // cachedRegexForConfig: below) doesn't catch that case
                // because ":" isn't a "-"/alnum identifier character, so a
                // pseudo-element's leading "::" would otherwise look like a
                // perfectly good boundary even though this obviously isn't
                // a property here.
                @"extraKeywordPattern" : @"(?<!:)-(?:webkit|moz|ms|o|khtml)-[A-Za-z-]+",
            },

            @"html" : @{
                @"blockComments" : @[ kPatXmlComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
            },
            @"xml" : @{
                @"blockComments" : @[ kPatXmlComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
            },

            @"markdown" : @{
                // Nothing structural to colour reliably; keep it plain but
                // readable. Headings/atx are picked up as "preproc"-ish.
            },

            @"r" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"if", @"else", @"for", @"while", @"function", @"return",
                    @"break", @"next", @"repeat", @"in", @"TRUE", @"FALSE", @"NULL",
                    @"NA", @"Inf", @"NaN", @"library", @"require", @"source",
                ],
            },

            @"dart" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"abstract", @"as", @"assert", @"async", @"await", @"break",
                    @"case", @"catch", @"class", @"const", @"continue", @"default",
                    @"deferred", @"do", @"dynamic", @"else", @"enum", @"export",
                    @"extends", @"extension", @"external", @"factory", @"false",
                    @"final", @"finally", @"for", @"Function", @"get", @"hide", @"if",
                    @"implements", @"import", @"in", @"interface", @"is", @"library",
                    @"late", @"mixin", @"new", @"null", @"on", @"operator", @"part",
                    @"required", @"rethrow", @"return", @"set", @"show", @"static",
                    @"super", @"switch", @"sync", @"this", @"throw", @"true", @"try",
                    @"typedef", @"var", @"void", @"while", @"with", @"yield",
                ],
                // See the php config above for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|extends|implements|new|is|as)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"elixir" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"after", @"and", @"catch", @"case", @"cond", @"def", @"defp",
                    @"defmodule", @"defprotocol", @"defimpl", @"defmacro",
                    @"defmacrop", @"defstruct", @"do", @"else", @"end", @"fn", @"for",
                    @"if", @"import", @"in", @"not", @"or", @"quote", @"raise",
                    @"receive", @"require", @"rescue", @"return", @"throw", @"try",
                    @"unless", @"unquote", @"use", @"when", @"while", @"with",
                ],
            },

            @"erlang" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"after", @"and", @"andalso", @"band", @"begin", @"bnot", @"bor",
                    @"bsl", @"bsr", @"bxor", @"case", @"catch", @"cond", @"div", @"end",
                    @"fun", @"if", @"let", @"not", @"of", @"or", @"orelse", @"query",
                    @"receive", @"rem", @"try", @"when", @"xor",
                ],
            },

            @"haskell" : @{
                @"lineComments" : @[ kPatDashLineComment ],
                @"blockComments" : @[ kPatHaskellBlock ],
                @"strings" : @[ kPatDoubleString ],
                @"keywords" : @[
                    @"case", @"class", @"data", @"default", @"deriving", @"do",
                    @"else", @"foreign", @"if", @"import", @"in", @"infix", @"infixl",
                    @"infixr", @"instance", @"let", @"module", @"newtype", @"of",
                    @"then", @"type", @"where", @"_",
                ],
            },

            @"pascal" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"blockComments" : @[ kPatCBlockComment ],
                @"strings" : @[ kPatSingleString ],
                @"keywords" : @[
                    @"absolute", @"abstract", @"and", @"array", @"as", @"asm",
                    @"begin", @"case", @"class", @"const", @"constructor", @"destructor",
                    @"dispinterface", @"div", @"do", @"downto", @"else", @"end",
                    @"except", @"exports", @"file", @"finalization", @"finally", @"for",
                    @"function", @"goto", @"if", @"implementation", @"in", @"inherited",
                    @"initialization", @"inline", @"interface", @"is", @"label",
                    @"library", @"mod", @"nil", @"not", @"object", @"of", @"or", @"out",
                    @"packed", @"procedure", @"program", @"property", @"raise",
                    @"record", @"repeat", @"resourcestring", @"set", @"shl", @"shr",
                    @"string", @"then", @"threadvar", @"to", @"try", @"type", @"unit",
                    @"until", @"uses", @"var", @"while", @"with", @"xor",
                ],
            },

            @"julia" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatPythonTriple, kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"baremodule", @"begin", @"break", @"catch", @"const", @"continue",
                    @"do", @"else", @"elseif", @"end", @"export", @"false", @"finally",
                    @"for", @"function", @"global", @"if", @"import", @"in", @"isa",
                    @"let", @"local", @"macro", @"module", @"mutable", @"primitive",
                    @"quote", @"return", @"struct", @"true", @"try", @"type", @"using",
                    @"where", @"while",
                ],
            },

            @"crystal" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"abstract", @"alias", @"annotation", @"as", @"asm", @"begin",
                    @"break", @"case", @"class", @"def", @"do", @"else", @"elsif",
                    @"end", @"ensure", @"enum", @"extend", @"false", @"for", @"fun",
                    @"if", @"in", @"include", @"instance_sizeof", @"is_a?", @"lib",
                    @"macro", @"module", @"next", @"nil", @"of", @"out", @"pointerof",
                    @"private", @"protected", @"public", @"raise", @"require",
                    @"rescue", @"responds_to?", @"return", @"select", @"self", @"sizeof",
                    @"struct", @"super", @"then", @"true", @"type", @"typeof",
                    @"uninitialized", @"union", @"unless", @"until", @"verbatim",
                    @"when", @"while", @"with", @"yield",
                ],
                // Crystal has no "extends" keyword (inheritance uses
                // "class Foo < Bar"); the closest reliable trigger words
                // are its declaration keywords plus "as"/"is_a?"/"new". See
                // the php config above for the full rationale.
                @"typeOrCallPattern" :
                    @"(?<=\\b(?:class|struct|module|as)[ \t])[A-Za-z_][A-Za-z0-9_]*"
                    @"|\\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\\()"
                    @"|\\b[A-Z][a-z][A-Za-z0-9_]*\\b",
            },

            @"zig" : @{
                @"lineComments" : @[ kPatSlashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"addrspace", @"align", @"allowzero", @"and", @"asm", @"async",
                    @"await", @"break", @"catch", @"comptime", @"const", @"continue",
                    @"defer", @"else", @"enum", @"errdefer", @"error", @"export",
                    @"extern", @"fn", @"for", @"if", @"inline", @"noalias", @"nosuspend",
                    @"opaque", @"or", @"orelse", @"packed", @"pub", @"resume", @"return",
                    @"struct", @"suspend", @"switch", @"test", @"threadlocal", @"try",
                    @"union", @"unreachable", @"var", @"volatile", @"while",
                ],
            },

            @"nim" : @{
                @"lineComments" : @[ kPatHashLineComment ],
                @"strings" : @[ kPatDoubleString, kPatSingleString ],
                @"keywords" : @[
                    @"addr", @"and", @"as", @"asm", @"bind", @"block", @"break", @"case",
                    @"cast", @"concept", @"const", @"continue", @"converter", @"defer",
                    @"discard", @"distinct", @"div", @"do", @"elif", @"else", @"end",
                    @"enum", @"except", @"export", @"finally", @"for", @"from", @"func",
                    @"if", @"import", @"in", @"include", @"interface", @"is", @"isnot",
                    @"iterator", @"let", @"macro", @"method", @"mixin", @"mod", @"nil",
                    @"not", @"notin", @"object", @"of", @"or", @"out", @"proc",
                    @"ptr", @"raise", @"ref", @"return", @"shl", @"shr", @"static",
                    @"template", @"try", @"tuple", @"type", @"using", @"var", @"when",
                    @"while", @"xor", @"yield",
                ],
            },

            @"diff" : @{ /* handled specially by the emit dispatcher */ },

            @"tex" : @{
                @"lineComments" : @[ @"%[^\\n]*" ],
                @"strings" : @[ ],
            },

            @"text" : @{},
        };

    });

    return gLanguageConfigs[lang] ?: gLanguageConfigs[@"text"];
}

/// The canonical list of language identifiers usable with the custom
/// extension→language override map (see QLCCConfiguration.customLanguageMap).
/// Exposed so the host app's "Custom File Types" UI can populate a picker
/// without duplicating this list.
+ (NSArray<NSString *> *)supportedLanguageNames {
    // Force the same dispatch_once used by +languageConfig: so this works
    // even if called before any +languageConfig: call.
    (void)[self languageConfig:@"text"];
    NSMutableArray<NSString *> *names =
        [gLanguageConfigs.allKeys mutableCopy];
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return [names copy];
}

#pragma mark - Tokenisation

/// Tokenise `source` for `language`, handing each run of text plus its
/// colour category to `emit` in strict document order. This routes to the
/// right tokenizer: PHP files with a real opening tag split into HTML/PHP
/// runs tokenised by their own configs (a pure-PHP file with no literal
/// "<?php"/"<?=" anywhere skips that entirely), markdown splits on fenced
/// code blocks, diffs colour by line prefix, and everything else runs
/// through the language's master regex.
- (void)emitTokensForSource:(NSString *)source
                   language:(NSString *)language
                     config:(NSDictionary *)cfg
                       emit:(QLCCEmitBlock)emit {
    if ([language isEqualToString:@"php"] && [QLCCHighlighter sourceHasPHPOpenTag:source]) {
        [self emitEmbeddedPHPTokens:source emit:emit];
    } else if ([language isEqualToString:@"markdown"]) {
        [self emitMarkdownTokens:source emit:emit];
    } else if ([language isEqualToString:@"diff"]) {
        [self emitDiffTokens:source emit:emit];
    } else {
        [self emitMasterRegexTokensForSource:source language:language config:cfg emit:emit];
    }
}

/// Walk `source` with the language's single master regular expression
/// (assembled by cachedRegexForConfig:), emitting each coloured token.
- (void)emitMasterRegexTokensForSource:(NSString *)source
                              language:(NSString *)language
                                config:(NSDictionary *)cfg
                                  emit:(QLCCEmitBlock)emit {
    NSRegularExpression *regex = [self cachedRegexForConfig:cfg language:language];
    if (!regex) {
        emit(source, QLCCTokenDefault);
        return;
    }

    __block NSUInteger cursor = 0;
    const NSRange wholeRange = NSMakeRange(0, source.length);
    const BOOL interpolates = [cfg[@"interpolates"] boolValue];
    // Which opening string delimiter actually interpolates for this
    // language — '"' for PHP/Ruby/Perl/shell (their single-quoted strings
    // never interpolate), '`' for JS/TS template literals (their '"'/"'"
    // strings never interpolate). Defaults to '"' when unspecified.
    NSString *interpDelimiterStr = cfg[@"interpDelimiter"] ?: @"\"";
    unichar interpDelimiter =
        interpDelimiterStr.length > 0 ? [interpDelimiterStr characterAtIndex:0] : '"';
    // The sub-tokenisation pattern is language-specific (PHP's "$foo",
    // Ruby's "#{expr}", JS's "${expr}", Perl's "$scalar"/"@array", shell's
    // "$VAR"/"${VAR}") — falls back to PHP's pattern only as a safety net
    // for a config that sets "interpolates" without its own pattern.
    NSString *interpPattern = cfg[@"interpPattern"] ?: kPatInterpVar;

    [regex enumerateMatchesInString:source
                            options:0
                              range:wholeRange
                         usingBlock:^(NSTextCheckingResult *m,
                                      NSMatchingFlags flags, BOOL *stop) {
        if (m.range.location > cursor) {
            emit([source substringWithRange:
                      NSMakeRange(cursor, m.range.location - cursor)],
                 QLCCTokenDefault);
        }
        QLCCTokenKind kind = [QLCCHighlighter kindOfMatch:m inRegex:regex];
        NSString *matchedText = [source substringWithRange:m.range];
        if (interpolates && kind == QLCCTokenString && matchedText.length > 0 &&
            [matchedText characterAtIndex:0] == interpDelimiter) {
            [self emitInterpolatedTokensForString:matchedText
                                          pattern:interpPattern
                                             emit:emit];
        } else {
            emit(matchedText, kind);
        }
        cursor = m.range.location + m.range.length;
    }];

    if (cursor < source.length) {
        emit([source substringFromIndex:cursor], QLCCTokenDefault);
    }
}

/// Diff hunk colouring: + lines green, - lines red, @@ headers blue.
- (void)emitDiffTokens:(NSString *)source emit:(QLCCEmitBlock)emit {
    NSArray<NSString *> *lines = [source componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        QLCCTokenKind kind = QLCCTokenDefault;
        if ([line hasPrefix:@"@@"]) {
            kind = QLCCTokenPreproc;
        } else if ([line hasPrefix:@"+"] && ![line hasPrefix:@"++"]) {
            kind = QLCCTokenComment;
        } else if ([line hasPrefix:@"-"] && ![line hasPrefix:@"--"]) {
            kind = QLCCTokenString; // red via string slot
        }
        emit(line, kind);
        if (i + 1 < lines.count) {
            emit(@"\n", QLCCTokenDefault);
        }
    }
}

+ (BOOL)sourceHasPHPOpenTag:(NSString *)source {
    NSRange r1 = [source rangeOfString:@"<?php" options:NSCaseInsensitiveSearch];
    if (r1.location != NSNotFound) return YES;
    NSRange r2 = [source rangeOfString:@"<?="];
    return r2.location != NSNotFound;
}

/// Split `source` into HTML/PHP runs on "<?php"/"<?=" ... "?>" boundaries
/// and tokenise each run with its own existing per-language tokenizer
/// (reusing 100% of the "html" and "php" configs already defined above —
/// this only decides which existing tokenizer runs on which slice of
/// text). Text before the first opening tag (or after the last closing
/// tag) is HTML, matching real PHP semantics: only text between tags is
/// ever executed as PHP.
- (void)emitEmbeddedPHPTokens:(NSString *)source emit:(QLCCEmitBlock)emit {
    static NSRegularExpression *delimRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        delimRegex = [NSRegularExpression regularExpressionWithPattern:
                          @"<\\?php\\b|<\\?=|\\?>"
                                                                 options:NSRegularExpressionCaseInsensitive
                                                                   error:&err];
        if (err) {
            QLCCLog(@"Failed to compile PHP delimiter regex: %@", err.localizedDescription);
        }
    });
    if (!delimRegex) {
        return [self emitMasterRegexTokensForSource:source language:@"php"
                                              config:[QLCCHighlighter languageConfig:@"php"]
                                                emit:emit];
    }

    NSDictionary *htmlCfg = [QLCCHighlighter languageConfig:@"html"];
    NSDictionary *phpCfg = [QLCCHighlighter languageConfig:@"php"];

    __block NSUInteger cursor = 0;
    __block BOOL inPHP = NO;
    const NSRange wholeRange = NSMakeRange(0, source.length);

    void (^emitChunk)(NSRange, BOOL) = ^(NSRange range, BOOL asPHP) {
        if (range.length == 0) return;
        NSString *chunk = [source substringWithRange:range];
        [self emitMasterRegexTokensForSource:chunk
                                    language:(asPHP ? @"php" : @"html")
                                      config:(asPHP ? phpCfg : htmlCfg)
                                        emit:emit];
    };

    [delimRegex enumerateMatchesInString:source
                                 options:0
                                   range:wholeRange
                              usingBlock:^(NSTextCheckingResult *m,
                                           NSMatchingFlags flags, BOOL *stop) {
        NSString *delim = [source substringWithRange:m.range];
        BOOL isOpen = ([delim caseInsensitiveCompare:@"<?php"] == NSOrderedSame) ||
                      [delim isEqualToString:@"<?="];
        if (!inPHP && isOpen) {
            // Emit the preceding HTML run; the tag itself starts the PHP
            // run (it's simplest and safe to let the PHP tokenizer treat
            // "<?php"/"<?=" as plain untokenised text — it won't match any
            // PHP piece, so it just renders in the default colour).
            emitChunk(NSMakeRange(cursor, m.range.location - cursor), NO);
            cursor = m.range.location;
            inPHP = YES;
        } else if (inPHP && !isOpen) {
            // "?>" closes the PHP run — include it in the PHP chunk.
            NSUInteger end = m.range.location + m.range.length;
            emitChunk(NSMakeRange(cursor, end - cursor), YES);
            cursor = end;
            inPHP = NO;
        }
        // A "?>" seen while not in PHP (e.g. inside an HTML comment/string)
        // or a second opener seen while already in PHP isn't a real
        // boundary — ignore it and keep scanning in the current state.
    }];

    if (cursor < source.length) {
        emitChunk(NSMakeRange(cursor, source.length - cursor), inPHP);
    }
}

/// Split a Markdown source into runs of plain Markdown and ```lang ... ```
/// (or ~~~lang ... ~~~) fenced code blocks, tokenising each fenced block's
/// body with its OWN existing per-language tokenizer (dispatched via
/// +languageForFenceTag:) — the same "which existing tokenizer runs on
/// which slice of text" idea as -emitEmbeddedPHPTokens:. The fence
/// delimiter lines themselves (and the language tag) are re-emitted
/// verbatim, unstyled. Markdown otherwise has no structural highlighting
/// of its own (see the "markdown" config above), so a file with no fenced
/// blocks at all renders exactly as before this change.
- (void)emitMarkdownTokens:(NSString *)source emit:(QLCCEmitBlock)emit {
    static NSRegularExpression *fenceRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *err = nil;
        // Group 1: fence run (``` or ~~~, backreferenced for the close).
        // Group 2: language tag (may be empty).
        // Group 3: the fenced body.
        // This is a standalone regex (not a cachedRegexForConfig: piece),
        // so — unlike those — it's fine for it to have multiple capturing
        // groups; we read them by explicit index below.
        fenceRegex = [NSRegularExpression regularExpressionWithPattern:
            @"^(```|~~~)[ \t]*([A-Za-z0-9_+#.-]*)[ \t]*\n([\\s\\S]*?)^\\1[ \t]*$"
                                                                 options:NSRegularExpressionAnchorsMatchLines
                                                                   error:&err];
        if (err) {
            QLCCLog(@"Failed to compile markdown fence regex: %@", err.localizedDescription);
        }
    });

    NSDictionary *mdCfg = [QLCCHighlighter languageConfig:@"markdown"];
    if (!fenceRegex) {
        [self emitMasterRegexTokensForSource:source language:@"markdown" config:mdCfg emit:emit];
        return;
    }

    __block NSUInteger cursor = 0;
    const NSRange wholeRange = NSMakeRange(0, source.length);

    [fenceRegex enumerateMatchesInString:source
                                 options:0
                                   range:wholeRange
                              usingBlock:^(NSTextCheckingResult *m,
                                           NSMatchingFlags flags, BOOL *stop) {
        if (m.range.location > cursor) {
            NSString *before = [source substringWithRange:
                                    NSMakeRange(cursor, m.range.location - cursor)];
            [self emitMasterRegexTokensForSource:before language:@"markdown"
                                           config:mdCfg emit:emit];
        }

        NSRange langRange = [m rangeAtIndex:2];
        NSRange bodyRange = [m rangeAtIndex:3];
        NSString *tag = (langRange.location != NSNotFound && langRange.length > 0)
                             ? [source substringWithRange:langRange]
                             : @"";
        NSString *fenceLang = [QLCCHighlighter languageForFenceTag:tag];
        NSDictionary *fenceCfg = [QLCCHighlighter languageConfig:fenceLang];

        // Opening fence line (delimiter + language tag) re-emitted verbatim.
        NSRange openRange = NSMakeRange(m.range.location, bodyRange.location - m.range.location);
        emit([source substringWithRange:openRange], QLCCTokenDefault);

        if (bodyRange.length > 0) {
            NSString *body = [source substringWithRange:bodyRange];
            if ([fenceLang isEqualToString:@"php"] && [QLCCHighlighter sourceHasPHPOpenTag:body]) {
                [self emitEmbeddedPHPTokens:body emit:emit];
            } else {
                [self emitMasterRegexTokensForSource:body language:fenceLang
                                                config:fenceCfg emit:emit];
            }
        }

        // Closing fence line re-emitted verbatim.
        NSUInteger bodyEnd = bodyRange.location + bodyRange.length;
        NSRange closeRange = NSMakeRange(bodyEnd, (m.range.location + m.range.length) - bodyEnd);
        emit([source substringWithRange:closeRange], QLCCTokenDefault);

        cursor = m.range.location + m.range.length;
    }];

    if (cursor < source.length) {
        NSString *tail = [source substringFromIndex:cursor];
        [self emitMasterRegexTokensForSource:tail language:@"markdown" config:mdCfg emit:emit];
    }
}

/// Compile-and-cache an interpolation sub-pattern. Each interpolating
/// language supplies its own pattern via cfg[@"interpPattern"] (PHP's
/// "$foo"/"{$expr}", Ruby's "#{expr}", JS/TS's "${expr}", Perl's
/// "$scalar"/"@array", shell's "$VAR"/"${VAR}") — cached in the same
/// shared regex cache used for the per-language master regexes, under an
/// "interp:"-prefixed key so the two namespaces can't collide.
- (nullable NSRegularExpression *)interpolationRegexForPattern:(NSString *)pattern {
    NSString *cacheKey = [@"interp:" stringByAppendingString:pattern];
    NSRegularExpression *cached = [[QLCCHighlighter sharedRegexCache] objectForKey:cacheKey];
    if (cached) return cached;

    NSError *err = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&err];
    if (err) {
        QLCCLog(@"Failed to compile interpolation regex %@: %@", pattern, err.localizedDescription);
        return nil;
    }
    [[QLCCHighlighter sharedRegexCache] setObject:regex forKey:cacheKey];
    return regex;
}

/// Split an already-matched interpolating string (delimiters included)
/// into alternating String/Variable segments wherever `pattern` matches.
/// Falls back to a single String segment covering the whole text if
/// nothing matches (the common case — most strings don't interpolate
/// anything) or if the regex failed to compile.
- (void)emitInterpolatedTokensForString:(NSString *)text
                                 pattern:(NSString *)pattern
                                    emit:(QLCCEmitBlock)emit {
    NSRegularExpression *regex = [self interpolationRegexForPattern:pattern];
    if (!regex) {
        emit(text, QLCCTokenString);
        return;
    }

    __block NSUInteger cursor = 0;
    const NSRange wholeRange = NSMakeRange(0, text.length);

    [regex enumerateMatchesInString:text
                            options:0
                              range:wholeRange
                         usingBlock:^(NSTextCheckingResult *m,
                                      NSMatchingFlags flags, BOOL *stop) {
        if (m.range.location > cursor) {
            emit([text substringWithRange:
                      NSMakeRange(cursor, m.range.location - cursor)],
                 QLCCTokenString);
        }
        emit([text substringWithRange:m.range], QLCCTokenVariable);
        cursor = m.range.location + m.range.length;
    }];

    if (cursor < text.length) {
        emit([text substringFromIndex:cursor], QLCCTokenString);
    }
}

/// Class-level cache of compiled master and interpolation regexes. The
/// patterns depend only on the static per-language configs (built once by
/// +languageConfig:), never on theme or user settings, so one cache can
/// be shared across all instances — and therefore across previews, since
/// the provider builds a fresh QLCCHighlighter per request (which used to
/// mean recompiling the language's ICU regex for every preview). NSCache
/// is thread-safe; the count limit bounds the cache to roughly the number
/// of built-in languages plus their interpolation patterns.
+ (NSCache<NSString *, NSRegularExpression *> *)sharedRegexCache {
    static NSCache<NSString *, NSRegularExpression *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    return cache;
}

/// Build (and cache) the master regular expression for a language config.
- (NSRegularExpression *)cachedRegexForConfig:(NSDictionary *)cfg
                                     language:(NSString *)language {
    NSString *cacheKey = language ?: @"text";
    NSRegularExpression *cached = [[QLCCHighlighter sharedRegexCache] objectForKey:cacheKey];
    if (cached) return cached;

    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    NSMutableArray<NSNumber *> *kinds = [NSMutableArray array];

    // 1. Comments (highest precedence — keywords inside comments must not
    //    be coloured).
    NSMutableArray<NSString *> *commentParts = [NSMutableArray array];
    for (NSString *p in cfg[@"blockComments"]) [commentParts addObject:p];
    for (NSString *p in cfg[@"lineComments"]) [commentParts addObject:p];
    if (commentParts.count > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)",
                           [commentParts componentsJoinedByString:@"|"]]];
        [kinds addObject:@(QLCCTokenComment)];
    }

    // 2. Strings.
    NSArray<NSString *> *stringParts = cfg[@"strings"];
    if (stringParts.count > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)",
                           [stringParts componentsJoinedByString:@"|"]]];
        [kinds addObject:@(QLCCTokenString)];
    }

    // 2b. Variables (e.g. PHP's $foo). Distinct from the strings/numbers/
    //     keywords already handled — these languages have no ambiguity
    //     with the '$' sigil, so this is safe to add unconditionally
    //     wherever a language config opts in.
    NSString *variablePattern = cfg[@"variablePattern"];
    if (variablePattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", variablePattern]];
        [kinds addObject:@(QLCCTokenVariable)];
    }

    // 3. Key names in "key: value" / "key = value" style formats (YAML,
    //    TOML, INI). These languages have no reserved words, so without
    //    this the key and its unquoted, non-numeric value render as
    //    identical plain text — only quoted strings and numbers stood out.
    //    Reuses the keyword colour slot to visually separate keys from
    //    values, matching how most editors distinguish the two.
    NSString *keyPattern = cfg[@"keyPattern"];
    if (keyPattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", keyPattern]];
        [kinds addObject:@(QLCCTokenKeyword)];
    }

    // 4. Boolean / null literals (YAML, TOML, INI). Listed before the
    //    generic number/value pieces below so e.g. "true" and "42" keep
    //    their own distinct colour instead of being absorbed into the
    //    generic unquoted-value colour. Reuses the preproc colour slot,
    //    which these languages otherwise never use.
    NSString *booleanPattern = cfg[@"booleanPattern"];
    if (booleanPattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", booleanPattern]];
        [kinds addObject:@(QLCCTokenPreproc)];
    }

    // 5. Preprocessor lines (C-family).
    if ([cfg[@"preproc"] boolValue]) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", kPatCPreproc]];
        [kinds addObject:@(QLCCTokenPreproc)];
    }

    // 6. Numbers.
    [pieces addObject:[NSString stringWithFormat:@"(%@)", kPatNumber]];
    [kinds addObject:@(QLCCTokenNumber)];

    // 7. Generic unquoted values (YAML, INI) — bare words that aren't a
    //    number or boolean/null (those already claimed above). Coloured
    //    with the *string* slot so quoted and unquoted values read as the
    //    same colour, only comments/keys/numbers/booleans stand apart.
    NSString *valuePattern = cfg[@"valuePattern"];
    if (valuePattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", valuePattern]];
        [kinds addObject:@(QLCCTokenString)];
    }

    // 8. Keywords.
    NSArray<NSString *> *keywords = cfg[@"keywords"];
    if (keywords.count > 0) {
        // Longest-first: a plain "\b...\b"-style alternation tries
        // alternatives in listed order and stops at the first match, so a
        // short keyword that's a literal prefix of a longer one (e.g. CSS's
        // "border" vs "border-radius" — "-" is a non-word char, so "\b"
        // fires right between them) would otherwise win and leave the rest
        // of the longer keyword uncoloured. Sorting longest-first makes the
        // more specific keyword win instead.
        NSArray<NSString *> *sortedKeywords =
            [keywords sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                if (a.length != b.length) {
                    return a.length > b.length ? NSOrderedAscending : NSOrderedDescending;
                }
                return NSOrderedSame;
            }];
        NSMutableArray<NSString *> *escaped = [NSMutableArray arrayWithCapacity:sortedKeywords.count];
        for (NSString *kw in sortedKeywords) {
            [escaped addObject:[NSRegularExpression escapedPatternForString:kw]];
        }
        // "\b" only fires at a transition between a word char and a
        // non-word char — so a keyword that itself STARTS or ENDS with a
        // non-word character (CSS's "@media", "-webkit-foo"; Ruby/Crystal's
        // "defined?", "is_a?") can never satisfy a "\b" placed right next to
        // that character, since both sides of the boundary are non-word.
        // "(?<![A-Za-z0-9_-])"/"(?![A-Za-z0-9_-])" assert what we actually
        // mean — "not immediately adjacent to an identifier character" —
        // and behave identically to "\b" for ordinary alphanumeric
        // keywords, so this is a pure bugfix, not a behaviour change, for
        // every keyword that doesn't start/end with "@"/"-"/"?"/etc.
        // "-" is deliberately included alongside [A-Za-z0-9_]: CSS
        // (and any kebab-case identifier) uses "-" as a name-joining
        // character, so without this a value keyword like "right"/"center"
        // would wrongly match inside a class name like ".column-right" or
        // ".right-column" — "-" is a non-word character, so plain "\b"
        // (and the character class without the "-") would treat that as a
        // legitimate boundary even though it very clearly isn't one here.
        [pieces addObject:[NSString stringWithFormat:@"(?<![A-Za-z0-9_-])(%@)(?![A-Za-z0-9_-])",
                           [escaped componentsJoinedByString:@"|"]]];
        [kinds addObject:@(QLCCTokenKeyword)];
    }

    // 8b. Extra keyword-coloured PATTERN (as opposed to a literal-string
    //     list) for open-ended families no fixed list could cover, e.g.
    //     CSS's "-webkit-*"/"-moz-*"/... vendor-prefixed properties. Same
    //     identifier-boundary guard as the keywords piece above.
    NSString *extraKeywordPattern = cfg[@"extraKeywordPattern"];
    if (extraKeywordPattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(?<![A-Za-z0-9_-])(%@)(?![A-Za-z0-9_-])",
                           extraKeywordPattern]];
        [kinds addObject:@(QLCCTokenKeyword)];
    }

    // 9. Function-call and PascalCase type/class names (e.g. PHP). Must be
    //    listed AFTER keywords above — otherwise a reserved word used with
    //    parens, like "if (", would be claimed here instead of coloured as
    //    a keyword. Reuses the preproc colour slot (unused by languages
    //    that opt into this) rather than adding yet another theme role.
    NSString *typeOrCallPattern = cfg[@"typeOrCallPattern"];
    if (typeOrCallPattern.length > 0) {
        [pieces addObject:[NSString stringWithFormat:@"(%@)", typeOrCallPattern]];
        [kinds addObject:@(QLCCTokenPreproc)];
    }

    if (pieces.count == 0) {
        return nil; // nothing to highlight (e.g. plain text)
    }

    // Stash the kind order so we can identify which group matched.
    NSString *pattern = [pieces componentsJoinedByString:@"|"];
    NSError *err = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:NSRegularExpressionAnchorsMatchLines
                                                    error:&err];
    if (err) {
        QLCCLog(@"Failed to compile regex for %@: %@", language, err.localizedDescription);
        return nil;
    }

#if DEBUG
    // Invariant: every piece above contributes exactly one
    // capturing group, so the kind-count must equal the regex's capture-group
    // count. A mismatch silently mis-maps group index -> token kind in
    // kindOfMatch: — this exact mistake has broken ALL highlighting for a
    // language twice before. Fires in Debug builds (which includes this
    // self-test build), turning the next stray capturing group into an
    // immediate abort instead of a silent partial-colour regression.
    NSCAssert(kinds.count == regex.numberOfCaptureGroups,
              @"%@: tokenizer kind-count (%lu) != regex capture groups (%lu); "
              @"each piece must contribute exactly one capturing group",
              language ?: @"text",
              (unsigned long)kinds.count,
              (unsigned long)regex.numberOfCaptureGroups);
#endif

    // Attach the kind array to the regex via a wrapper object in the cache.
    // NSRegularExpression has no userInfo, so we remember the mapping in a
    // parallel cache keyed identically.
    objc_setAssociatedObject(regex, &kKindOrderKey, [kinds copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [[QLCCHighlighter sharedRegexCache] setObject:regex forKey:cacheKey];
    return regex;
}

static char kKindOrderKey;

/// Map the group that matched in `regex` back to its `QLCCTokenKind`.
///
/// Invariant: this MUST only be called with a *master* regex
/// produced by `cachedRegexForConfig:` — that is the only place the parallel
/// `kinds` array is attached (via `objc_setAssociatedObject` below). The
/// same shared regex cache also holds interpolation regexes (under `interp:`
/// keys) which carry NO associated kinds; passing one of those here would
/// silently read `nil` and fall back to `QLCCTokenDefault`.
///
/// NSCache can evict entries under memory pressure — that is safe here: the
/// caller (the master-regex emitter) holds a strong reference to the returned regex
/// for the whole pass, so both the regex and its attached `kinds` array stay
/// alive until tokenisation finishes, even if the cache drops its own entry.
/// A post-eviction re-lookup simply rebuilds and re-attaches.
+ (QLCCTokenKind)kindOfMatch:(NSTextCheckingResult *)m
                   inRegex:(NSRegularExpression *)regex {
    NSArray<NSNumber *> *kinds = objc_getAssociatedObject(regex, &kKindOrderKey);
    for (NSUInteger i = 0; i < kinds.count; i++) {
        NSRange r = [m rangeAtIndex:(i + 1)]; // groups are 1-based
        if (r.location != NSNotFound && r.length > 0) {
            return (QLCCTokenKind)[kinds[i] integerValue];
        }
    }
    return QLCCTokenDefault;
}

#pragma mark - Rendering

/// CSS colour for a token kind in the current theme, or nil for default text.
- (nullable NSString *)colorForKind:(QLCCTokenKind)kind {
    switch (kind) {
        case QLCCTokenComment: return self.theme.commentColor;
        case QLCCTokenString:  return self.theme.stringColor;
        case QLCCTokenPreproc: return self.theme.preprocColor;
        case QLCCTokenNumber:  return self.theme.numberColor;
        case QLCCTokenKeyword: return self.theme.keywordColor;
        case QLCCTokenVariable: return self.theme.variableColor;
        case QLCCTokenDefault: return nil;
    }
    return nil;
}

/// Single-letter CSS class for a token kind (see wrapBody:'s stylesheet).
/// Nil for default text, same as colorForKind:.
- (nullable NSString *)classForKind:(QLCCTokenKind)kind {
    switch (kind) {
        case QLCCTokenComment: return @"c";
        case QLCCTokenString:  return @"s";
        case QLCCTokenPreproc: return @"p";
        case QLCCTokenNumber:  return @"n";
        case QLCCTokenKeyword: return @"k";
        case QLCCTokenVariable: return @"v";
        case QLCCTokenDefault: return nil;
    }
    return nil;
}

/// HTML-escape a string for safe inclusion inside a <pre>/<span>.
///
/// Bulk scan-and-copy: strings containing none of `&`, `<`, `>` are
/// returned as-is (no copy — most tokens qualify), and the rest are
/// escaped by appending whole runs between the three specials with
/// CFStringAppendCharacters, expanding only the specials themselves.
/// (A previous per-character appendFormat:"%C" version parsed a format
/// string once per character of the file and measured ~30% of total
/// preview time on a 2 MB source.)
+ (NSString *)htmlEscape:(NSString *)s {
    const NSUInteger len = s.length;
    if (len == 0) return @"";

    enum { kChunk = 1024 };
    unichar buf[kChunk];

    // Fast path: locate the first escapable character, if any.
    NSUInteger first = NSNotFound;
    for (NSUInteger off = 0; off < len && first == NSNotFound; off += kChunk) {
        const NSUInteger n = MIN(kChunk, len - off);
        CFStringGetCharacters((CFStringRef)s,
                              CFRangeMake((CFIndex)off, (CFIndex)n), buf);
        for (NSUInteger i = 0; i < n; i++) {
            const unichar c = buf[i];
            if (c == '&' || c == '<' || c == '>') {
                first = off + i;
                break;
            }
        }
    }
    if (first == NSNotFound) return s;  // immutable; nothing to escape

    NSMutableString *out =
        [NSMutableString stringWithCapacity:len + (len >> 3) + 8];
    if (first > 0) [out appendString:[s substringToIndex:first]];

    for (NSUInteger idx = first; idx < len; ) {
        const NSUInteger n = MIN(kChunk, len - idx);
        CFStringGetCharacters((CFStringRef)s,
                              CFRangeMake((CFIndex)idx, (CFIndex)n), buf);
        NSUInteger run = 0;
        for (NSUInteger i = 0; i < n; i++) {
            const unichar c = buf[i];
            if (c != '&' && c != '<' && c != '>') continue;
            if (i > run) {
                CFStringAppendCharacters((CFMutableStringRef)out,
                                         buf + run, (CFIndex)(i - run));
            }
            switch (c) {
                case '&': [out appendString:@"&amp;"]; break;
                case '<': [out appendString:@"&lt;"];  break;
                case '>': [out appendString:@"&gt;"];  break;
            }
            run = i + 1;
        }
        if (n > run) {
            CFStringAppendCharacters((CFMutableStringRef)out,
                                     buf + run, (CFIndex)(n - run));
        }
        idx += n;
    }
    return out;
}

- (NSString *)renderPlainPreWithSource:(NSString *)source
                              language:(NSString *)language
                                config:(NSDictionary *)cfg {
    // Adjacent same-kind tokens share one span, and colours come from the
    // per-kind classes defined in wrapBody:'s stylesheet. Tokens stream in
    // straight from the tokenizer (no segments array); the capacity hint
    // avoids geometric regrowth of a several-MB body.
    NSMutableString *body =
        [NSMutableString stringWithCapacity:source.length + (source.length >> 3) + 32];
    [body appendString:@"<pre class=\"code\">"];
    __block NSString *openClass = nil;
    [self emitTokensForSource:source language:language config:cfg
                         emit:^(NSString *text, QLCCTokenKind kind) {
        NSString *cls = [self classForKind:kind];
        if (cls) {
            if (![openClass isEqualToString:cls]) {
                if (openClass) [body appendString:@"</span>"];
                [body appendFormat:@"<span class=%@>", cls];
                openClass = cls;
            }
        } else if (openClass) {
            [body appendString:@"</span>"];
            openClass = nil;
        }
        [body appendString:[QLCCHighlighter htmlEscape:text]];
    }];
    if (openClass) [body appendString:@"</span>"];
    [body appendString:@"</pre>"];
    return body;
}

- (NSString *)renderLineNumbersTableWithSource:(NSString *)source
                                      language:(NSString *)language
                                        config:(NSDictionary *)cfg {
    NSMutableString *body =
        [NSMutableString stringWithCapacity:source.length + (source.length >> 2) + 256];
    [body appendString:@"<table class=\"code\"><tbody>"];
    __block NSUInteger lineNo = 1;
    __block NSString *openClass = nil;

    void (^closeSpan)(void) = ^{
        if (openClass) {
            [body appendString:@"</span>"];
            openClass = nil;
        }
    };
    void (^openSpan)(NSString *) = ^(NSString *cls) {
        if (!openClass || ![openClass isEqualToString:cls]) {
            closeSpan();
            if (cls) {
                [body appendFormat:@"<span class=%@>", cls];
                openClass = cls;
            }
        }
    };
    void (^startRow)(void) = ^{
        [body appendFormat:@"<tr><td class=\"ln\">%lu</td><td class=\"lc\">",
                            (unsigned long)lineNo];
    };

    startRow();
    [self emitTokensForSource:source language:language config:cfg
                         emit:^(NSString *text, QLCCTokenKind kind) {
        NSString *cls = [self classForKind:kind];
        NSString *escaped = [QLCCHighlighter htmlEscape:text];
        NSArray<NSString *> *parts = [escaped componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i < parts.count; i++) {
            if (i > 0) {
                closeSpan();
                [body appendString:@"</td></tr>"];
                lineNo++;
                startRow();
            }
            NSString *part = parts[i];
            if (part.length == 0) continue;
            if (cls) {
                openSpan(cls);
            } else {
                closeSpan();
            }
            [body appendString:part];
        }
    }];
    closeSpan();
    [body appendString:@"</td></tr></tbody></table>"];
    return body;
}

#pragma mark - HTML document

- (NSString *)wrapBody:(NSString *)body {
    NSString *whiteSpace =
        self.config.wrapLines ? @"pre-wrap" : @"pre";
    NSString *font = [QLCCHighlighter cssFontFamily:self.config.font];
    NSUInteger tab = MAX((NSUInteger)1, self.config.tabWidth);

    // One CSS rule per token kind so the renderers can emit a short
    // class=k attribute instead of a style attribute on every token.
    NSMutableString *tokenCSS = [NSMutableString stringWithCapacity:112];
    for (NSInteger kind = QLCCTokenComment; kind <= QLCCTokenVariable; kind++) {
        NSString *color = [self colorForKind:kind];
        if (color) {
            [tokenCSS appendFormat:@".%@{color:%@}",
                              [self classForKind:kind], color];
        }
    }

    return [NSString stringWithFormat:
        @"<!DOCTYPE html>\n"
        @"<html><head><meta charset=\"UTF-8\">"
        @"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        @"<style>\n"
        @"html, body { margin:0; padding:0; background:%@; }\n"
        @"body { color:%@; padding:16px 20px; "
        @"  -webkit-font-smoothing:antialiased; }\n"
        @"pre.code, table.code {\n"
        @"  font-family:%@;\n"
        @"  font-size:%.1fpt;\n"
        @"  line-height:1.5;\n"
        @"  tab-size:%lu; -moz-tab-size:%lu;\n"
        @"  margin:0;\n"
        @"  white-space:%@;\n"
        @"  word-break:normal;\n"
        @"}\n"
        @"table.code { border-collapse:collapse; width:100%%; }\n"
        @"table.code td { vertical-align:top; padding:0; "
        @"  white-space:%@; }\n"
        @"table.code td.ln { user-select:none; -webkit-user-select:none; "
        @"  text-align:right; padding-right:%.0fpx; color:%@; "
        @"  white-space:pre; opacity:0.65; }\n"
        @"table.code td.lc { width:100%%; }\n"
        @"%@\n"
        @"</style></head><body>%@</body></html>",
        self.theme.canvasColor, self.theme.defaultColor,
        font, (double)self.config.fontSize,
        (unsigned long)tab, (unsigned long)tab, whiteSpace,
        whiteSpace, (double)self.config.lineNumberGutterWidth,
        self.theme.lineNumberColor, tokenCSS, body];
}

/// Quote a font family for use in CSS, accounting for multi-word names.
+ (NSString *)cssFontFamily:(NSString *)font {
    NSString *f = [font stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
    if (f.length == 0) f = @"Menlo";
    // Build a CSS font stack. Each entry is escaped + conditionally quoted by
    // cssQuotedFamilyName: so the (free-typed, user-controlled) font value
    // can't break out of the CSS string or the surrounding <style> block.
    NSArray<NSString *> *names = @[
        f, @"SF Mono", @"Menlo", @"Monaco", @"Consolas",
        @"Liberation Mono", @"Courier New", @"monospace"
    ];
    NSMutableArray<NSString *> *quoted = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        [quoted addObject:[QLCCHighlighter cssQuotedFamilyName:name]];
    }
    return [quoted componentsJoinedByString:@", "];
}

/// Escape + quote a single CSS font-family name for safe embedding inside
/// the HTML `<style>` block emitted by `wrapBody:`. The user's font value
/// arrives raw from an editable combo box (`PreferencesViewController`'s
/// `fontField`) and is interpolated into `font-family:%@;`, so without this:
///   - a `"` or `\` breaks out of the CSS string, and
///   - a `</style>` even breaks out into the HTML body (the `<style>`
///     element is raw-text, so the HTML parser scans for `</style>` and
///     doesn't care that it's "inside" a CSS string).
/// Quick Look disables JavaScript in HTML previews, so this is a
/// self-inflicted broken-preview / markup-injection vector, not script
/// execution — but it still ruins every preview until the bad value is
/// cleared. We CSS-escape `\` and `"` and strip `<`/`>` (font names never
/// legitimately contain them), then quote anything that isn't a bare CSS
/// identifier.
+ (NSString *)cssQuotedFamilyName:(NSString *)name {
    NSMutableString *s = [NSMutableString stringWithString:name ?: @""];
    [s replaceOccurrencesOfString:@"\\" withString:@"\\\\"
                          options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\"" withString:@"\\\""
                          options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"<" withString:@""
                          options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@">" withString:@""
                          options:0 range:NSMakeRange(0, s.length)];
    NSCharacterSet *bare =
        [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    BOOL isBare = s.length > 0
        && [[s stringByTrimmingCharactersInSet:bare] length] == 0;
    return isBare ? s : [NSString stringWithFormat:@"\"%@\"", s];
}

@end

#pragma mark - NSDictionary helper

@implementation NSDictionary (QLCCMerge)
- (NSDictionary *)mtl_setValue:(id)value forKey:(NSString *)key {
    NSMutableDictionary *m = [self mutableCopy];
    m[key] = value;
    return [m copy];
}
@end
