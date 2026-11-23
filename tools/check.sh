#!/usr/bin/env bash
# Everything that must pass before a change is called done, in one command: the same here and in CI. Each part runs
# when what it checks exists, so a part added later joins on its own.
#
#   tools/check.sh          every check
#   tools/check.sh --quick  no browser tests
set -euo pipefail
cd "$(dirname "$0")/.."

quick=false
[[ "${1:-}" == "--quick" ]] && quick=true

step() { printf '\n== %s\n' "$*"; }

step "Rust: format"
cargo fmt --all --check

step "Rust: lint"
cargo clippy --workspace --all-targets --quiet -- -D warnings

step "Rust: tests, the conformance kit and the architecture check"
if ! out=$(cargo test --workspace 2>&1); then
    grep -E 'FAILED|panicked|error|failures:|^----' <<<"$out" | head -80
    exit 1
fi
grep -c '^test result: ok' <<<"$out" | xargs printf '%s test binaries passed\n'

if [[ -f canvas/package.json ]]; then
    step "Canvas: install"
    (cd canvas && npm ci --no-audit --no-fund --silent)
    step "Canvas: types and build"
    (cd canvas && npm run --silent build)
    if [[ -f canvas/playwright.config.ts ]] && ! $quick; then
        step "Canvas: browser tests, every engine"
        (cd canvas && npm run --silent e2e)
    fi
fi

step "All checks passed"
