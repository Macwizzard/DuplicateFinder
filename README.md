# DuplicateFinder

A macOS app that finds byte-identical files in a folder tree and gives you a
simple way to review them and move the duplicates to the Trash.

Filenames are ignored entirely — detection is based on file contents, so a
renamed copy is still found.

## Requirements

- macOS 12.0 or later
- Xcode (to build from source)

## How detection works

Comparing every file against every other file would be impossibly slow, so
candidates are narrowed down in tiers. Each tier is cheaper than the one after
it, and most files are eliminated before anything is read from disk:

1. **Group by exact file size**, taken from the directory listing. Any file
   whose size is unique cannot have a duplicate, so it is discarded here — for
   free, without being opened.
2. **Hash the first 64 KB.** Files whose heads differ are discarded.
3. **Hash the last 64 KB.** Files whose tails differ are discarded.
4. **Full SHA-256** on whatever survives, read in 256 KB chunks so that
   hashing a very large file does not load it into memory.

Files under 256 KB skip straight to step 4, since hashing them outright is
cheaper than sampling them twice.

Each tier runs across every size group at once and hashes in parallel across
all CPU cores. As a rough indication, a tree of 62,354 files totalling 1.8 GB
scans in about 7 seconds on an 8-core Xeon E5 (2013 Mac Pro).

Hidden files, symlinks, package contents (such as the insides of `.app`
bundles) and zero-byte files are skipped.

## Features

- Pick any folder and scan it recursively
- Results grouped by content, sorted by largest savings, file size, duplicate
  count, or age of the original
- One file per group is the **keeper**; a radio button lets you choose which
- Checkboxes to mark duplicates for trashing, with Select All / Deselect All
  per group
- Running total of recoverable space, and of the current selection
- Creation date shown per file, plus a Reveal in Finder button
- Cancel a scan at any time (Cmd+.); quitting mid-scan asks first

## Safety

Files are moved to the Trash via `FileManager.trashItem`, never deleted
outright, so anything removed can be restored until you empty the Trash. The
keeper in each group is never trashed. A confirmation dialog shows the file
count and how much space will be freed before anything is moved.

The app is sandboxed and only requests read/write access to folders you
explicitly select.

## Building

Open `DuplicateFinder.xcodeproj` in Xcode and build the `DuplicateFinder`
target (Product > Build), or from the command line:

```bash
xcodebuild -project DuplicateFinder.xcodeproj -target DuplicateFinder \
  -configuration Release build
```

If you are not the original author, change the signing team in the target's
Signing & Capabilities tab to your own. The app is sandboxed, so it must be
signed to run.

## AI assistance

Development of this project was assisted by AI tooling (Claude, by Anthropic).
Commits that included AI assistance carry a `Co-Authored-By` trailer, so the
per-change record is in the Git history.

## License

MIT — see [LICENSE](LICENSE).
