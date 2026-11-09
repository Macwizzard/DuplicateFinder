# DuplicateFinder — AppKit / Mojave variant

This is an **independent branch**, not a modification of `main`. It shares no
history with `main` because it is a separate codebase rather than a change to
the SwiftUI app.

It is a rewrite of DuplicateFinder in plain AppKit, targeting **macOS 10.14
Mojave**, which has no SwiftUI, no `async`/`await`, no actors and no CryptoKit.
The SwiftUI version on `main` requires macOS 12.

| | `main` | this branch |
|---|---|---|
| UI | SwiftUI | AppKit (`NSViewController`, `NSTableView`) |
| Minimum macOS | 12.0 | 10.14 |
| Concurrency | actors, `async`/`await` | pre-concurrency |
| Hashing | CryptoKit `SHA256` | hand-rolled / CommonCrypto |
| Status | working | **builds, but shows no window — see below** |

## Detection algorithm

Identical in intent to `main`: group by exact file size, then hash the first
64 KB, then the last 64 KB, then full SHA-256 on the survivors. Files under
256 KB are hashed outright.

This variant reads through POSIX `open`/`read` into a single reused byte
buffer rather than `FileHandle`, which was necessary to keep memory flat when
hashing very large files on this target.

## Known bug: no window appears

The app builds and the process launches and stays running, but no window is
ever shown and `print` statements at the top of `applicationDidFinishLaunching`
never appear — the delegate method is apparently never called.

Already ruled out:

- Only one `AppDelegate` class, with `@NSApplicationMain` directly above it
- No `Main.storyboard` file
- No storyboard or nib key in the target's Info settings
  (`INFOPLIST_KEY_NSMainStoryboardFile` is absent; `GENERATE_INFOPLIST_FILE` is
  `YES`, so there is no `Info.plist` on disk to carry a stale key)
- `INFOPLIST_KEY_NSPrincipalClass` is `NSApplication`
- Clean Build Folder did not help

Leading hypothesis, not yet confirmed by a build: `@NSApplicationMain` expands
to a `main` that calls `NSApplicationMain()`, which expects a main nib or
storyboard to instantiate the app delegate and connect it to `NSApp`. With no
nib and no storyboard present, nothing assigns `NSApp.delegate`, so
`applicationDidFinishLaunching` is never delivered and no window is created.

If that is the cause, the fix is to stop relying on `@NSApplicationMain` and
wire the delegate up explicitly in a `main.swift`:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

...with `@NSApplicationMain` removed from `AppDelegate` so there is only one
entry point.

## Building

Open `Duplicate Finder Legacy.xcodeproj` in Xcode and build the
`Duplicate Finder Legacy` target. If you are not the original author, set the
signing team to your own in Signing & Capabilities — the app is sandboxed, so
it must be signed to run.

## AI assistance

Development of this project was assisted by AI tooling (Claude, by Anthropic).
Commits that included AI assistance carry a `Co-Authored-By` trailer.

## License

MIT — see [LICENSE](LICENSE).
