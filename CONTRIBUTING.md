# Contributing

Read [TigerStyle for skills-zig](docs/engineering/TIGER_STYLE.md) before making
Zig changes. It is the normative engineering contract for new and materially
changed code.

Before opening a pull request, run the relevant application tests and these
repository checks:

```bash
zig fmt --check <changed-zig-files>
zig test tools/tiger_style/main.zig
zig run tools/tiger_style/main.zig -- audit-diff --base <base> --head <head>
```

For a new file or a substantial refactor, also run:

```bash
zig run tools/tiger_style/main.zig -- audit-files path/to/file.zig
```

Pull requests must explain why the design is correct, which limits apply, how
invalid states are rejected, and what evidence proves the error paths. Follow
the independent release contract in `docs/release/README.md` for shipped CLI
changes.
