# Plan (one vertical slice)
1. monitor-push-end-to-end: `reporter/push-verdict.sh` with a dry-run mode and its smoke; the monitor branch of the shared validator; `src_monitor` reading `STATUS_ISSUE_MONITOR`; monitor legs in `schema-reject` and `host-stale`; publish-gate refusal cases for a planted URL and token in the monitor payload; README and design-doc updates. Runnable end to end without any token (dry runs).

Constraints: the page shape `{last, ok}` never changes; `data.json` legitimately carries URLs in `runs[]`, so URL refusal is scoped to the monitor payload; the verdict vocabulary stays `OK|FAIL|STALE`; issue numbers are configuration (`STATUS_ISSUE_MONITOR`); the push step needs only Issues-write on this repo.
