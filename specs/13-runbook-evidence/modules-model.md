# Modules model
- `verify/reproduce.sh` (new): the one-command evidence runner; knows the epic's check matrix and one break per check; never pushes; owns its fixtures like the existing checks do.
- `deploy/compare-live.sh` (new): operator comparison tool; runs the collector container dry and diffs against the live page; read-only outward.
- `docs/runbook.md` (new): operator runbook (tokens, checklist, recovery, tools).
- `nix/checks.nix` (or flake apps): new `reproduce` app wrapping `verify/reproduce.sh`; `compare-live` stays a plain script (it needs operator-mounted secrets, so it is not a CI check).
- `.github/workflows/ci.yml`: one new job `Reproduce evidence` running `nix run --quiet .#reproduce`; no other job changes.
Dependency direction: reproduce reads checks through their existing nix apps; nothing in production code depends on verify/ or the runbook.
