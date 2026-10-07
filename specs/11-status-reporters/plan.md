# Plan
1. reporter: script, image, compose, CI build and push of a second image, `reporter-smoke` and payload checks.
2. collector-reader: the strict reader, source split, last-success from `reported_at`, page staleness marking, deletion of the ssh pulls, `schema-reject` and `host-stale` checks.
Constraints: the status issue numbers are configuration (STATUS_ISSUE_ORACLE, STATUS_ISSUE_AGENT); the reporter needs only Issues-write; the collector reads with its existing read token.
