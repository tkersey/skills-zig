# typesafe

`typesafe` is a small document review CLI backed by TypeSafe's System One API.
It accepts UTF-8 text and Markdown files as paths, or `-` for stdin. Each
document is sent once with all configured Score questions. Results are JSONL:
one record per document, including scores, level probabilities, token usage,
and `needs_review`.

The default rubric judges apparent technical accuracy from the document alone.
It flags scores below 2 on a 0–3 scale. This is a triage signal, not verified
correctness. Provide source evidence and a domain-specific rubric before using
the results for consequential decisions.

```sh
# In the repository root, create .env containing TYPESAFE_API_KEY=your_key_here.
set -a
source .env
set +a
zig build build-typesafe
./zig-out/bin/typesafe README.md notes.md
cat notes.md | ./zig-out/bin/typesafe -
```

Pass `--rubric FILE` before the document paths to score more dimensions. The
rubric is JSON with one to eight dimensions. Every dimension has a unique ID,
complete question instructions, two to six ordered level descriptions, and a
`review_below` threshold on the level scale. A score strictly below that
threshold sets its `review` flag; any flagged dimension sets `needs_review`.
For example:

```json
{
  "dimensions": [
    {
      "id": "technical_accuracy",
      "instructions": "Based only on `document.text`, how technically sound are its claims?",
      "levels": [
        "Clear technical errors or contradictions",
        "Several questionable technical claims",
        "Mostly coherent with a specific uncertainty",
        "Technically coherent with no apparent error"
      ],
      "review_below": 2.0
    }
  ]
}
```

The CLI reads `TYPESAFE_API_KEY` from the process environment; it does not
load `.env` itself. The repository ignores `.env` and `.env.*`. The CLI uses
`POST https://api.typesafe.ai/v1/systemone` with `jev-latest`; it does not write
the key to output. Input is limited to 32 documents of 512 KiB each. Non-200
API responses, malformed answers, invalid rubrics, and file errors fail the
command without printing a result for the affected document. Successful
results, including flagged ones, return exit code 0.
