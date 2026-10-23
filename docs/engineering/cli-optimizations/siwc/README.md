# SIWC HTTP session measurement

The benchmark compares the transport at commit
`8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb` with the current transport source.
Each sample performs token, discovery, and signing-key requests against one
loopback HTTP server, matching the request order in login completion and identity
verification. Both sides check the same synthetic response bytes. The timed
region includes transport construction, all three requests, response cleanup,
and transport destruction. Listener startup and final server join are excluded.

The builder replaces only `Request.url` with the loopback address, then appends
the same test server and benchmark harness to both source versions. Production
request validation still runs. This local fixture does not model TLS setup,
remote latency, real tokens, or authentication acceptance. The result measures
transport overhead and accepted connection counts, not end-to-end live login.

Observed on 2026-10-23 with Zig 0.17.0, ReleaseFast, Darwin 27.2.0 arm64:

| Per three-request sequence | Baseline | Owned session |
| --- | ---: | ---: |
| Samples | 125 | 125 |
| Accepted connections, every sample | 3 | 1 |
| Median elapsed time | 426.8 µs | 238.4 µs |
| 10th–90th percentile elapsed time | 338.1–755.6 µs | 177.9–448.8 µs |

The median decreased 44.1%; every candidate process median was lower than its
paired baseline. Other task builds and measurements were stopped during this
window, but unrelated shared-host jobs remained. The spread and process-to-process
drift limit the precision of the timing estimate. The measured connection-count
reduction was consistent across all 250 samples. Raw output and exact input
hashes are in [results](results/), with aggregates in
[summary.json](results/summary.json).

Build with Zig 0.17.0 and `uv` from the repository root:

```sh
uv run --no-project --isolated \
  docs/engineering/cli-optimizations/siwc/benchmark.py \
  --baseline 8e470a2 --output /tmp/siwc-http-benchmark --build-only
```

Once other compilation and benchmark work has finished, collect five alternating
pairs of processes, with 25 samples per process:

```sh
uv run --no-project --isolated \
  docs/engineering/cli-optimizations/siwc/benchmark.py \
  --baseline 8e470a2 --output /tmp/siwc-http-benchmark --skip-build
```

The output directory contains generated source, compiled binaries, raw samples,
input hashes, toolchain and host details, and a summary. The sampler refuses to
run if the source, harness, baseline, toolchain, or host metadata changed since
the ReleaseFast build.
All samples, including each process's first sample, are included in the median
and 10th/90th percentile calculations.

The owned session keeps at most two idle connections and uses one stable client
allocation. Token and revocation requests discard idle connections before
sending and are never replayed. Reads may recover once from an idle connection
that closed before response bytes arrived, within the original deadline.
Existing `Http{}` callers retain the stateless behavior.

Debug and ReleaseSafe SIWC checks each pass 106 of 107 tests; the remaining test
is the existing Linux-only FIFO test on macOS. Both synthetic process gates pass.
Transport tests cover connection reuse, bearer omission, pooled secret erasure,
stable lifetime after moving the handle, response-size boundaries, redirects,
cancellation and lock release, I/O mismatch, allocation failure, stale idle
connections, partial response headers, and absence of token replay. Framing tests
cover 204 responses completing on open sockets before a subsequent reused
request, coalesced and separated informational responses before the final
response, 101 connection retirement, 304 rejection, normal response bodies,
missing final responses, and exclusion of retries after any accepted header.

Status-defined empty responses complete through the HTTP reader's zero-length
framing transition, making both reading and cleanup independent of socket
closure. Informational messages lead to the final response under the original
deadline; 101 retains its status with an empty body and closes the connection.
Manager status acceptance and the existing rejection of all 3xx responses remain
unchanged. These framing rules follow
[RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3) and
[RFC 9110 §15.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.2).
