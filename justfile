set shell := ["bash", "-cu"]

default:
    @just --list

ci:
    nix flake check --no-eval-cache

shellcheck:
    nix run --quiet .#shellcheck

format-check:
    nix run --quiet .#format-check

format:
    shfmt -i 4 -w collect/collect.sh deploy/cycle.sh deploy/publish.sh deploy/loop.sh

syntax:
    nix run --quiet .#syntax

secrets-gate:
    nix run --quiet .#secrets-gate

publish-gate:
    nix run --quiet .#publish-gate

preview-smoke:
    nix run --quiet .#preview-smoke

preview-verify url:
    nix run --quiet .#preview-verify -- "{{url}}"

site-check:
    nix run --quiet .#site-check

loop-runtime:
    nix run --quiet .#loop-runtime

image-clean:
    nix run --quiet .#image-clean
