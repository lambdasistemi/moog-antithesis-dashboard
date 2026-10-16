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
8. Collector images are pinned and updated by the automatic deployment
   described below; reporter images stay manual. Dry-run the collector
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
DASHBOARD_DRY_RUN=1 bb publish
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

## MPFS status publication

As the operator, I inspect two independent MPFS cards and their GitHub feeds.
Issue30 reports collector-legacy-mpfs (container mpfs-compose-mpfs-1), used by the
dashboard collector. Issue37 reports moog-role-legacy-mpfs (container mpfs-mpfs-1),
used by the oracle and agent. Both are legacy v1.3.0 on preprod. Matching image
versions never establish that these are the same deployment. Do not substitute
umpfs or use the Antithesis proxy readiness probe as MPFS evidence.

Each reporter samples every minute, publishes meaningful changes and sends a
five-minute heartbeat. Container state, image, API response, readiness and slot
observations are meaningful; elapsed uptime and reported_at alone are excluded
from comparison. Failed writes retain the previous successful comparison and
retry on the next sample. The collector reads STATUS_ISSUE_MPFS_COLLECTOR=30
and STATUS_ISSUE_MPFS_ROLES=37 separately and retains each last-good value with
its own timestamp. Reports more than fifteen minutes old are stale.

The read-only GET /tokens response supplies indexerStatus. The reporter discards
token records and other response fields. Synchronization is observed only when
ready is boolean and both tips are nonnegative safe integer slots with the
network tip at least as large as the indexer tip. Otherwise it is unmeasured.
Lag is networkTip minus indexerTip against this backend's own Ogmios observation;
it does not establish independently verified network freshness. API availability
and a running container are displayed separately from indexer synchronization.

The [legacy v1.3.0 API](https://github.com/cardano-foundation/mpfs/blob/fb8786967e7e7e21d46a7ca0ba90789dd5903f65/off_chain/src/service/signingless/public/openapi.json)
exposes these fields. Its block-height wording conflicts with the
[indexer implementation](https://github.com/cardano-foundation/mpfs/blob/fb8786967e7e7e21d46a7ca0ba90789dd5903f65/off_chain/src/indexer/indexer.ts),
which assigns Ogmios slot values. The dashboard therefore labels them as slots,
without converting them into seconds or inventing a readiness threshold.

### Install, update and rollback

Use reporter/mpfs-compose.yaml with reporter/compose.yaml beside it. Provision
the existing repository-scoped issue-write credential as a mounted file at
/srv/moog-status-reporter/status-token, owner UID1000, mode0400; never copy it
into the Compose environment. Obtain DOCKER_GID from getent group docker. Set
STATUS_ISSUE_NUMBER, MPFS_SERVICE_ID and MPFS_PROBE_URL in the host-local .env.
The collector reporter uses https://mpfs.plutimus.com/tokens. The role reporter
uses http://127.0.0.1:3000/tokens with network_mode: host in its override. Neither
private endpoint coordinates nor response bodies enter its published snapshot.

Pin a merged Nix image in deployed-image.yaml. Retain the previous override for
rollback. From the reporter service directory, run these same commands for an
install or an image update; the named project keeps its comparison cache.

~~~sh
docker compose -p moog-mpfs-reporter -f mpfs-compose.yaml -f deployed-image.yaml pull
docker compose -p moog-mpfs-reporter -f mpfs-compose.yaml -f deployed-image.yaml up -d
docker compose -p moog-mpfs-reporter -f mpfs-compose.yaml -f deployed-image.yaml ps
~~~

Verify the expected service_id, container image and reported_at in that host's
GitHub feed, then the corresponding public data.json source. Capture the running
reporter image ID, merged revision and public observation together. A successful
PATCH does not establish public dashboard publication until Pages is checked.

To roll back an update, restore the previous deployed-image.yaml and run up -d
with the same project and files. To undo the first installation, run down with
those files; retain the comparison cache and let the last report expire visibly.
When a source is stale, inspect its own issue timestamp, reporter execution,
file credential access and GitHub write outcome. Do not refresh an old verdict
or manually relabel a stopped reporter as healthy.

## Delivery progress

Oracle, agent and monitor issue reporting is deployed. MPFS has separate
reporter and collector paths for the two legacy instances; production evidence
is attached to its delivery ticket. Current Koios balance collection and the
ADA account cards are implemented; their installation uses the same collector
image and publication path. Configure its GitHub read access to the source
repository. Expense history, locked-fund accounting and provider observations
bound to an exact chain point remain open.
The funds tickets retain balance and historical accounting as distinct acceptance
requirements. See the [system design](transport-design.md) and issues
[MPFS](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/29),
[agent/oracle](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/23)
and [requester](https://github.com/lambdasistemi/moog-antithesis-dashboard/issues/24).

## Monitor publication and snapshot API

The existing Antithesis freshness producer publishes a sanitized verdict through
the Nix reporter image to status issue34. Its production wrapper preserves the
existing notification behavior, publishes failure as a generic verdict and
retains a five-minute producer interval. File-mounted status credentials stay
on the producing host. The collector reads STATUS_ISSUE_MONITOR=34; inspect the
issue timestamp and next producer execution when recovering a stale source.

On NixOS the wrapper explicitly invokes /run/wrappers/bin/sudo for the Docker
command: the service PATH excludes the setuid wrapper directory. A non-setuid
sudo from the system profile fails in the scheduled service even when an
interactive operator invocation succeeds. Production receipt records this live
boundary check. Host unit drop-ins must be retained when rebuilding NixOS.

Swagger UI lives at swagger.html beside openapi.json and data.json. The schema
describes the public snapshot, not the external provider APIs. Try it out reads
the same directory snapshot. CDN assets are version-pinned with integrity hashes;
the specification is not sent to an external validation service. Schema CI
checks recorded actual and unavailable snapshots and refuses malformed claims.

## Automatic collector deployment

As a dashboard maintainer, I merge a checked change and the running collector
and public page update without manual deployment commands. The collector host
polls GitHub on a timer, and one Nix-packaged Babashka command does everything.
The timer runs a reviewed build installed on the host, never code resolved from
main at tick time:

~~~sh
collector-deploy update
collector-deploy status
collector-deploy rollback
~~~

`update` deploys only the current head of main, and only when its complete push
CI run succeeded: every job is successful or skipped, and the collector image and
reproduction jobs are both successful. Pull request runs, failed runs, pending
runs and an older revision are refused with the reason printed and recorded.
Image publication alone is not enough, because it precedes the final
reproduction job. The head is read again after the image is pulled; if main
moved, nothing deploys.

The selected image is pulled by commit tag, bound to its registry digest, and
pinned in `deployed-image.yaml` as `repository:tag@sha256:digest`. If the tag
ever resolves to another digest, the update is refused. Only the collector
service is recreated, with the existing `compose.yaml`, mounts, cache volume,
secrets and environment untouched, and Compose never pulls (`--pull never`).
Repeating the same revision changes nothing.

Before anything is changed the host must be fully readable. The command refuses,
and changes nothing, when Docker or Compose cannot list the containers or inspect
them, when another container runs an image of the collector repository (found by
its configured reference or by what its image id is known as), or when the
project has more than one collector container. A lookup that fails is never
taken as evidence that nothing is running. A second running `update` exits at
once on the deployment lock.

~~~mermaid
flowchart LR
  poll[Timer polls main] --> open{Unfinished rollout?}
  open -- yes --> restore[Restore the earlier pin first]
  open -- no --> ci{Head CI complete and green?}
  restore --> ci
  ci -- no --> refuse[Refuse and record]
  ci -- yes --> host{Host state readable, no other publisher?}
  host -- no --> refuse
  host -- yes --> pin[Pull and pin by digest]
  pin --> up[Recreate collector]
  up --> start{Stays running?}
  start -- no --> back[Restore previous pin]
  start --> cycle{Fresh snapshot valid and published by this collector?}
  cycle -- no --> back
  cycle -- yes --> pages{Public page matches every renderer file?}
  pages -- yes --> done[Healthy and published]
  pages -- no --> wait[Report Pages pending or failed]
~~~

The diagram shows the verdicts. A refused revision never reaches the collector.
Everything after the first change is one recovery scope: a collector that fails
to start, a first cycle that does not publish, a snapshot that is invalid, or any
error raised while observing, gets the previous pin restored and the failure
recorded. A healthy collector whose page has not caught up is reported on its
own, without a rollback and without touching GitHub Pages.

A snapshot counts only when it validates against the contract shipped inside the
selected image (`site/openapi.json`), its generation time parses and is newer
than the rollout, and the selected collector's own log says it published that
exact time. The public page counts only when every file of the image's `site`
directory, `index.html` included, is served with identical content and
`data.json` validates and is not older than the collector's snapshot. If any
renderer file cannot be inspected, Pages is reported pending, never ok.

Exit codes are 0 deployed or already current, 1 failed and rolled back (or the
rollback itself failed), 2 refused, 3 CI still running, 4 Pages pending, 5 Pages
build failed. Pages pending or failed is re-observed on the next `update` without
redeploying; the command never deletes, resets or recreates Pages.

### Rollback state

Before the first change `update` writes the previous override, the identity of
the image that was running (its image id, not only its tag) and an in-progress
marker (`rollout.json`) in `deploy-state/`. A rollback pins the recorded pin; if a
mutable tag no longer resolves to the recorded image it pins the image id itself.
A rollback succeeds only when the restored collector stays up and publishes a
fresh valid snapshot; then the state names the restored revision and digest, the
newer Pages state is dropped, and the marker is removed. If a rollback fails, the
state says `unhealthy`, the marker and previous-pin record stay, and the unit
stays failed.

If a run dies mid-rollout (power loss, kill), the next `update` finds the marker,
restores the earlier pin first and only then continues; the original previous pin
is never overwritten by a later run. A revision that failed, was interrupted or
was rolled back by `rollback` is not deployed again until main has a new head or
`update --retry` is given.

### Install on the collector host

The supported installation is a persistent user timer (`loginctl` shows
`Linger=yes`, so it survives logout and reboot) running a reviewed build from a
user-owned, GC-rooted Nix profile. No host rebuild and no write to
`/etc/systemd/system` are needed. Install a reviewed revision:

~~~sh
nix build --profile ~/.local/state/nix/profiles/collector-deploy \
  github:lambdasistemi/moog-antithesis-dashboard/<reviewed-40-character-commit>#collector-deploy
mkdir -p ~/.config/systemd/user
cp deploy/systemd/user/collector-deploy.service deploy/systemd/user/collector-deploy.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now collector-deploy.timer
~~~

The `cp` source is a checkout of the same reviewed commit. The profile link keeps
the build alive across garbage collection; the unit runs
`~/.local/state/nix/profiles/collector-deploy/bin/collector-deploy`. Check with
`systemctl --user list-timers collector-deploy.timer`, run once with
`systemctl --user start collector-deploy.service`, and read it with
`journalctl --user -u collector-deploy.service`. To upgrade, review the new
commit and run only the `nix build --profile` command with its hash; the next tick
runs it. To return to the previous build,
`nix-env --profile ~/.local/state/nix/profiles/collector-deploy --rollback`.

A system-wide alternative is `deploy/systemd/collector-deploy.service` and its
timer with a root profile at `/nix/var/nix/profiles/collector-deploy`; on NixOS
declare them in the machine configuration rather than copying files.

The package carries `bb`, `gh`, `curl` and the snapshot validator; `docker` with
the Compose plugin comes from the host PATH, and the user must be in the docker
group. The GitHub token is the existing read file and reaches the command as a
credential file; it needs Actions, contents and Pages read access. It is never an
argument, never logged, and no token, SSH access, inbound receiver or Docker
socket is added to the collector. State lives in `deploy-state/` beside the
stack: `state.json`, `history.jsonl`, the previous override, `rollout.json` and
`bindings.json`.

### Status and rollback

`status` prints the pinned image, the running container, the deployed revision,
collector and Pages health, the previous pin, any rollout in progress, the
revision that will not be redeployed and the last failure. `rollback` restores the
previous pin under the same readiness rule as above and suppresses the revision it
replaced; it does nothing when no previous pin is recorded. If a rollback fails,
`history.jsonl` records `rollback-failed`; fix the cause and run `update` or
`rollback` again, which completes the recovery from the preserved state, or
restore `deploy-state/previous-override.yaml` over `deployed-image.yaml` by hand
and run `docker compose up -d`.

Timeouts are `DEPLOY_STARTUP_SECONDS`, `DEPLOY_SNAPSHOT_SECONDS` and
`DEPLOY_PAGES_SECONDS`.

### Evidence and its limits

`deploy-controls` runs the packaged command against disposable fixtures behind
fake `gh`, `docker` and `curl`: every refusal, discovery failure, both rollback
causes, thrown errors, interrupted rollouts, moved tags, Pages pending and
failure, and serialization. `deploy-live-smoke` (`nix run .#deploy-live-smoke`,
run by CI) runs the same command against real Docker and Compose with a
disposable registry, project and offline collector, and reads the live GitHub
Actions, Pages and gh-pages answers read-only. It proves digest inspection,
`--pull never`, startup and cycle rollback and the image's own schema against
reality. It does not prove the installed timer on the production host; that
criterion is accepted only when one merged visible change is observed to reach
the public page through the installed automation.
