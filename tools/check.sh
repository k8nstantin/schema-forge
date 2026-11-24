#!/usr/bin/env bash
# Everything that must pass before a change is called done, in one command: the same here and in CI (specs/rules.xml
# one-check). Each part runs when what it checks exists, so a part a task adds joins on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }

step "Rust: format"
cargo fmt --all --check

step "Rust: lint"
cargo clippy --workspace --all-targets --all-features --quiet -- -D warnings

step "Rust: tests (the kit, the architecture check and the spec check among them)"
if ! out=$(cargo test --workspace --all-features 2>&1); then
    # Each failing test's own output, whole: what broke and where.
    awk '/^---- .* stdout ----$/,/^failures:$/' <<<"$out" | head -150
    grep -E '^error' <<<"$out" | head -20
    exit 1
fi
grep -c '^test result: ok' <<<"$out" | xargs printf '%s test binaries passed\n'

step "All checks passed"
