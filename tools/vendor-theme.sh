#!/usr/bin/env bash
# Rebuild the checked-in Web Awesome theme control with esbuild 0.25.5.
# Only the radio components and theme tokens are included; no runtime CDN.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
THEME_TMP=$(mktemp -d)
trap 'rm -rf "$THEME_TMP"' EXIT
[[ $(esbuild --version) == 0.25.5 ]] || { echo 'Use esbuild 0.25.5' >&2; exit 1; }
curl --fail --silent --show-error --location \
    https://registry.npmjs.org/@awesome.me/webawesome/-/webawesome-3.14.0.tgz \
    --output "$THEME_TMP/webawesome.tgz"
printf '%s  %s\n' ffc602ca68be6cb34520d728c2effceee7819559755d3d5aa7ca78f39b0fdf55 "$THEME_TMP/webawesome.tgz" | sha256sum --check
tar -xzf "$THEME_TMP/webawesome.tgz" -C "$THEME_TMP"
cat >"$THEME_TMP/entry.js" <<'JS'
import './package/dist-cdn/styles/themes/default.css';
import './package/dist-cdn/components/radio-group/radio-group.js';
import './package/dist-cdn/components/radio/radio.js';
JS
esbuild "$THEME_TMP/entry.js" --bundle --format=esm --minify --legal-comments=inline \
    --outfile="$ROOT/site/theme-components.js"
cp "$THEME_TMP/package/LICENSE.md" "$ROOT/site/theme-components.LICENSE.txt"
printf '\nLit dependencies\n\n' >>"$ROOT/site/theme-components.LICENSE.txt"
cat "$ROOT/tools/theme-third-party.txt" >>"$ROOT/site/theme-components.LICENSE.txt"
