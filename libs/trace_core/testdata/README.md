# Trace fixtures

These files contain synthetic source records for parser regression tests.
`nested_tool_outputs.jsonl` combines the existing Codex response-item envelope
with the `exec_command` / `write_stdin` process-result fields printed by the
`functions.exec` wrapper. It contains no private transcript or real command run.

The fixture covers several commands in one wrapper, a text block containing a
JSON array, intermediate and final output, an asynchronous wait, redirected
output readback, missing and malformed statuses, and quoted documentation.
The failed application output is passive fixture data. Its process exit is
independent of the successful wrapper exit, and its nested application error is
not promoted to another process execution.
