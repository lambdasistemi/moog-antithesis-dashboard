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
    shfmt -i 4 -w collect/collect.sh deploy/cycle.sh deploy/publish.sh

syntax:
    nix run --quiet .#syntax

secrets-gate:
    nix run --quiet .#secrets-gate

publish-gate:
    nix run --quiet .#publish-gate

systemd-check:
    nix run --quiet .#systemd-check

site-check:
    nix run --quiet .#site-check
