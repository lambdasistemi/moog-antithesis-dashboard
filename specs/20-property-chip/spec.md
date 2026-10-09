# The property chip counts every property node (#20)

## User story
As the operator, I read a run's chip and see the run's true property state: any failing property, at any node level, makes the chip non-green and names it.

## Requirements
- chip-counts-every-node: the run property summary counts every node in the properties response — group nodes included, exactly the population the per-run detail file embeds — so the chip and the detail cannot disagree. For the evidence run (7e206055…-62-14: 39 groups, 31 Failing + 8 Passing; 11 non-group nodes, all Passing) the chip reads 19/50 with 31 failing names, not 11/11.
- chip-red-when-any-node-fails: the failing list carries every non-Passing node's name as it comes (group names include their measured values, e.g. `Praos block diffusion p95 latency (100052.7ms) < 5000.0ms`).
- empty-not-cached-forever: a properties response with an empty node list produces a summary but is NOT written to the summary cache — the next cycle refetches — so a completed run whose results land late never freezes as `{total: 0}`.
- stale-pre-fix-cache-ignored: the summary cache uses a new namespace (new filename shape), so summaries cached by the pre-fix collector are never served by the fixed one.
- props-summary-fixture-check: a fixture check builds fake properties responses with the real taxonomy (failing groups, passing groups, plain leaves, event leaves, one-sided empty) and asserts: counts cover all nodes; failing groups appear by name; an empty response leaves no cache file and is retried; the runs summary in data.json uses the same numbers as the detail. One break of the subject (re-adding the group filter) must turn the check red, then restore green. Wired like the other fixture checks: flake check, its CI job, and a row in the reproduce matrix with that break.
- docs-chip-semantics: the README's description of the chip counts states the every-node semantics.

## Rejection behavior
Unchanged from the collector's contract; this child only changes what the summary counts and caches.

## Out of scope
Changing which properties Antithesis reports; the detail page's rendering; the page layout.
