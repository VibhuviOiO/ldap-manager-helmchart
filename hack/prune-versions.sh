#!/usr/bin/env bash
set -euo pipefail
#
# prune-versions.sh - delete chart versions from the gh-pages branch.
#
# A published version that cannot install is worse than a missing one: Helm and
# Artifact Hub both resolve the HIGHEST version, so a broken 0.2.0 keeps winning
# over a fixed 0.1.5 and nobody ever receives the fix.
#
# This clones gh-pages into a temp directory rather than using a worktree. A
# worktree checks out the LOCAL gh-pages branch, which is often stale, and
# running `helm repo index` in an empty checkout writes an index with zero
# entries - which would wipe the published repository.
#
# Usage:
#   hack/prune-versions.sh --dry-run 0.1.0
#   hack/prune-versions.sh 0.1.0 0.1.1
#
# Run it as a script (`bash hack/prune-versions.sh ...`), never by pasting it
# into a shell: `set -e` in an interactive session exits your terminal.

DRY_RUN=false
VERSIONS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=true ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) VERSIONS+=("$arg") ;;
    esac
done

if [ "${#VERSIONS[@]}" -eq 0 ]; then
    echo "usage: hack/prune-versions.sh [--dry-run] <version> [version...]" >&2
    exit 2
fi

command -v helm >/dev/null || { echo "helm 3 is required" >&2; exit 1; }

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

REMOTE=$(git config --get remote.origin.url || true)
if [ -z "$REMOTE" ]; then
    echo "no remote.origin.url in $(pwd)" >&2
    exit 1
fi

# git@github.com:OWNER/REPO.git  or  https://github.com/OWNER/REPO(.git)
slug=$(printf '%s' "$REMOTE" \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')
owner=${slug%%/*}
repo=${slug##*/}
pages_url="https://${owner}.github.io/${repo}"
echo "repository: ${owner}/${repo}"
echo "pages url : ${pages_url}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> cloning gh-pages"
git clone --quiet --branch gh-pages "$REMOTE" "$WORK/gh-pages"
cd "$WORK/gh-pages"
echo "    HEAD $(git rev-parse --short HEAD) — $(git log -1 --format=%s)"

# Guard 1: the checkout must actually contain charts. An empty checkout is the
# exact mistake that produces a zero-entry index.yaml.
chart_count=$(find . -maxdepth 1 -name '*.tgz' -type f | wc -l | tr -d ' ')
if [ "$chart_count" -eq 0 ]; then
    echo "ERROR: gh-pages contains no .tgz files; refusing to rewrite the index" >&2
    exit 1
fi
echo "    ${chart_count} chart(s) present:"
find . -maxdepth 1 -name '*.tgz' -type f -exec basename {} \; | sed 's/^/      /'

echo "==> removing"
removed=0
for v in "${VERSIONS[@]}"; do
    f="ldap-manager-${v}.tgz"
    if [ -f "$f" ]; then
        rm -f "$f"
        removed=$((removed + 1))
        echo "    - ${f}"
    else
        echo "    = ${f} not present, nothing to do"
    fi
done
if [ "$removed" -eq 0 ]; then
    echo "nothing removed; leaving gh-pages alone"
    exit 0
fi

echo "==> regenerating index.yaml"
helm repo index . --url "$pages_url"

# Guard 2: the new index must list the charts that are actually here, and must
# not be empty.
python3 - <<'PY'
import sys, glob, yaml
index = yaml.safe_load(open('index.yaml'))
entries = index.get('entries') or {}
versions = sorted(v['version'] for v in entries.get('ldap-manager', []))
on_disk = sorted(p[len('ldap-manager-'):-len('.tgz')]
                 for p in glob.glob('ldap-manager-*.tgz'))
print('    index lists:', versions or '<nothing>')
print('    files       :', on_disk or '<nothing>')
if not versions:
    print('ERROR: regenerated index has no versions', file=sys.stderr)
    sys.exit(1)
if versions != on_disk:
    print('ERROR: index and directory disagree', file=sys.stderr)
    sys.exit(1)
PY

if [ "$DRY_RUN" = true ]; then
    echo
    echo "DRY RUN: nothing committed. Files removed and index regenerated in:"
    echo "  $WORK/gh-pages"
    trap - EXIT
    exit 0
fi

echo "==> committing and pushing"
git add -A
git commit --quiet -m "chore: drop $(IFS=', '; echo "${VERSIONS[*]}") from the chart repository"
git push origin gh-pages

echo
echo "done. Remaining versions:"
helm show chart ./*.tgz 2>/dev/null | grep -E '^(name|version|appVersion):' | paste - - - || true
