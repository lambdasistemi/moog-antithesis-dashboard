# Automatic collector deployment

## User story

As a dashboard maintainer, I merge a checked change and observe the running
collector and the public dashboard update without manual deployment commands.

## Behaviour and the control that executes it

`controls` is `tests/deploy/controls.clj` (packaged command, fake adapters);
`live smoke` is `tests/deploy/live-smoke.clj` (real Docker, Compose and GitHub).

| Behaviour | Control |
|---|---|
| Pull request, failed, pending, superseded revisions do not deploy | controls: PR-only run, PR revision, failed CI, pending CI, newest attempt failed, unsuccessful or missing required job, head moved |
| Only a published, digest-bound image is selected | controls: image not published, tag moved after binding; live smoke: real registry digest bound in state |
| One publisher at a time; unreadable host state refuses before any change | controls: competing publisher, publisher known only by image id, duplicate project publishers, failing `docker ps`, `docker inspect`, `compose ps`, unrelated container not blocking, held lock |
| Repeating a revision changes nothing | controls and live smoke: second `update` adds no rollout and does not recreate the container |
| Startup, first cycle, invalid snapshot or any observation error restores the previous pin and records it | controls: startup crash, cycle failure, no new snapshot, unparseable time, schema violation, snapshot the collector did not publish, thrown observation error, unrecoverable rollback; live smoke: crashing and failing-cycle images rolled back by real Compose |
| A rollback keeps accurate state and recovery data | controls: failed rollback keeps marker and previous pin and never claims healthy, killed deployment is recovered before anything else, moved mutable tag pins the recorded image id, unready manual rollback never claims healthy, restored state carries the restored digest |
| A reverted revision is not redeployed until a new head or `--retry` | controls and live smoke: next timer refuses, new head and retry deploy |
| Snapshot validity is the image's own contract | controls with the packaged validator on malformed data; live smoke: the live gh-pages and public snapshots validate under the candidate image's schema |
| Pages pending or failed is not a collector failure; the whole renderer must match | controls: pending, failed, partial renderer, uninspectable renderer, image without `index.html`, recovery without redeploy, no Pages mutation; live smoke: published pages match the real image's files |
| Cache, mounts and settings are preserved | controls: override differs only in the image pin; no down, volume or prune call |
| Credentials stay in files | controls: token absent from arguments, output and history |
| The timer runs a reviewed installed build | controls: unit `ExecStart` is the profile binary and resolves no remote code; the install command was run into a disposable profile |

## Findings the live smoke produced

The live production snapshot did not validate under the repository's own
`site/openapi.json`: the contract rejected the `@sha256:` digest suffix of the MPFS
container image that the collector reports (`schema/mpfs.jq` already allowed it).
Used as the success gate, the schema would have rolled back every real rollout.
The pattern now allows the digest, with a schema regression.

## Out of scope

Reporters, Moog, the Antithesis proxy, source collection, wallet accounting,
report authorization, and any automatic Pages reset. One visible UI change is
included only to be observed through the automation: the footer link reads
"Source code on GitHub" (old text "Source code").

## Acceptance still pending after merge

One merged visible change observed through the installed timer with no manual
image or Compose edit. Fixtures and the disposable live smoke prove the command;
only the installed host can prove that criterion.
