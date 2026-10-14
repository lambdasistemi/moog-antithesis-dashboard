# Implementation plan

1. Repair the shared MPFS image validator with an executable reporter regression and malformed/private digest controls. Preserve the exact observed pinned image and existing privacy/cadence contract.
2. Compute alarm entries from the current snapshot and refresh state, deduplicated by source. Render a separate pane, pane badge and document title, share existing pane persistence, and preserve responsive layout and report navigation.
3. Restore monitor publication in the declared Nix timer through a linked infrastructure PR. Retain existing check and notification behavior, and five-minute freshness publication.
4. Run native gates, browser fixtures and exact-head hosted CI, merge and deploy immutable native images, verify both real GitHub feeds advance and the public page matches the merged source.

Existing solo seat owns coordination, implementation and local review. No additional worker or independent audit is claimed. Preserve canonical dirty checkout, unrelated infrastructure PRs and production caches.
