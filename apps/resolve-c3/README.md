# resolve-c3

Zig controller for the `$resolve` C3 workflow.

This app owns the runtime command surface that will replace the legacy Python controller and gate scripts. Runtime state belongs under `.ledger/c3/`; legacy `.resolve-c3/` state is handled only by the explicit migration command added in the lifecycle implementation wave.

## Commands

- `resolve-c3 init`: create `.ledger/c3/` state and install the local exclude guard.
- `resolve-c3 doctor`: print current controller path defaults.
- `resolve-c3 paths`: print the active state and legacy roots.
- `resolve-c3 status`: report whether `.ledger/c3/state.json` exists.

## Build

```sh
zig build build-resolve-c3
zig build test-resolve-c3
zig build run-resolve-c3
```
