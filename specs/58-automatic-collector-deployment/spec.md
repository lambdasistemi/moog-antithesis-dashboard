# Automatic collector deployment

## User story

As a dashboard maintainer, I merge a checked change and observe the running
collector and the public dashboard update without manual deployment commands.

## Behaviour and the control that executes it

| Behaviour | Control in `tests/deploy/controls.clj` |
|---|---|
| Pull request, failed, pending, superseded revisions do not deploy | refusal controls: PR-only run, PR revision, failed CI, pending CI, newest attempt failed, unsuccessful or missing required job, head moved |
| Only a published, digest-bound image is selected | image not published, tag moved after binding |
| One publisher at a time | competing publisher, held deployment lock |
| Repeating a revision changes nothing | second `update` adds no rollout |
| Startup or first cycle failure restores the previous pin and records it | startup crash, cycle failure, no new snapshot, unrecoverable rollback |
| Cache, mounts and settings are preserved | override differs only in the image pin; no down, volume or prune call |
| Pages pending or failed is not a collector failure | pending and failed Pages keep the new image, report separately, recover on the next update, never reset Pages |
| Credentials stay in files | token absent from arguments, output and history |

## Out of scope

Reporters, Moog, the Antithesis proxy, source collection, wallet accounting,
report authorization, and any automatic Pages reset.

## Acceptance still pending after merge

One merged visible change observed through the installed timer with no manual
image or Compose edit. Fixtures prove the command; only the installed host can
prove that criterion.
