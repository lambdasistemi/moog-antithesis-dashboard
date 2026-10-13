# MPFS status

## Operator story

As an operator, I see the collector and Moog-role MPFS services separately, with their deployed container state, API reachability, indexer observation and report age. A successful Moog facts read cannot stand in for this report.

## Requirements

Each service publishes one bounded allowlisted snapshot to its own GitHub issue. Samples occur every minute; meaningful changes publish immediately and unchanged observations publish after five minutes. Uptime and timestamp changes alone do not trigger a write; failed writes do not advance comparison state.

The collector accepts only the expected service identity, known keys, valid scalar values and a producer timestamp no more than fifteen minutes old and never in the future. Failed sources retain their own last good observations and timestamp. Container, API and indexer observations remain separate; old observations never appear healthy.

The legacy read-only tokens endpoint can supply network and indexer slots. Lag is the difference against the same backend's reported network tip, without claiming independent network verification. Missing, invalid or inverted tips mean synchronization is unmeasured. Raw token records, response bodies, logs, credentials and private endpoint coordinates never enter the payload.

## Scope

Two legacy preprod services, existing Nix reporter image and GitHub collection boundary. No migration, wallet changes, on-chain writes, SSH in reporter or collector, or additional worker seats. This existing seat implements and verifies; no independent audit claim.
