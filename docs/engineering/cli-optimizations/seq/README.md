# Seq field retention comparison

Build baseline commit `8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb` and the
candidate with Zig 0.17.0 using `zig build build-seq -Doptimize=fast -j1`.
From this directory on macOS:

```sh
ruby measure.rb /path/to/baseline/zig-out/bin/seq \
  /path/to/candidate/zig-out/bin/seq results.json
```

The runner creates temporary synthetic JSONL traces, checks identical output
bytes, and removes its fixtures afterward. Eleven paired rounds alternate
binary order and rotate cases after one warmup per binary and case. Each command
has a ten-second timeout. Wall time uses a monotonic clock around process launch
and completion, including the `/usr/bin/time` wrapper. Peak resident memory comes
from macOS `/usr/bin/time -l`; its coarse elapsed-time field is retained as raw
evidence but is not used for latency calculations.

Projected turns, messages, and source events avoid retaining unrequested text
and serialized occurrence payloads. Full-row queries remain a control. Parsing
and validation still inspect every source record, including excluded records;
this change does not skip source I/O or suppress malformed-input errors.

The captured run shares the host with unrelated work. Paired samples reduce
ordering bias but do not establish isolated-host latency or production tail
latency. Binary and fixture digests, raw samples, and observed ranges are in
`results.json`.
