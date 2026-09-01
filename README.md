# QLCodePreview

A Quick Look preview extension for macOS that renders **syntax-highlighted
previews** for source code, config, markup, and more directly in Finder and
Quick Look (Space bar).

The highlighter is self-contained and dependency-free; it runs entirely inside
the sandboxed Quick Look extension (no shelling out to external tools).

## Requirements

- **macOS 12.0+** (uses the modern `QLPreviewProvider` / `QLPreviewReply`
  extension API).
- Builds **without Xcode** only the Command Line Tools are required.

## Build and Install

```sh
./build.sh install
```

This builds the host app plus the embedded `.appex`, copies it to
`~/Applications/QLCodePreview.app`, and registers it with LaunchServices /
PlugInKit / Quick Look.

Then enable it once (macOS won't let a script do this part):

> **System Settings → General → Login Items & Extensions → Quick Look →
> QLCodePreview Extension = ON**

Space-bar any source file in Finder to get a colourised preview. Rebuild after
code changes with `zsh build.sh`; re-run `install` to deploy.

## Configuration

Launch the **QLCodePreview** app — a single settings window with two tabs:

- **Preview Settings**: font, font size, light/dark themes, line numbers (and
  gutter width), soft-wrap, tab width, max file size.
- **Custom File Types**: map any file extension to one of the supported
  languages (e.g. `install → php`).

Both take effect immediately for new previews **no rebuild needed.**
Preferences live in an App-Group defaults suite
(`group.com.konstruuktlabs.QLCodePreview`) shared between the host app and the
sandboxed extension.

## Supported file types

Dozens of source/config/markup languages are supported. The full extension→language
map lives in `QLCodePreview/QLCCHighlighter.m` (`+languageForExtension:`); the
claimed UTIs are listed in `QLCodePreview/Info.plist` (`QLSupportedContentTypes`).
Any extension can additionally be remapped in the app's **Custom File Types**
pane (e.g. `myext → php`).

| Category | Language | Extensions |
| --- | --- | --- |
| **C family** | C | `.c` |
| | Objective‑C | `.h`, `.m` |
| | Objective‑C++ | `.mm` |
| | C++ | `.cpp`, `.cc`, `.cxx`, `.c++`, `.hpp`, `.hh`, `.hxx`, `.h++`, `.ino` |
| **Apple / systems** | Swift | `.swift` |
| | Rust | `.rs` |
| | Go | `.go` |
| | Zig | `.zig` |
| | Nim | `.nim` |
| **JVM** | Java | `.java` |
| | Kotlin | `.kt`, `.kts` |
| | Scala | `.scala`, `.sc` |
| | Groovy | `.groovy`, `.gradle` |
| | Clojure | `.clj`, `.cljs` |
| **.NET** | C# | `.cs` |
| | F# | `.fs` |
| | Visual Basic | `.vb` |
| **Web / JS** | JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` |
| | TypeScript | `.ts` †, `.tsx` |
| | PHP | `.php`, `.install`, `.module`, `.engine` |
| | CSS / preprocessors | `.css`, `.scss`, `.sass`, `.less`, `.styl` |
| | HTML | `.html` ‡, `.htm` ‡, `.xhtml` ‡, `.vue`, `.svelte` |
| | XML | `.xml`, `.xsl`, `.xslt`, `.xsd`, `.rss`, `.svg`, `.resx`, `.csproj`, `.plist`, `.iml`, `.fxml`, `.rdf` |
| **Scripting** | Python | `.py`, `.pyw`, `.pyi` |
| | Ruby | `.rb`, `.rbw`, `.gemspec` |
| | Perl | `.pl`, `.pm`, `.t` |
| | Lua | `.lua` |
| | Tcl | `.tcl` |
| | Shell | `.sh`, `.bash`, `.zsh`, `.ksh`, `.csh`, `.tcsh`, `.fish`, `.command`, `.bashrc`, `.zshrc`, `.bash_profile`, `.profile`, `.bats`, `.ebuild`, `.eclass` |
| | PowerShell | `.ps1`, `.psm1` |
| **Data / config** | JSON | `.json`, `.json5`, `.jsonl` |
| | YAML | `.yaml`, `.yml` |
| | TOML | `.toml` |
| | INI / config | `.ini`, `.cfg`, `.conf`, `.properties`, `.editorconfig`, `.gitconfig` |
| **Build / infra** | Make | `.mk`, `.makefile`, `.gnumakefile`, `.am` |
| | CMake | `.cmake` |
| | GraphQL | `.graphql`, `.gql` |
| | Terraform | `.tf`, `.tfvars` |
| **Database** | SQL | `.sql`, `.psql`, `.ddl` |
| **Docs / markup** | Markdown | `.md`, `.markdown`, `.adoc`, `.asciidoc`, `.rst` |
| | LaTeX / TeX | `.tex`, `.latex` |
| **Other languages** | R | `.r` |
| | Dart | `.dart` |
| | Elixir | `.ex`, `.exs` |
| | Erlang | `.erl`, `.hrl` |
| | Haskell | `.hs`, `.lhs` |
| | Pascal | `.pas`, `.pp`, `.dpr` |
| | Julia | `.jl` |
| | Crystal | `.cr` |
| **Misc** | Diff / patch | `.diff`, `.patch`, `.rej` |
| | Plain text | `.txt`, `.log`, `.diz`, `.nfo`, `.sfv`, `.readme` |

> † On current macOS, `.ts` is claimed by the system video type
> (`public.mpeg-2-transport-stream`) and is **not** previewable as code.
> `.tsx` works normally — see [Known limitations](#known-limitations-macos).
>
> ‡ `.html` / `.htm` / `.xhtml` are rendered by macOS's built-in HTML
> previewer, not shown as colourised source — see
> [Known limitations](#known-limitations-macos).

Unknown extensions fall back to plain-text highlighting.

---

## Known limitations (macOS)

A few common extensions **cannot be previewed as code**. In every case below
the cause is the **operating system**, not QLCodePreview: macOS assigns the
file an Apple **public** UTI for that extension, and a third-party Quick Look
preview extension cannot override the system handler that owns it. There is no
priority field in `UTExportedTypeDeclarations` and no public API to make a
third-party UTI preferred over a public one for a given extension. macOS picks
the first matching **system** UTI and does **not** fall through to a secondary
one (e.g. a TypeScript declaration). This behaviour is long-standing and
unchanged through macOS 15 (Sequoia) / macOS 26.

### `.html` / `.htm` / `.xhtml` shown rendered, not as source

macOS tags these `public.html` / `public.xhtml`, which the built-in Quick Look
handler (historically `Web.qlgenerator`, now the modern system preview
provider) claims and renders in a WebKit view. The system handler always takes
precedence, so you see the **rendered page**, never colourised source. No
in-extension workaround exists.

### `.ts` treated as video, not TypeScript

Apple's CoreTypes maps `.ts` to `public.mpeg-2-transport-stream`, a public UTI
that conforms to `public.movie`. Quick Look therefore hands the file to the
system video handler and never reaches QLCodePreview. Any TypeScript UTI (e.g.
`com.microsoft.typescript`) is secondary and is never selected. This can also
affect Spotlight metadata in some scenarios.

**`.tsx` is unaffected and previews correctly.** Practical workaround: rename
or copy the file to `.tsx`.

### Why these can't be fixed in code

Both are the same root cause: the OS owns the extension with a public UTI the
extension can't outrank.

## How it works

The extension returns a data-based HTML preview (`UTTypeHTML`) that Quick Look
renders in its WebKit view. Note that **Quick Look disables JavaScript in HTML
previews**, so all preview UI is plain HTML/CSS there is no script-driven
interactivity available to previews.

## Troubleshooting

- **No preview?** Confirm the extension is ON in *System Settings → Quick Look*,
  then re-run `zsh build.sh install` (re-registers with LaunchServices).
- **Check registration:** `pluginkit -mAvvv | grep -i qlcodepreview` the line
  should start with `+` (enabled).
- **Reset Quick Look:** `qlmanage -r`.

## Development

This repo keeps a local [graphify](https://pypi.org/project/graphifyy/) knowledge
graph in `graphify-out/` (gitignored, disposable). A post-commit hook rebuilds
it after every commit; query it with `graphify query "…"`, or rebuild manually
with `graphify extract . --code-only` if stale.
