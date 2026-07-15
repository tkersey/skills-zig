# img

`img` is a pure-Zig CLI for turning UTF-8 code, skills, and other text documents into dense PNG pages. It ports the document-rendering path from pxpipe without the proxy, dashboard, provider clients, or runtime package dependencies.

## Install

```bash
brew tap tkersey/tap
brew install img
```

## Build

Zig 0.16.0 or newer is required.

```bash
zig build build-img -Doptimize=ReleaseFast
zig build test-img --summary all
```

The binary is written to `zig-out/bin/img`.

## Usage

Choose exactly one input mode and always name an output directory:

```bash
img SKILL.md references/ --out /tmp/skill-pages
img docs/ --include '*.md' --exclude 'archive/**' --out /tmp/docs
cat AGENTS.md | img --stdin --facts --out /tmp/agents
img --git /path/to/repo --facts --json --out /tmp/working-tree
img --diff origin/main /path/to/repo --out /tmp/main-diff
```

Path mode accepts files and recursive directories. `--include` and `--exclude` are repeatable and support `*`, `**`, and `?`; patterns without `/` match basenames. Use `--` before a path that begins with `-`.

`--git [REPO]` renders the deterministic tracked diff from `HEAD`, followed by sorted untracked, nonignored text files. `--diff REF [REPO]` renders only the tracked diff from `REF`. These modes invoke the system `git` directly with an argument vector, never through a shell. Use Git modes only with a trusted repository and trusted Git configuration: Git itself may run configured conversion filters, filesystem monitors, or other helpers while reading a working tree.

## Output contract

The exact `--out` path must be absent or empty. `img` renders into a private sibling staging directory and publishes the completed directory with one same-filesystem rename. A successful output contains only:

```text
page-001.png
page-002.png
...
factsheet.txt   # only with --facts
```

There is no manifest file. `--json` writes one stable `img.render.v1` summary to standard output after publication; it includes page dimensions, byte counts, dropped-glyph counts, source files, fact-sheet counts, and structured skip warnings.

`--facts` preserves precision-critical strings that vision models can misread—paths, URLs, UUIDs, commit hashes, versions, flags, numbers, environment-style constants, camelCase identifiers, and ticket codes. The one-line `factsheet.txt` is extracted from the original corpus, keeps at most 96 ranked identifiers and eight URLs, and annotates repeated tokens as `×N`.

## Input safeguards

- UTF-8 is required; valid codepoints and original line endings, including CRLF, are preserved.
- Explicit invalid, binary, oversized, inaccessible, or symlink targets fail the run.
- Recursive and untracked-file collection skips those entries with structured warnings.
- Symlinks are never traversed.
- Files are capped at 1,000,000 bytes, the assembled corpus at 32 MiB, and output at 999 pages.
- Collected paths are slash-normalized, sorted, and deduplicated before rendering.
- Output directories and files are created with private `0700` and `0600` permissions on POSIX systems.
