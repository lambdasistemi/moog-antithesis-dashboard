# Oracle and agent push status through GitHub issues (#11)

## User story
As the operator, I start a reporter container on the oracle or agent host with one fine-grained token and observe that host's section on the page update every 5 minutes, and turn stale with the right last-success time when I stop it.

## Requirements
- reporter-payload-matches-today: containers whose name matches `moog` with name, image (registry prefix dropped) and status; on the agent also the count of log lines matching `exception|error` over 6 hours and `Published result` over 24 hours; plus `reported_at` (UTC, ISO 8601).
- reporter-uses-docker-api-only: the reporter talks to the Docker socket with curl; no docker CLI, no shell access, raw logs never leave the host, only counts.
- reporter-pushes-by-issue-edit: it edits the body of one status issue (number from configuration) through the GitHub API over HTTPS, token read from a file, never in argv.
- collector-validates-strictly: known keys, types, length caps, `reported_at` not in the future; anything else is dropped; a body failing validation makes the source fail.
- source-split: `hosts` becomes the sources `oracle` and `agent`; `data.json.hosts` keeps its shape; the page shows both as sources and marks the hosts section stale when either is not ok.
- last-success-is-reported-at: a source's last-success time is its payload's `reported_at`; a payload older than 15 minutes counts as failed (stale).
- ssh-gone-from-collector: every `ssh` call and host variable is removed from `collect.sh`.

## Rejection behavior
A body with extra keys, wrong types or a future `reported_at` is refused and the last good value is served, marked stale.

## Out of scope
The freshness monitor (#12); runbook (#13); page redesign.
