#!/usr/bin/env bash
set -euo pipefail
exec bb --config bb.edn --main dashboard.test-runner wallets
