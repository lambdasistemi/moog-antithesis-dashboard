# Operator runbook: moog Antithesis dashboard

How to bring the dashboard up, keep it up, and recover when a card goes
stale. The live page, the collection loop and the push transport are
described in `README.md` and `docs/transport-design.md`; this file is the
hands-on companion: tokens, hosts, cutover, recovery.

## Token inventory

| secret | where created | scope | who rotates / max lifetime | while expired |
|---|---|---|---|---|
| Oracle status token | repo owner, github.com → Settings → Developer settings | fine-grained PAT, Issues: write, this repo only | owner, at most 1 year | Oracle card goes stale with its last success time; nothing else breaks |
| Agent status token | repo owner, same place | fine-grained PAT, Issues: write, this repo only | owner, at most 1 year | Agent card goes stale with its last success time; nothing else breaks |
| Monitor status token | repo owner, same place | fine-grained PAT, Issues: write, this repo only | owner, at most 1 year | Monitor chip goes stale with its last success time; nothing else breaks |
| Pages push token (`pages-push`) | repo owner, same place | fine-grained PAT, Contents: write, this repo only | owner, at most 1 year | Publish fails, the snapshot ages, the 25-minute banner fires; reporters keep pushing (recovery is automatic on rotation) |
| GitHub read token (`gh-read`) | operator, any token with public-repo read, no scopes needed | public repos only | operator, at most 1 year | Runs, nightly receipts and all three status-issue reads fail; those sources go stale, the rest is unaffected |
| Antithesis API key (`antithesis-key`) | Antithesis tenant admin | read key for the tenant | tenant admin, per tenant policy | `runs` goes stale; every other source is unaffected |
| Moog read environment (`moog-read-env`) | moog operator: provider URL plus read-only settings only, never wallet paths | read-only view of the moog setup | moog operator, on rotation of the provider setup | `chain` and `token` fail; everything else is unaffected |

Verified on the collector host (2026-10-08): read-only `moog facts
test-runs` and `moog token` both work with the read env alone — no wallet
paths, no `being_*` identity, isolated HOME. The env file needs exactly
three settings: `MOOG_MPFS_HOST`, `MOOG_TOKEN_ID`, and (only `moog token`
reads it) `MOOG_GITHUB_PAT`. Evidence: `facts test-runs --whose cfhal`
exit 0 with 1486 facts; `token` exit 0 with the pending-request list.

## Action checklist (current state)

1. Create the three status issues on this repository (one each for the
   oracle, agent and monitor reporters) and note their numbers as
   `STATUS_ISSUE_ORACLE`, `STATUS_ISSUE_AGENT`, `STATUS_ISSUE_MONITOR`.
2. Create the three status tokens (table above) plus the Pages push token
   and the GitHub read token.
3. Create the Antithesis key file and the moog read env file (provider URL
   and read-only settings only).
4. Place secret files on each host, mode `0400`, owned by uid 1000:
   collector gets `antithesis-key`, `gh-read`, `pages-push`,
   `moog-read-env` under `/srv/moog-antithesis-dashboard/`; each reporter
   host gets its `status-token` under `/srv/moog-status-reporter/`.
5. Start the reporters through `reporter/compose.yaml`. The Docker group
   GID differs per host: run `getent group docker` on the host and export
   it as `DOCKER_GID` so the non-root reporter can read the socket.
6. Add the push hook to the monitor's script (the README one-liner: one-shot
   `docker run` of the reporter image running
   `/app/reporter/push-verdict.sh`, verdict line on stdin, token file
   bind-mounted read-only). Dry-run it first
   (`REPORT_DRY_RUN=1 ./reporter/push-verdict.sh`).
7. Flip the two GHCR packages
   (`moog-antithesis-dashboard`, `moog-antithesis-dashboard-reporter`) to
   public after the first push to main, so hosts pull without a credential.
8. Cutover order: dry-run the collector first and compare with
   `deploy/compare-live.sh`; stop the old timer before switching the
   container to the real `gh-pages` remote; keep the old checkout for one
   release as rollback; never let the old publisher and the new publisher
   write `gh-pages` simultaneously.

## Recovery

When a card goes stale, in order: is the reporter container running
(`docker ps`, `docker logs` — one failing report logs one line and the
loop continues)? Is its token expired (table above)? Is the host clock in
sync (more than 15 minutes behind shows stale even while reporting, more
than 2 minutes ahead is refused)? Can the collector reach api.github.com?
What does the source error on the page banner say, and how old is
`last_success`?

Dry-run commands (no token needed, nothing is sent or pushed):

```sh
REPORTER_ROLE=oracle REPORT_DRY_RUN=1 ./reporter/report.sh
REPORTER_ROLE=agent REPORT_DRY_RUN=1 ./reporter/report.sh
echo "OK run_id=$id age=${age}s maximum=${max}s" | REPORT_DRY_RUN=1 ./reporter/push-verdict.sh
DASHBOARD_DRY_RUN=1 ./deploy/publish.sh
LIVE_URL=... ./deploy/compare-live.sh
```

## Rejected transports

Four designs were considered for host-to-collector status and rejected:
the receiver service (a new always-on public endpoint to supervise and
patch for the same outcome), pushing a git branch (the token could write
`gh-pages`), gists (classic PAT with account-wide scope, no fine-grained
option), and on-chain facts (barred: the dashboard never writes chain
data). The per-issue edit won: no listening service and the smallest token
blast radius.
