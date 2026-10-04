# Public tracking examples

[`cases.json`](cases.json) publishes small inputs and semantic expectations for the
[`contract`](../CONTRACT.md). These are data, not an implementation, test runner,
complete evaluator, or measured performance result. Both participants receive the
same file. The coordinator must validate the eventual evaluator before scoring;
that preparation does not block participants from starting development.

## Reading the operations

Each case starts with a fresh environment. `operations` are ordered. An operation's
`command` is a contract JSONL command. The surrounding fields below are fixture
annotations for a test harness; do not send them to the implementation as commands.

| Annotation | Meaning |
| --- | --- |
| `on` | Independent tracker/CLI process name within this case; usually `main`. |
| `expect.ok` | Expected response success flag. |
| `expect.result` | Complete expected result, with exact keys and list length/order. |
| `expect.result_subset` | Recursive dictionary subset of the result. Lists still require exactly the stated length/order. Unlisted episode fields must satisfy the contract. |
| `expect.error` | Exact expected error object. |
| `capture_result` | Save an independent JSON copy of the successful result under this case-local name. |
| `snapshot_from` | Before sending this restore command, fill its omitted `snapshot` field from the named capture, after JSON serialization/deserialization. |
| `expect_result_equal` | Compare the complete returned result with the named capture. |

When `expect` contains only `ok`, also check the normative result shape and the
capture/equality annotation. Every operation runs even after an expected failure.
An independent `on` environment starts uninitialized; a restore initializes it.
Exit status applies separately to each `on` CLI stream: a stream containing any
error response exits 1 at EOF, and an entirely successful stream exits 0. In the
checkpoint example, `main` and `restored` exit 0 while `sealed` exits 1. A
fixture-aware harness reports a case as passing when all results and exit codes
match, including intentional errors.

Use the contract's numeric tolerance (absolute/relative 1e-9) for measurement
floats. IDs, counts, statuses, quantized costs, ordering and integer times are exact.
Snapshot equality means equivalent complete JSON values, including checksum;
restore must not change canonical state. Each input/return/capture should be
independent so a test harness does not accidentally introduce aliasing itself.

`cost_checks` gives independently inspectable arithmetic at the indicated batch;
costs are not additional API output fields. These examples do not prescribe a
matching algorithm. `semantic_checks` explains evidence constraints. The separate
`adapter_examples` section supplies pure Python adapter cases, outside the JSONL
protocol. Construct its `blob` with the existing `labs_foreground_mask.Blob` and a
lightweight frame exposing the stated fields and the blob tuple; no image data,
video decoder, network, or production input is necessary. Apply each variant to
the original example independently.

## Expected behavior at a glance

| Case | Published expectation |
| --- | --- |
| One unique object | Four observations remain one track; the bounded three-sample path keeps timestamps 0, 2000 and 3000; repeated finish/drain emits nothing. |
| Global assignment | `left` maps to `t00000001`, `middle` to `t00000002`. Taking the individually cheapest edge loses maximum cardinality. |
| Distinguishable crossing | Orthogonal supplied descriptors preserve the two tracks despite changing detection IDs/order; no unsampled crossing point is emitted. |
| Cost tie | The center detection is ambiguous for both tracks; later observations recover, with two accepted observations and one ambiguous batch per track. |
| Possible merge | A wide box enclosing both predicted centers reports `merge`, and neither track gains observed evidence. |
| Boundaries | Gap/span equality is retained; one millisecond beyond closes at the last observed time. Reset creates a fresh ID. |
| Replay and atomicity | Replay returns the original receipt without requeueing; conflicting/stale retries fail; rejected capacity operations preserve the entire snapshot and subsequent IDs. |
| Checkpoint with queued output | JSON restore preserves two queued episodes, active state and replay history. All continuation receipts, output, and snapshots equal uninterrupted execution. |

For the global-assignment example the distance gate is 0.25. The feasible costs
are 400000 (`t1` to `left`), 360000 (`t1` to `middle`), and 440000 (`t2` to
`middle`). `t2` to `left` is infeasible. The unique size-two assignment therefore
costs 840000. For the cost-tie example both size-one alternatives cost 800000.
In the possible-merge example both alternatives cost 333333; merge precedence
determines the reported reason.

The replay example exercises explicit optional defaults versus omitted defaults.
Ordinary parsed JSON treats numeric `0` and `0.0` as equivalent measurements;
participants should additionally test their normalization with distinct lexical
representations and permuted detection lists. These examples are deliberately
small; they do not exhaust validation, corruption, aliasing, or resource coverage.
The fixed streaming workload and budgets are in contract section 13. No throughput
or feasibility baseline has been measured by publishing these fixtures.
