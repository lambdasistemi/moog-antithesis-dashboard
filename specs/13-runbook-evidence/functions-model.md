# Functions model
- `verify/reproduce.sh`: no required arguments; optional `--list` prints the matrix; exits non-zero if any green fails, any red does not fire, any restore leaves the tree dirty, or the tree was dirty at start.
- `deploy/compare-live.sh`: `LIVE_URL` (default the published page's data.json), `OUT` (default a temp dir); environment for the collector container as in `collect/compose` documentation; exits 0 with a difference report, non-zero on structural mismatch or fetch failure.
