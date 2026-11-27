#!/usr/bin/env bash
# Everything that must pass before a change is called done, in one command: the same here and in CI (specs/rules.xml
# one-check). Each part runs when what it checks exists, so a part a task adds joins on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$*"; }

# No Rust step until an objective brings a crate back (decision code-reset); each part runs when what it checks exists.
if [ -f Cargo.toml ]; then
    step "Rust: format, lint, tests"
    cargo fmt --all --check
    cargo clippy --workspace --all-targets --all-features --quiet -- -D warnings
    cargo test --workspace --all-features --quiet
fi

step "No private name in any tracked file"
if git grep -nIiE 'core_manager|core_services|gdx_services|mq_services|sec_testdb|cr_debug|piaalcm|piaclws|GDXClients|ClientKey' -- . ':!site' ':!tools/check.sh'; then
    echo "a private name is in a tracked file"; exit 1
fi
echo "none"

step "XML for everything: Markdown only where a tool looks for it by name (specs/root.xml, decision xml-for-agents)"
named='README.md CONTRIBUTING.md CODE_OF_CONDUCT.md AGENTS.md CLAUDE.md .github/copilot-instructions.md'
stray=$(git ls-files --cached --others --exclude-standard -- '*.md' | grep -vxF -f <(tr ' ' '\n' <<<"$named") || true)
mentions=$(git grep -nIoE '[A-Za-z0-9_./-]+\.md([^A-Za-z0-9_]|$)' -- . ':!site' ':!specs/reviews' |
    grep -vE ':([A-Za-z0-9_./-]*/)?(README|CONTRIBUTING|CODE_OF_CONDUCT|CHANGELOG|AGENTS|CLAUDE|copilot-instructions)\.md([^A-Za-z0-9_]|$)' || true)
if [ -n "$stray$mentions" ]; then
    [ -n "$stray" ] && printf 'a Markdown file a tool does not look for: %s\n' $stray
    [ -n "$mentions" ] && printf '%s\n' "$mentions" | sed 's/^/names a Markdown file: /'
    echo "write it as XML (docs/*.xml, rendered for people by docs/pages/docs.py) and name that"
    exit 1
fi
for f in $(git ls-files --cached --others --exclude-standard -- '*.xml'); do
    python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$f" || { echo "$f: not XML"; exit 1; }
done
echo "no stray Markdown; every XML file parses"

step "Generated files: the pages, the site and the agent files are what their sources render"
generated=(site AGENTS.md CLAUDE.md .github/copilot-instructions.md)
python3 docs/pages/build.py >/dev/null
if [ -n "$(git status --porcelain -- "${generated[@]}")" ]; then
    git status --short -- "${generated[@]}"
    echo "these differ from what specs/, the owners' folders and docs/pages render: run python3 docs/pages/build.py and commit them"
    exit 1
fi
echo "every generated file is current"

step "All checks passed"
