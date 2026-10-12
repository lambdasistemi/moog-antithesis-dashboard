# Plan (one vertical slice)
1. property-chip-every-node: `props_for` counts all nodes and uses a new cache namespace; empty responses are not cached; the `props-summary` fixture check (with its break) lands in flake check, CI and the reproduce matrix; README chip semantics updated. Runnable end to end with fixtures only.

Constraints: the detail file's population is the definition — the summary must equal what the detail embeds for the same response; no page changes; the evidence run's numbers (19/50, 31 failing) come from the live API and are reproduced by a fixture with the same shape.
