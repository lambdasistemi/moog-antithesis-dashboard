# Operator runbook and end-to-end evidence (#13)

## User story
As a reviewer, I run one command from a clean checkout and observe each verification item executed, including break, red, restore, green for every new check. As the operator, I find every token and every deployment step in one runbook.

## Requirements
- reproduce-one-command: `nix run .#reproduce` (backed by `verify/reproduce.sh`) runs, from a clean checkout, every verification item of the epic: the green suite for each new check, then for each new check one break of its subject, the targeted check going red, the restore, and the check green again; each red/green is recorded with exit codes. It refuses to start on a dirty tree, proves the tree clean after every restore, and never pushes anything.
- planted-credential-refuses-publication: the reproduce script proves a planted credential refuses publication at each staged location (publish-gate cases) and that no smoke leaks its planted literals into payloads, issue bodies, logs or process lists.
- image-export-clean: the reproduce script proves the built image export and the dry-run container environment are clean (image-clean legs).
- reporter-stop-shows-stale-and-recovers: the reproduce script proves stopping a reporter turns its section stale with the correct last-success time and that it recovers on the next push (host-stale legs for oracle, agent and monitor).
- every-new-check-red-then-green: the break matrix covers every check introduced by this epic (reporter-smoke, push-verdict-smoke, schema-reject, host-stale, publish-gate, the site render test, loop-runtime, container-smoke, image-clean, secrets-gate) — one break per check, targeted red, restore, green.
- compare-live-tool: `deploy/compare-live.sh` runs the collector container in a dry run against the mounted production secrets and compares its `data.json` with the live page's `data.json`, ignoring the volatile fields it names (generated_at, started_at, refresh_seconds, every `sources.*` status/error/last_success, the `monitor` verdict, per-run progress timestamps); it reports each remaining difference and exits non-zero on structural mismatch (missing sections, type changes, host lists). It makes no outward write and needs no token with secrets removed.
- runbook-lists-all-tokens: `docs/runbook.md` lists every secret this system uses — the three status tokens, the Pages push token, the GitHub read token, the Antithesis API key, the moog read environment — with where it is created, who rotates it, its maximum lifetime, and exactly what breaks while it is expired.
- runbook-carries-operator-checklist: the runbook contains the operator action checklist (create the three status issues and their tokens, the Pages push token, the read token, the Antithesis key file and moog read env, place secret files 0400/uid 1000 on each host, start the reporters through compose, add the monitor push hook, flip the GHCR packages public after first push to main, dry-run and cutover rules) and the recovery procedure for a stale reporter.
- docs-name-rejected-alternatives: one place in the docs names all four rejected transports — receiver service, git branch push, gists, on-chain facts.

## Out of scope
New product behavior; the collector, reporters and page contracts do not change in this child.
