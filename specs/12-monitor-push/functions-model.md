# Functions model
- `reporter/push-verdict.sh`: verdict line from stdin or from the file named by `$1`; environment `STATUS_ISSUE_NUMBER`, `REPORT_REPOSITORY`, `STATUS_TOKEN_FILE`, `REPORT_API_BASE`, `REPORT_DRY_RUN`; exits non-zero on an empty verdict line, a missing token file or a failed PATCH; prints the payload in dry-run mode.
- `validate_status_payload ROLE NOW`: signature unchanged; new `monitor` branch with the data-model rules.
- `src_monitor`: emits `{last, ok, reported_at}`; fetch seam `STATUS_BODY_CMD_MONITOR` (checks only, like the other role seams).
