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

Launch the **QLCodePreview** app, it has two windows:

- **Preferences**: font, font size, light/dark themes, line numbers (and
  gutter width), soft-wrap, tab width, max file size.
- **Custom File Types**: map any file extension to one of the supported
  languages (e.g. `install → php`).

Both take effect immediately for new previews **no rebuild needed.**
Preferences live in an App-Group defaults suite
(`group.com.konstruuktlabs.QLCodePreview`) shared between the host app and the
sandboxed extension.

## Supported file types

Dozens of source/config/markup languages: Swift, Objective-C, C/C++, Rust, Go,
Python, Ruby, JavaScript/JSX, TypeScript, Java, Kotlin, Scala, SQL, Vue/Svelte
components, Markdown, YAML, TOML, JSON, shell scripts, and many more. See
`QLCodePreview/QLCCHighlighter.m` (`+languageForExtension:`) for the full
extension→language map and `QLCodePreview/Info.plist` (`QLSupportedContentTypes`)
for the claimed UTIs.

---

## Known limitations (macOS)

A few common extensions **cannot be previewed as code**. In every case below
the cause is the **operating system**, not QLCodePreview: on current macOS
(verified on macOS 26 / darwin 25) a third-party Quick Look preview extension
cannot override the built-in/system type that owns the extension. There is no
priority field in `UTExportedTypeDeclarations` and no public API to make a
third-party UTI preferred over an Apple **public** UTI for a given extension, so
no Quick Look code extension can work around these.

### `.html` / `.htm` / `.xhtml` shown rendered, not as source

macOS has a built-in HTML Quick Look previewer that always wins for
`public.html`, even when QLCodePreview claims it. You'll see the **rendered
page**, not colourised source. No in-extension workaround on this OS.

### `.ts` treated as video, not TypeScript

macOS maps `.ts` to `public.mpeg-2-transport-stream` (an Apple public UTI
conforming to `public.movie`), which beats every TypeScript UTI so `.ts`
files are handed to a video handler and never reach QLCodePreview.

**`.tsx` is unaffected and previews correctly.** Practical workaround: rename
or copy the file to `.tsx`.

### Why these can't be fixed in code

Both are the same class of problem: the OS assigns the file a system-owned type
that conforms to nothing QLCodePreview claims, so Quick Look never offers the
file to the extension.

This is plausibly **version-dependent** older macOS releases may have allowed
third-party extensions to override these so it's worth re-testing on other
versions. But on macOS 26 these two are not achievable by any third-party
extension.

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
