#!/usr/bin/env bash
#
# Tests for THIS project's guards — the ones in guards.d/.
#
# PROJECT-OWNED. The guards template's `bootstrap` writes this skeleton once, if
# it is absent, and never overwrites it. guards.test.sh is the opposite — the
# template's, replaced on every upgrade — which is why a project's cases go here
# and not there. `guards.sh self-test` runs both, and guards.yml runs that
# whenever .github/ changes.
#
# Each case asserts the exit code AND that the message names the thing that is
# wrong. A guard that fails for the right reason with the wrong explanation is
# one people learn to ignore. (Shape from rathi-fitness and yt, which each
# invented this file before the template shipped it.)
#
#   bash .github/scripts/guards.d.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0

# A throwaway git repo carrying this project's guard scripts, so a case can
# break the tree without breaking the tree. Add the minimal files your guards
# read. It commits once as `base`; a case then commits its change on top.
sandbox() {
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/.github/scripts/guards.d"
  cp "$HERE/guards.sh" "$dir/.github/scripts/"
  [ -f "$HERE/guards.conf" ] && cp "$HERE/guards.conf" "$dir/.github/scripts/"
  for f in "$HERE"/guards.d/*.sh; do
    [ -f "$f" ] && cp "$f" "$dir/.github/scripts/guards.d/"
  done
  ( cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@t; git config user.name t
    git add -A >/dev/null; git commit -qm base --allow-empty ) >/dev/null 2>&1
  echo "$dir"
}

# commit <sandbox> <message> — commit whatever the case changed.
commit() { ( cd "$1" && git add -A && git commit -qm "$2" --allow-empty ) >/dev/null 2>&1; }

# check <name> <want-rc> <want-text> <guard>
#   Runs the real guards.sh <guard> in $SB, diffing its first commit against
#   HEAD. <want-text> ("" to skip) must appear in the output, case-insensitive.
#   Set LABELS=... before the call to exercise a label opt-out.
check() {
  local name="$1" want_rc="$2" want_text="$3" guard="$4" out rc
  out=$( cd "$SB" \
    && BASE_SHA=$(git rev-list --max-parents=0 HEAD) HEAD_SHA=$(git rev-parse HEAD) \
       LABELS="${LABELS:-}" bash .github/scripts/guards.sh "$guard" 2>&1 ); rc=$?
  if [ "$rc" != "$want_rc" ]; then
    echo "  FAIL $name — exit $rc, wanted $want_rc"; echo "$out" | sed 's/^/       /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$want_text" ] && ! grep -qi -- "$want_text" <<< "$out"; then
    echo "  FAIL $name — message never mentions '$want_text'"; echo "$out" | sed 's/^/       /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "  ok   $name"; PASS=$((PASS + 1))
}

# ------------------------------------------------------------------ cases
# One block per guard in guards.d/. Test the FAILURE path, not only the healthy
# one — a guard whose failing case was never run is a guard that may never fail.
#
# echo "my-guard"
# SB=$(sandbox); echo 'bad thing' > "$SB/src/x.py"; commit "$SB" "add x"
# check "a bad thing is caught" 1 "src/x.py" my-guard
# SB=$(sandbox); echo 'fine' > "$SB/src/x.py"; commit "$SB" "add x"
# check "a fine thing passes" 0 "" my-guard
# SB=$(sandbox); echo 'bad thing' > "$SB/src/x.py"; commit "$SB" "add x [skip my-guard]"
# check "the commit tag opts out" 0 "skipping" my-guard

echo
echo "$PASS passed, $FAIL failed"

# Zero cases is a FAILURE once there is a project guard to test. A suite that
# runs nothing prints "0 passed, 0 failed", exits 0, and reads as green in the
# self-test step — which is how a guards.d guard ships with no test at all.
# With no guards.d/*.sh yet there is genuinely nothing to test, and failing
# then would turn every fresh install's first PR red.
if [ $((PASS + FAIL)) -eq 0 ]; then
  for f in "$HERE"/guards.d/*.sh; do
    if [ -f "$f" ]; then
      echo "::error::guards.d.test.sh ran ZERO cases, but guards.d/ has guards ($(basename "$f") …). Add a case per guard — its failure path first."
      exit 1
    fi
  done
  echo "(no guards.d/*.sh — no project guards, so no cases to run)"
fi
[ "$FAIL" -eq 0 ]
