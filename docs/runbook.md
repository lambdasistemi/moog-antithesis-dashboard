# Operator runbook: moog Antithesis dashboard

As the pipeline operator, I bring the dashboard up, keep it up, and recover
when a source goes stale. I inspect the published inputs before trusting an
old service observation or wallet balance. The live page, the collection loop and the push transport are
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
8. Pin deployed images to the merged commit SHA. Dry-run the collector
   first and compare with `deploy/compare-live.sh`, setting all installed
   `STATUS_ISSUE_*` numbers. The legacy timer is already disabled; leave
   it disabled. Save the current Compose configuration and image SHA
   before updating; rollback restores that previous Nix-built service.
   Keep the existing cache volume and never run two publishers together.

Oracle and agent reporters sample every minute, publish on meaningful
changes, and send a five-minute heartbeat. The collector publishes every
ten minutes. The monitor hook is one-shot; its external scheduler must
produce fresh reports within the fifteen-minute staleness window.

The table describes recommended credential scopes, not an attestation of
every deployed token. The current collector uses existing operator tokens
with broader permissions. Issues-write covers all issues in the selected
repository, not one issue. The reporter's Docker socket grants privileged
Engine API access despite the read-only container configuration.

## Recovery

When a card goes stale, in order: is the reporter container running
(`docker ps`, `docker logs` — one failing report logs one line and the
loop continues)? Is its token expired (table above)? Is the host clock in
sync (more than 15 minutes behind shows stale even while reporting, more
any time ahead is refused)? Can the collector reach api.github.com?
What does the source error on the page banner say, and how old is
`last_success`?

Dry-run commands (no token needed, nothing is sent or pushed):

```sh
REPORTER_ROLE=oracle REPORT_DRY_RUN=1 ./reporter/report.sh
REPORTER_ROLE=agent REPORT_DRY_RUN=1 ./reporter/report.sh
echo "OK run_id=$id age=${age}s maximum=${max}s" | REPORT_DRY_RUN=1 ./reporter/push-verdict.sh
DASHBOARD_DRY_RUN=1 ./deploy/publish.sh
STATUS_ISSUE_ORACLE=27 STATUS_ISSUE_AGENT=28 STATUS_ISSUE_MONITOR=... \
  IMAGE=ghcr.io/lambdasistemi/moog-antithesis-dashboard:<merged-sha> \
  ./deploy/compare-live.sh
```

The comparison stores its local JSON in a fresh `snapshot.*` directory
under `OUT_DIR`. It compares structure and reports value differences;
it ignores source freshness fields and the monitor verdict, so exit zero
does not certify service health or monitor cutover. The reproduction
matrix uses controlled fixtures for reporter stopping and recovery;
production outage and recovery evidence must be recorded separately.

## Rejected transports

Four designs were considered for host-to-collector status and rejected:
the receiver service (a new always-on public endpoint to supervise and
patch for the same outcome), pushing a git branch (the token could write
`gh-pages`), gists (classic PAT with account-wide scope, no fine-grained
option), and on-chain facts (barred: the dashboard never writes chain
data). The per-issue edit won: no listening service and the smallest token
blast radius.

## Public wallet configuration and Koios collection

The collector reads config/wallets.json from the source repository at one commit
per cycle, defaulting to main. WALLET_CONFIG_REF can pin a preview to a specific
source commit. The deployed balance source supports verified preprod addresses.
Provider endpoints are fixed by the application, not configurable in the JSON.

GitHub holds wallet query coordinates, not a balance issue supplied by a second
publisher. Configure role, verified network, active public addresses and historical
address scope in a versioned public document. Record the deployed wallet-to-role
mapping evidence; never copy wallet files or private keys into the collector or
repository. A testnet address alone does not determine which testnet to query.

The collector reads the document at one commit, validates its schema and scope,
chooses an allowlisted Koios endpoint for that network and queries Koios directly.
Antithesis follows the same direct API collection pattern for tests. The existing
publication gate publishes derived wallet observations in gh-pages; inspect the
snapshot there or through the dashboard. A separate wallet status publisher is
not part of this design.

During recovery, distinguish a GitHub configuration failure from a Koios provider
failure. The source must show its last successful query time, configured address
scope and revision, network and history coverage. Rereading coordinates cannot
refresh a stale balance. Pipeline and wallet cards also refuse a healthy/current
label when their source is stale or its last observation is over fifteen minutes
old, even if a cached boolean verdict still says OK. After address rotation, old cached observations retain
the old scope and remain stale until the new scope is queried successfully.
Unavailable data is never zero ADA. Complete history is never inferred from one
page of transactions. Fee attribution and locked funds need transaction evidence.

## MPFS status publication (planned)

MPFS needs its own reporter and status issue. Bind it to the legacy service used
by the collector; do not substitute umpfs or use the Antithesis proxy readiness
probe. Publish container/image identity and bounded API probe outcome. Inspect
that issue first when the MPFS source is stale, then verify reporter execution,
GitHub write access and producer timestamps. Running and reachable do not imply
chain synchronization; synchronization remains unmeasured until supported.

## Delivery progress

Oracle and agent issue reporting is deployed. Monitor reporting is merged but
installation and fresh production verdict evidence remain open. MPFS reporting remains uninstalled. Current Koios balance collection and the
ADA account cards are implemented; their installation uses the same collector
image and publication path. Configure its GitHub read access to the source
repository. Expense history, locked-fund accounting and provider observations
bound to an exact chain point remain open.
The funds tickets retain balance and historical accounting as distinct acceptance
requirements. See the [system design](transport-design.md) and issues
[MPFS](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/29),
[agent/oracle](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/23)
and [requester](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/24).
