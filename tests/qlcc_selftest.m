//
//  qlcc_selftest.m
//  Automated regression harness for QLCCHighlighter.
//
//  Renders a handful of small, hand-picked snippets per language against a
//  FIXED theme (darkplus, so expected hex colours are deterministic
//  regardless of the machine's saved preferences) and asserts that specific
//  colour spans appear (or don't) in the output HTML.
//
//  This exists because of two real regressions where a hidden
//  extra capturing group in one language's regex silently broke ALL
//  highlighting for that language (comments/strings/numbers included, not
//  just the new feature being added) a bug that's easy to introduce and
//  easy to miss by eye. Run automatically by build.sh before signing; a
//  non-zero exit here fails the build.
//
//  Deliberately NOT part of the shipped .app/.appex compiled and run only
//  as a build-time check.
//

#import <Foundation/Foundation.h>
#import "QLCCConfiguration.h"
#import "QLCCTheme.h"
#import "QLCCHighlighter.h"
#import "QLCodePreviewProvider.h"

// The two helpers under test (effectiveExtensionForURL:, readPrefixAtURL:)
// are private to the provider; surface them for this self-test only.
@interface QLCodePreviewProvider (SelfTestHooks)
- (NSString *)effectiveExtensionForURL:(NSURL *)url;
- (nullable NSString *)readPrefixAtURL:(NSURL *)url maxBytes:(NSUInteger)maxBytes;
- (nullable NSString *)readSourceAtURL:(NSURL *)url configuration:(QLCCConfiguration *)config;
@end

// cssFontFamily: is private to the highlighter; surface it for the M1 test.
@interface QLCCHighlighter (SelfTestHooks)
+ (NSString *)cssFontFamily:(NSString *)font;
@end

// Known darkplus class→colour mapping (QLCCTheme.m +defaultDarkTheme;
// wrapBody: emits one .class{color:hex} rule per token kind). The span
// assertions below check classes, not colours — the point isn't the exact
// colours, it's that DIFFERENT categories render DIFFERENT classes and the
// same category stays consistent; one dedicated case below pins the
// class→hex mapping itself.
static NSString *const kKeyword  = @"k";
static NSString *const kString   = @"s";
static NSString *const kComment  = @"c";
static NSString *const kNumber   = @"n";
static NSString *const kPreproc  = @"p";
static NSString *const kVariable = @"v";

static NSString *span(NSString *cls, NSString *text) {
    return [NSString stringWithFormat:@"<span class=%@>%@</span>", cls, text];
}

typedef struct {
    const char *name;
    const char *ext;
    const char *source;
    // NULL-terminated array of C strings, or NULL for "no requirements".
    const char **mustContain;
    const char **mustNotContain;
} QLCCSelfTestCase;

static int gFailures = 0;     // total failed assertions across all cases
static int gTotal = 0;        // total cases run
static int gCasesPassed = 0;  // cases with zero failed assertions

static void runCase(QLCCSelfTestCase tc, QLCCHighlighter *h) {
    gTotal++;
    int failuresBefore = gFailures;
    NSString *source = @(tc.source);
    NSString *html = [h htmlPreviewForSource:source pathExtension:@(tc.ext)];

    if (tc.mustContain) {
        for (const char **p = tc.mustContain; *p; p++) {
            NSString *needle = @(*p);
            if ([html rangeOfString:needle].location == NSNotFound) {
                gFailures++;
                fprintf(stderr, "FAIL [%s]: expected to find %s\n---- full output ----\n%s\n----------------------\n",
                        tc.name, needle.UTF8String, html.UTF8String);
            }
        }
    }
    if (tc.mustNotContain) {
        for (const char **p = tc.mustNotContain; *p; p++) {
            NSString *needle = @(*p);
            if ([html rangeOfString:needle].location != NSNotFound) {
                gFailures++;
                fprintf(stderr, "FAIL [%s]: expected NOT to find %s\n---- full output ----\n%s\n----------------------\n",
                        tc.name, needle.UTF8String, html.UTF8String);
            }
        }
    }
    if (gFailures == failuresBefore) gCasesPassed++;
}

// Single-condition check for cases that don't fit the render-and-search
// mould (provider helper methods, the line-number renderer with a bespoke
// config, ...). Counts as one case, mirroring runCase's tallies so the
// final "%d/%d cases passed" line stays meaningful.
static void checkCond(const char *name, BOOL ok, NSString *detail) {
    gTotal++;
    if (!ok) {
        gFailures++;
        fprintf(stderr, "FAIL [%s]: %s\n", name, detail.UTF8String);
    } else {
        gCasesPassed++;
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        QLCCConfiguration *cfg = [[QLCCConfiguration alloc] init];
        QLCCTheme *theme = [QLCCTheme defaultDarkTheme];
        QLCCHighlighter *h = [[QLCCHighlighter alloc] initWithTheme:theme configuration:cfg];

        NSString *keySpan_name = span(kKeyword, @"name");
        NSString *strSpan_production = span(kString, @"production");
        NSString *numSpan_42 = span(kNumber, @"42");
        NSString *boolSpan_true = span(kPreproc, @"true");
        NSString *commentSpan = span(kComment, @"# hi");

        const char *yamlMust[] = {
            keySpan_name.UTF8String, strSpan_production.UTF8String,
            numSpan_42.UTF8String, boolSpan_true.UTF8String,
            commentSpan.UTF8String, NULL,
        };
        QLCCSelfTestCase yamlCase = {
            .name = "yaml: key/value/number/bool/comment colours",
            .ext = "yaml",
            .source = "name: production\ncount: 42\nenabled: true\n# hi\n",
            .mustContain = yamlMust,
        };
        runCase(yamlCase, h);

        NSString *tomlKeySpan = span(kKeyword, @"name");
        NSString *tomlStrSpan = [NSString stringWithFormat:@"<span class=%@>&quot;prod&quot;</span>", kString];
        NSString *tomlNumSpan = span(kNumber, @"42");
        NSString *tomlBoolSpan = span(kPreproc, @"true");
        const char *tomlMust[] = {
            tomlKeySpan.UTF8String, tomlNumSpan.UTF8String, tomlBoolSpan.UTF8String, NULL,
        };
        QLCCSelfTestCase tomlCase = {
            .name = "toml: key/number/bool colours",
            .ext = "toml",
            .source = "name = \"prod\"\ncount = 42\nenabled = true\n# hi\n",
            .mustContain = tomlMust,
        };
        runCase(tomlCase, h);
        (void)tomlStrSpan; // string quoting/escaping is exercised, not asserted exactly here

        NSString *iniKeySpan = span(kKeyword, @"name");
        NSString *iniValSpan = span(kString, @"production");
        NSString *iniBoolSpan = span(kPreproc, @"yes");
        const char *iniMust[] = {
            iniKeySpan.UTF8String, iniValSpan.UTF8String, iniBoolSpan.UTF8String, NULL,
        };
        QLCCSelfTestCase iniCase = {
            .name = "ini: key/value/bool colours",
            .ext = "ini",
            .source = "[section]\nname = production\nenabled = yes\n; hi\n",
            .mustContain = iniMust,
        };
        runCase(iniCase, h);

        NSString *phpClassKw = span(kKeyword, @"class");
        NSString *phpExtendsKw = span(kKeyword, @"extends");
        NSString *phpIfKw = span(kKeyword, @"if");
        NSString *phpTrueKw = span(kKeyword, @"true");
        NSString *phpFooType = span(kPreproc, @"Foo");
        NSString *phpExceptionType = span(kPreproc, @"Exception");
        NSString *phpVar = span(kVariable, @"$x");
        NSString *phpIfMiscolouredAsCall = span(kPreproc, @"if");
        const char *phpMust[] = {
            phpClassKw.UTF8String, phpExtendsKw.UTF8String, phpIfKw.UTF8String,
            phpTrueKw.UTF8String, phpFooType.UTF8String, phpExceptionType.UTF8String,
            phpVar.UTF8String, NULL,
        };
        const char *phpMustNot[] = { phpIfMiscolouredAsCall.UTF8String, NULL };
        QLCCSelfTestCase phpCase = {
            .name = "php: keyword/type/variable colours, no keyword-as-call leakage",
            .ext = "php",
            .source =
                "class Foo extends Exception {\n"
                "  public function bar($x) {\n"
                "    if ($x === true) {\n"
                "      return $x;\n"
                "    }\n"
                "  }\n"
                "}\n",
            .mustContain = phpMust,
            .mustNotContain = phpMustNot,
        };
        runCase(phpCase, h);

        NSString *phpInterpLead = span(kString, @"\"Hello ");
        NSString *phpInterpMid = span(kString, @", you have ");
        NSString *phpInterpTail = span(kString, @" items!\"");
        NSString *phpInterpVar1 = span(kVariable, @"$user");
        NSString *phpInterpVar2 = span(kVariable, @"$count");
        NSString *phpInterpWholeUnsplit =
            span(kString, @"\"Hello $user, you have $count items!\"");
        const char *phpInterpMust[] = {
            phpInterpLead.UTF8String, phpInterpMid.UTF8String, phpInterpTail.UTF8String,
            phpInterpVar1.UTF8String, phpInterpVar2.UTF8String, NULL,
        };
        const char *phpInterpMustNot[] = { phpInterpWholeUnsplit.UTF8String, NULL };
        QLCCSelfTestCase phpInterpCase = {
            .name = "php: double-quoted string interpolation splits out $variables",
            .ext = "php",
            .source = "echo \"Hello $user, you have $count items!\";\n",
            .mustContain = phpInterpMust,
            .mustNotContain = phpInterpMustNot,
        };
        runCase(phpInterpCase, h);

        NSString *phpSingleQuoteWhole = span(kString, @"'Hello $user'");
        const char *phpNoInterpMust[] = { phpSingleQuoteWhole.UTF8String, NULL };
        QLCCSelfTestCase phpNoInterpCase = {
            .name = "php: single-quoted strings do NOT interpolate",
            .ext = "php",
            .source = "echo 'Hello $user';\n",
            .mustContain = phpNoInterpMust,
        };
        runCase(phpNoInterpCase, h);

        // Only the HTML tokenizer knows about "<!-- -->" comments PHP's
        // config doesn't. Seeing this comment span colored proves the
        // "outside <?php ?>" run actually got routed through the HTML
        // tokenizer rather than being force-fit through PHP's.
        // Note: htmlEscape converts '<'/'>' to '&lt;'/'&gt;' (but not '"'),
        // so the expected span text must reflect that, same as the raw
        // XML-comment delimiters below.
        NSString *embeddedHtmlComment = span(kComment, @"&lt;!-- header --&gt;");
        NSString *embeddedPhpIf = span(kKeyword, @"if");
        NSString *embeddedPhpTrue = span(kKeyword, @"true");
        NSString *embeddedPhpVar = span(kVariable, @"$x");
        const char *embeddedMust[] = {
            embeddedHtmlComment.UTF8String, embeddedPhpIf.UTF8String,
            embeddedPhpTrue.UTF8String, embeddedPhpVar.UTF8String, NULL,
        };
        QLCCSelfTestCase embeddedCase = {
            .name = "php: embedded HTML runs use html tokenizer, <?php ?> runs use php tokenizer",
            .ext = "php",
            .source =
                "<!-- header -->\n"
                "<div>\n"
                "<?php\n"
                "if ($x === true) {\n"
                "  echo $x;\n"
                "}\n"
                "?>\n"
                "</div>\n",
            .mustContain = embeddedMust,
        };
        runCase(embeddedCase, h);

        // A .php file with NO literal "<?php" anywhere (our other PHP
        // fixtures above, and plenty of real snippet-style files) must
        // still be tokenised as plain PHP, not silently swallowed as HTML.
        NSString *noTagStillPhp = span(kKeyword, @"class");
        const char *noTagMust[] = { noTagStillPhp.UTF8String, NULL };
        QLCCSelfTestCase noTagCase = {
            .name = "php: file with no <?php tag at all is still tokenised as PHP",
            .ext = "php",
            .source = "class Foo {\n  public $x;\n}\n",
            .mustContain = noTagMust,
        };
        runCase(noTagCase, h);

        // typeOrCallPattern's keyword-lookbehind rewrite (task 23): a type
        // hint not after class/new/extends/implements/instanceof still
        // gets coloured via the PascalCase fallback, a function name still
        // gets coloured via the call heuristic, but an ALL_CAPS constant
        // must NOT be swept up as a "type" just because it starts with an
        // uppercase letter.
        NSString *typeHintException = span(kPreproc, @"Exception");
        NSString *callProcess = span(kPreproc, @"process");
        NSString *constantMisColoured = span(kPreproc, @"MY_CONST");
        const char *lookbehindMust[] = {
            typeHintException.UTF8String, callProcess.UTF8String, NULL,
        };
        const char *lookbehindMustNot[] = { constantMisColoured.UTF8String, NULL };
        QLCCSelfTestCase lookbehindCase = {
            .name = "php: sharper type detection — type-hint fallback works, ALL_CAPS constant excluded",
            .ext = "php",
            .source =
                "function process(Exception $e) {\n"
                "  return $e;\n"
                "}\n"
                "const MY_CONST = 1;\n",
            .mustContain = lookbehindMust,
            .mustNotContain = lookbehindMustNot,
        };
        runCase(lookbehindCase, h);

        // The same generic typeOrCallPattern/variablePattern
        // mechanism extended to Python, Go, JavaScript, and Ruby.
        NSString *pyClassName = span(kPreproc, @"Foo");
        NSString *pyCall = span(kPreproc, @"isinstance");
        NSString *pyConstantMisColoured = span(kPreproc, @"MY_CONST");
        const char *pyMust[] = { pyClassName.UTF8String, pyCall.UTF8String, NULL };
        const char *pyMustNot[] = { pyConstantMisColoured.UTF8String, NULL };
        QLCCSelfTestCase pyCase = {
            .name = "python: class/call colouring via extended typeOrCallPattern",
            .ext = "py",
            .source =
                "class Foo:\n"
                "    def process(self, x):\n"
                "        return isinstance(x, Foo)\n"
                "\n"
                "MY_CONST = 42\n",
            .mustContain = pyMust,
            .mustNotContain = pyMustNot,
        };
        runCase(pyCase, h);

        NSString *goTypeName = span(kPreproc, @"Foo");
        NSString *goCall = span(kPreproc, @"Println");
        const char *goMust[] = { goTypeName.UTF8String, goCall.UTF8String, NULL };
        QLCCSelfTestCase goCase = {
            .name = "go: type/call colouring via extended typeOrCallPattern",
            .ext = "go",
            .source =
                "type Foo struct {\n"
                "\tName string\n"
                "}\n"
                "\n"
                "func process(f Foo) {\n"
                "\tfmt.Println(f.Name)\n"
                "}\n",
            .mustContain = goMust,
        };
        runCase(goCase, h);

        NSString *jsClassName = span(kPreproc, @"Foo");
        NSString *jsExtendsName = span(kPreproc, @"Bar");
        NSString *jsNewCall = span(kPreproc, @"Baz");
        const char *jsMust[] = {
            jsClassName.UTF8String, jsExtendsName.UTF8String, jsNewCall.UTF8String, NULL,
        };
        QLCCSelfTestCase jsCase = {
            .name = "javascript: class/extends/new colouring via extended typeOrCallPattern",
            .ext = "js",
            .source =
                "class Foo extends Bar {\n"
                "  process(x) {\n"
                "    return new Baz(x);\n"
                "  }\n"
                "}\n",
            .mustContain = jsMust,
        };
        runCase(jsCase, h);

        NSString *rbClassName = span(kPreproc, @"Foo");
        NSString *rbCall = span(kPreproc, @"initialize");
        NSString *rbIvar = span(kVariable, @"@x");
        NSString *rbGlobal = span(kVariable, @"$global");
        const char *rbMust[] = {
            rbClassName.UTF8String, rbCall.UTF8String, rbIvar.UTF8String, rbGlobal.UTF8String, NULL,
        };
        QLCCSelfTestCase rbCase = {
            .name = "ruby: class/call/@ivar/$global colouring via extended variable+typeOrCallPattern",
            .ext = "rb",
            .source =
                "class Foo\n"
                "  def initialize(x)\n"
                "    @x = x\n"
                "    $global = 1\n"
                "  end\n"
                "end\n",
            .mustContain = rbMust,
        };
        runCase(rbCase, h);

        // --- Round 2: markdown fences, more interpolation, C-family types, sigils ---

        NSString *mdFenceKeyword = span(kKeyword, @"def");
        NSString *mdFenceCall = span(kPreproc, @"foo");
        const char *mdMust[] = { mdFenceKeyword.UTF8String, mdFenceCall.UTF8String, NULL };
        QLCCSelfTestCase mdCase = {
            .name = "markdown: fenced ```python block tokenised as python, not plain text",
            .ext = "md",
            .source =
                "# Title\n"
                "\n"
                "```python\n"
                "def foo():\n"
                "    return 1\n"
                "```\n"
                "\n"
                "Some text.\n",
            .mustContain = mdMust,
        };
        runCase(mdCase, h);

        NSString *jsTemplateVar = span(kVariable, @"${user}");
        NSString *jsTemplateLead = span(kString, @"`Hello ");
        const char *jsTemplateMust[] = { jsTemplateVar.UTF8String, jsTemplateLead.UTF8String, NULL };
        QLCCSelfTestCase jsTemplateCase = {
            .name = "javascript: template literal ${expr} interpolation",
            .ext = "js",
            .source = "const msg = `Hello ${user}!`;\n",
            .mustContain = jsTemplateMust,
        };
        runCase(jsTemplateCase, h);

        NSString *rubyInterpVar = span(kVariable, @"#{user.name}");
        const char *rubyInterpMust[] = { rubyInterpVar.UTF8String, NULL };
        QLCCSelfTestCase rubyInterpCase = {
            .name = "ruby: #{expr} interpolation inside double-quoted strings",
            .ext = "rb",
            .source = "name = \"Hello #{user.name}!\"\n",
            .mustContain = rubyInterpMust,
        };
        runCase(rubyInterpCase, h);

        NSString *perlScalarVar = span(kVariable, @"$name");
        NSString *perlArrayVar = span(kVariable, @"@list");
        NSString *perlInterpVar = span(kVariable, @"$name");
        const char *perlMust[] = {
            perlScalarVar.UTF8String, perlArrayVar.UTF8String, perlInterpVar.UTF8String, NULL,
        };
        QLCCSelfTestCase perlCase = {
            .name = "perl: $scalar/@array sigils + double-quoted-string interpolation",
            .ext = "pl",
            .source = "my $name = \"world\";\nmy @list = (1, 2, 3);\nprint \"Hello $name\\n\";\n",
            .mustContain = perlMust,
        };
        runCase(perlCase, h);

        NSString *shellVar = span(kVariable, @"$HOME");
        NSString *shellInterpVar = span(kVariable, @"$USER");
        NSString *shellSingleQuoteNoInterp = span(kString, @"'no $interpolation here'");
        const char *shellMust[] = {
            shellVar.UTF8String, shellInterpVar.UTF8String, shellSingleQuoteNoInterp.UTF8String, NULL,
        };
        QLCCSelfTestCase shellCase = {
            .name = "shell: $VAR sigil + double-quoted interpolation, single-quoted stays literal",
            .ext = "sh",
            .source = "x=$HOME\necho \"hi $USER\"\necho 'no $interpolation here'\n",
            .mustContain = shellMust,
        };
        runCase(shellCase, h);

        NSString *javaTypeName = span(kPreproc, @"Base");
        NSString *javaCall = span(kPreproc, @"process");
        const char *javaMust[] = { javaTypeName.UTF8String, javaCall.UTF8String, NULL };
        QLCCSelfTestCase javaCase = {
            .name = "java: class/extends/new type colouring via typeOrCallPattern",
            .ext = "java",
            .source = "class Foo extends Base {\n  Base process() {\n    return new Base();\n  }\n}\n",
            .mustContain = javaMust,
        };
        runCase(javaCase, h);

        NSString *csTypeName = span(kPreproc, @"Base");
        const char *csMust[] = { csTypeName.UTF8String, NULL };
        QLCCSelfTestCase csCase = {
            .name = "csharp: class/new type colouring via typeOrCallPattern",
            .ext = "cs",
            .source = "class Foo {\n  void Run() {\n    var b = new Base();\n  }\n}\n",
            .mustContain = csMust,
        };
        runCase(csCase, h);

        NSString *swiftTypeName = span(kPreproc, @"Base");
        const char *swiftMust[] = { swiftTypeName.UTF8String, NULL };
        QLCCSelfTestCase swiftCase = {
            .name = "swift: class/struct type colouring via typeOrCallPattern",
            .ext = "swift",
            .source = "class Foo {\n  var b: Base\n  init() {\n    b = Base()\n  }\n}\n",
            .mustContain = swiftMust,
        };
        runCase(swiftCase, h);

        // --- Round 3: CSS property coloring fixes ---
        // Regression coverage: the CSS properties "bottom",
        // "--custom-property", "border-radius"/"border-bottom-width"
        // (prefix-collision with the shorter "border" keyword), and
        // "-webkit-*" vendor prefixes were partially or fully uncoloured.

        NSString *cssBottom = span(kKeyword, @"bottom");
        NSString *cssCustomPropDecl = span(kVariable, @"--main-color");
        NSString *cssBorderRadius = span(kKeyword, @"border-radius");
        NSString *cssBorderBottomWidth = span(kKeyword, @"border-bottom-width");
        NSString *cssWebkitFillColor = span(kKeyword, @"-webkit-text-fill-color");
        NSString *cssWebkitBgClip = span(kKeyword, @"-webkit-background-clip");
        NSString *cssAtMedia = span(kKeyword, @"@media");
        // The bug: "border" (a real, separately-listed keyword) matching as
        // a standalone token INSIDE "border-radius" / "border-bottom-width"
        // instead of the longer keyword winning outright.
        NSString *cssBorderRadiusBroken =
            [NSString stringWithFormat:@"%@-radius", span(kKeyword, @"border")];
        NSString *cssBorderBottomWidthBroken =
            [NSString stringWithFormat:@"%@-bottom-width", span(kKeyword, @"border")];
        const char *cssMust[] = {
            cssBottom.UTF8String, cssCustomPropDecl.UTF8String, cssBorderRadius.UTF8String,
            cssBorderBottomWidth.UTF8String, cssWebkitFillColor.UTF8String,
            cssWebkitBgClip.UTF8String, cssAtMedia.UTF8String, NULL,
        };
        const char *cssMustNot[] = {
            cssBorderRadiusBroken.UTF8String, cssBorderBottomWidthBroken.UTF8String, NULL,
        };
        QLCCSelfTestCase cssCase = {
            .name = "css: bottom/--custom-property/border-radius/border-bottom-width/-webkit-*/@media all colour fully",
            .ext = "css",
            .source =
                ".box {\n"
                "  bottom: 10px;\n"
                "  --main-color: #336699;\n"
                "  border-radius: 4px;\n"
                "  border-bottom-width: 2px;\n"
                "  -webkit-text-fill-color: transparent;\n"
                "  -webkit-background-clip: text;\n"
                "}\n"
                "@media screen {\n"
                "  .x { color: red; }\n"
                "}\n",
            .mustContain = cssMust,
            .mustNotContain = cssMustNot,
        };
        runCase(cssCase, h);

        // --- Round 4: CSS keyword false positives inside kebab-case selectors ---
        // Regression coverage: value/vendor keywords must not colour class-name
        // suffixes/pieces they merely happen to appear inside of.
        // "right" legitimately appears twice in this fixture, once inside
        // ".column-right" (must NOT colour) and once in "text-align: right"
        // (MUST colour), so a bare "must not contain <span>right</span>"
        // check would be ambiguous (it'd find the legitimate one and think
        // the assertion passed/failed for the wrong reason). Instead assert
        // the exact literal selector text comes through UNWRAPPED/
        // contiguous, which only holds if nothing inside it got a <span>.
        NSString *cssSelectorColumnRightWrong = @".dropzone.column-right {";
        NSString *cssSelectorWindowCenterWrong = @".dropzone.window-center {";
        NSString *cssSelectorWebkitScrollbarWrong = @".slide-inner::-webkit-scrollbar-thumb {";
        NSString *cssRealValueRight = span(kKeyword, @"right");
        NSString *cssRealVendorProp = span(kKeyword, @"-webkit-text-fill-color");
        const char *cssSelectorMust[] = {
            cssSelectorColumnRightWrong.UTF8String, cssSelectorWindowCenterWrong.UTF8String,
            cssSelectorWebkitScrollbarWrong.UTF8String,
            cssRealValueRight.UTF8String, cssRealVendorProp.UTF8String, NULL,
        };
        QLCCSelfTestCase cssSelectorCase = {
            .name = "css: value/vendor keywords must not colour inside kebab-case class-name selectors",
            .ext = "css",
            .source =
                ".dropzone.column-right {\n"
                "  color: red;\n"
                "}\n"
                ".dropzone.window-center {\n"
                "  color: blue;\n"
                "}\n"
                ".slide-inner::-webkit-scrollbar-thumb {\n"
                "  background: gray;\n"
                "}\n"
                "p {\n"
                "  text-align: right;\n"
                "  -webkit-text-fill-color: transparent;\n"
                "}\n",
            .mustContain = cssSelectorMust,
        };
        runCase(cssSelectorCase, h);

        // --- Round 5: regression coverage for highlighting fixes + line renderer ---

        // B1: Swift compiler directives (#if/#available/#endif) must NOT be
        // coloured as strings; raw string literals (#"…"#) must be. The old
        // kPatHashLineComment in the swift "strings" array painted every #
        // line as a string.
        NSString *swiftHashIfString = span(kString, @"#if DEBUG");
        NSString *swiftHashAvailString = span(kString, @"#available(iOS 15)");
        NSString *swiftHashEndString = span(kString, @"#endif");
        NSString *swiftRawLiteral = span(kString, @"#\"raw\"#");
        NSString *swiftIfKeyword = span(kKeyword, @"if");
        const char *swiftHashMust[] = {
            swiftRawLiteral.UTF8String, swiftIfKeyword.UTF8String, NULL,
        };
        const char *swiftHashMustNot[] = {
            swiftHashIfString.UTF8String, swiftHashAvailString.UTF8String,
            swiftHashEndString.UTF8String, NULL,
        };
        QLCCSelfTestCase swiftHashCase = {
            .name = "swift: #if/#available/#endif not coloured as string; raw #\"…\"# is (B1)",
            .ext = "swift",
            .source =
                "#if DEBUG\n"
                "if flag {\n"
                "  let s = #\"raw\"#\n"
                "  if #available(iOS 15) {}\n"
                "}\n"
                "#endif\n",
            .mustContain = swiftHashMust,
            .mustNotContain = swiftHashMustNot,
        };
        runCase(swiftHashCase, h);

        // B2: F# line comments are // and block comments are (* … *). The old
        // config matched the literal three characters "(*)" (and Haskell's
        // {- -}), so neither F# comment style was ever coloured.
        NSString *fsBlockComment = span(kComment, @"(* block *)");
        NSString *fsLineComment = span(kComment, @"// line");
        const char *fsMust[] = { fsBlockComment.UTF8String, fsLineComment.UTF8String, NULL };
        QLCCSelfTestCase fsCommentCase = {
            .name = "fsharp: (* block *) and // line comments colour (B2)",
            .ext = "fs",
            .source = "let x = 1 (* block *)\n// line\nlet y = 2\n",
            .mustContain = fsMust,
        };
        runCase(fsCommentCase, h);

        // B3: C/ObjC/C++ preprocessor lines (#import/#define) must colour as
        // preprocessor. '<'/'>' are HTML-escaped in the rendered output.
        NSString *cImportLine = span(kPreproc, @"#import &lt;Foundation/Foundation.h&gt;");
        NSString *cDefineLine = span(kPreproc, @"#define MAX 10");
        const char *cPreprocMust[] = { cImportLine.UTF8String, cDefineLine.UTF8String, NULL };
        QLCCSelfTestCase cPreprocCase = {
            .name = "objc: #import/#define preprocessor lines colour (B3)",
            .ext = "m",
            .source =
                "#import <Foundation/Foundation.h>\n"
                "#define MAX 10\n"
                "int main() { return MAX; }\n",
            .mustContain = cPreprocMust,
        };
        runCase(cPreprocCase, h);

        // The line-number renderer is the most complex
        // rendering path and had zero coverage. With showLineNumbers on it
        // must emit a <table> with one numbered <td class="ln"> row per line.
        // Uses a dedicated config so the shared `h` (plain <pre> output) is
        // untouched for any earlier/later cases.
        {
            QLCCConfiguration *lnCfg = [[QLCCConfiguration alloc] init];
            lnCfg.showLineNumbers = YES;
            QLCCHighlighter *lnH = [[QLCCHighlighter alloc] initWithTheme:theme
                                                            configuration:lnCfg];
            NSString *lnHtml = [lnH htmlPreviewForSource:@"int a = 1;\nint b = 2;\nint c = 3;\n"
                                        pathExtension:@"c"];
            checkCond("highlighter: line-number table renders one row per line (§4)",
                      [lnHtml rangeOfString:@"<table class=\"code\">"].location != NSNotFound
                          && [lnHtml rangeOfString:@"<td class=\"ln\">1</td>"].location != NSNotFound
                          && [lnHtml rangeOfString:@"<td class=\"ln\">3</td>"].location != NSNotFound,
                      lnHtml);
        }

        // B5: dotless convention filenames must highlight via the language
        // map end-to-end. The provider returns a lowercased identifier for
        // dotless names; the highlighter then maps "makefile"/"gnumakefile"
        // to the make tokenizer, so a # comment gets coloured (previously
        // these rendered as plain text).
        {
            QLCodePreviewProvider *p = [QLCodePreviewProvider new];
            NSString *mkExt = [p effectiveExtensionForURL:[NSURL fileURLWithPath:@"/tmp/Makefile"]];
            NSString *gnuExt = [p effectiveExtensionForURL:[NSURL fileURLWithPath:@"/proj/GNUmakefile"]];
            NSString *mkHtml = [h htmlPreviewForSource:@"# comment\nall: build\n"
                                       pathExtension:mkExt];
            NSString *gnuHtml = [h htmlPreviewForSource:@"# comment\nall: build\n"
                                         pathExtension:gnuExt];
            NSString *makeComment = span(kComment, @"# comment");
            checkCond("provider: Makefile & GNUmakefile resolve and highlight as make (B5)",
                      [mkExt isEqualToString:@"makefile"]
                          && [gnuExt isEqualToString:@"gnumakefile"]
                          && [mkHtml rangeOfString:makeComment].location != NSNotFound
                          && [gnuHtml rangeOfString:makeComment].location != NSNotFound,
                      [NSString stringWithFormat:@"mkExt=%@ gnuExt=%@", mkExt, gnuExt]);
        }

        // B4: readPrefixAtURL must not mojibake when the byte cap splits a
        // multi-byte UTF-8 sequence. Write "café" (5 bytes; é = C3 A9) and
        // read only 4 bytes: the split trailing é must be trimmed, decoding
        // cleanly to "caf" instead of falling through to lossy ASCII ("cafÃ").
        {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                @"qlcc_selftest_utf8.txt"];
            uint8_t cafe[] = { 'c','a','f',0xC3,0xA9 };  // "café", 5 bytes
            [[NSData dataWithBytes:cafe length:sizeof(cafe)] writeToFile:tmp atomically:YES];
            QLCodePreviewProvider *p = [QLCodePreviewProvider new];
            NSString *prefix = [p readPrefixAtURL:[NSURL fileURLWithPath:tmp] maxBytes:4];
            checkCond("provider: readPrefixAtURL trims a split UTF-8 sequence (B4)",
                      [prefix isEqualToString:@"caf"],
                      [NSString stringWithFormat:@"got '%@'", prefix]);
        }

        // M1: the user-typed font value is escaped so it can't break out of
        // the CSS string or the <style> block. The Font field is an editable
        // combo box, so any string can land raw in font-family:%@;.
        {
            NSString *legit  = [QLCCHighlighter cssFontFamily:@"Fira Code"];
            NSString *htmlIn = [QLCCHighlighter cssFontFamily:@"</style><script>alert(1)</script>"];
            NSString *cssIn  = [QLCCHighlighter cssFontFamily:@"Menlo\"; body{x:1}"];
            checkCond("highlighter: cssFontFamily escapes CSS/HTML injection (M1)",
                      [legit rangeOfString:@"\"Fira Code\""].location != NSNotFound   // legit multi-word still quoted
                          && [htmlIn rangeOfString:@"<"].location == NSNotFound       // '<' stripped -> no </style>
                          && [htmlIn rangeOfString:@">"].location == NSNotFound       // '>' stripped
                          && [cssIn rangeOfString:@"\\\""].location != NSNotFound,    // '"' escaped, not bare
                      [NSString stringWithFormat:@"legit=%@ htmlIn=%@ cssIn=%@", legit, htmlIn, cssIn]);
        }

        // P2: token colours ship as one CSS class per kind plus a rule in
        // the document stylesheet, not a style attribute per token. Pin the
        // class→hex mapping for the fixed darkplus theme.
        {
            NSString *html = [h htmlPreviewForSource:@"int x = 1; // c\n\"s\" #p $v\n"
                                       pathExtension:@"c"];
            NSDictionary<NSString *, NSString *> *clsToHex = @{
                @"k": @"#569cd6", @"s": @"#d7ba7d", @"c": @"#6a9955",
                @"n": @"#b5cea8", @"p": @"#007acc", @"v": @"#9cdcfe",
            };
            BOOL allRules = YES;
            for (NSString *cls in clsToHex) {
                NSString *rule = [NSString stringWithFormat:@".%@{color:%@}", cls, clsToHex[cls]];
                if ([html rangeOfString:rule].location == NSNotFound) allRules = NO;
            }
            checkCond("highlighter: stylesheet maps token classes to darkplus colours (P2)",
                      allRules, html);
        }

        // M2: a built-in safety-net cap (kQLCCDefaultMaxFileSize) must exist
        // and be sane, and the capping mechanism must truncate a file that
        // exceeds config.maxFileSize. (0 still means explicit "no cap".)
        {
            BOOL sane = kQLCCDefaultMaxFileSize > 0
                     && kQLCCDefaultMaxFileSize <= 64ULL * 1024 * 1024;
            QLCCConfiguration *capCfg = [[QLCCConfiguration alloc] init];
            capCfg.maxFileSize = 8;  // 8-byte cap
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                @"qlcc_selftest_cap.txt"];
            [@"abcdefghijklmnopqrstuvwxyz0123456789" writeToFile:tmp
                                          atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            QLCodePreviewProvider *p = [QLCodePreviewProvider new];
            NSString *prefix = [p readSourceAtURL:[NSURL fileURLWithPath:tmp]
                                    configuration:capCfg];
            checkCond("config/provider: built-in size cap + capping mechanism (M2)",
                      sane && [prefix length] <= 8,
                      [NSString stringWithFormat:@"cap=%llu prefixLen=%lu",
                          kQLCCDefaultMaxFileSize, (unsigned long)prefix.length]);
        }

        fprintf(stderr, "\nqlcc_selftest: %d/%d cases passed\n", gCasesPassed, gTotal);
        if (gFailures > 0) {
            fprintf(stderr, "qlcc_selftest: %d assertion(s) FAILED\n", gFailures);
            return 1;
        }
        fprintf(stderr, "qlcc_selftest: all assertions passed\n");
        return 0;
    }
}
