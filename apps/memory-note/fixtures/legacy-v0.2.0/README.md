# Actual memory-note 0.2.0 admissions

These four envelope files are unmodified bytes written by the 0.2.0 native
`append` command, one for each supported extension. The development binary was
built from `apps/memory-note/scripts/memory_note.zig` at commit
[`a8bce33dc948192475abbf3eb9daabbe8c4787e2`](https://github.com/tkersey/skills-zig/blob/a8bce33dc948192475abbf3eb9daabbe8c4787e2/apps/memory-note/scripts/memory_note.zig),
verified Git blob `e1e7a9be364fc4e1c62c97476c0b798488b55a30`. The imported
shared libraries are unchanged between that base and the 0.3.0 upgrade.

`manifest.json` records the exact input text, original filename, original note
ID, and SHA-256 for each envelope. The fixture filenames name the extension;
the upgrade test installs them under their original filenames in temporary v1
stores. It checks exact bytes and identity before and after v1-to-v2 and reverse
migration, and replays the original input to require `duplicate_skip` with the
original ID. CI does not need to build or run the retired 0.2.0 executable.

The separate capacity case generates fresh valid envelopes through the current
native `append` command. It proves that a source over 64 MiB can migrate and that
retaining both copies does not invalidate retry. It is not represented as old
binary output.
