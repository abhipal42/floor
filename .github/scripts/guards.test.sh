#!/usr/bin/env bash
#
# Self-test for guards.sh, run against synthetic git repos.
#
# Every case builds a throwaway repo, commits a base state, commits a head
# state, and asserts the guard's exit code. That is the whole point of guards
# being a script: these run in milliseconds, where testing them through real PRs
# would cost a push and a CI run per case.
#
# Each case asserts the exit code AND, where it matters, that the message names
# the thing that is wrong. A guard that fails for the right reason with the wrong
# explanation is a guard people learn to ignore.
#
# Usage: guards.test.sh
set -uo pipefail

# Hermetic: every case sets exactly the CI inputs it means to. Run inside a
# real PR job, the job's own PR_TITLE / LABELS / BASE_SHA leaked into cases
# asserting "no PR_TITLE" — green on a laptop, red in CI (v2.44.2, the first
# repo to run this suite from a job that also runs its own guards).
unset PR_TITLE PR_AUTHOR LABELS BASE_SHA HEAD_SHA GITHUB_ACTIONS GITHUB_OUTPUT \
      GH_TOKEN GITHUB_TOKEN

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDS="$HERE/guards.sh"
PASS=0; FAIL=0

# ---------------------------------------------------------------------------

setup() {
  REPO=$(mktemp -d)
  cd "$REPO" || exit 1
  git init -q .
  git config user.email t@t.t; git config user.name t
  git config commit.gpgsign false
  mkdir -p src docs/retros docs/changelog tests .github/scripts .github/workflows
  cp "$HERE/guards.sh" .github/scripts/guards.sh
  cat > .github/scripts/guards.conf <<'CONF'
APP="."
VERSION_FILE="./VERSION"
VERSION_FIELDS=3
CHANGELOG="./CHANGELOG.md"
CHANGELOG_ARCHIVE_DIR="./docs/changelog"
RETRO_DIR="./docs/retros"
RETRO_DEBT_MAX=8
DOCS_CODE_PATTERN="^src/.*\.py$"
DOCS_TARGET_PATTERN="^docs/.*\.md$"
TESTS_CODE_PATTERN="^src/.*\.py$"
TESTS_TARGET_PATTERN="^tests/.*\.py$"
CAPABILITY_ADD_PATTERN="^src/tools/[^/]+\.py$"
VERSION_MIRRORS=""
SCOPE_RULES="app:^src/"
CONF
  # A correctly wired, injection-free workflow, so workflow-wired and
  # workflow-injection pass on the base state and each case breaks one thing.
  cat > .github/workflows/guards.yml <<'YML'
on: pull_request
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - name: guards
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          PR_TITLE: ${{ github.event.pull_request.title }}
        run: bash .github/scripts/guards.sh all
YML
  printf '1.0.0\n' > VERSION
  printf '# Changelog\n\n## 1.0.0 — 2026-01-01\n\n- base\n' > CHANGELOG.md
  echo base > src/thing.py
  git add -A >/dev/null; git commit -qm "base"
  BASE=$(git rev-parse HEAD)
}

teardown() { cd /; rm -rf "$REPO"; }

# run <guard> [LABELS] -> sets OUT and RC
#
# GITHUB_OUTPUT/GITHUB_ACTIONS are blanked so a run of this suite INSIDE Actions
# neither writes the cases' outputs into the real step nor changes what `all`
# prints. A case that wants them sets them explicitly (GHA=1).
run() {
  local guard="$1" labels="${2:-}"
  OUT=$(BASE_SHA="$BASE" HEAD_SHA="$(git rev-parse HEAD)" LABELS="$labels" \
        PR_TITLE="${PR_TITLE:-}" PR_AUTHOR="${PR_AUTHOR:-}" \
        GITHUB_OUTPUT="" GITHUB_ACTIONS="${GHA:-}" \
        GUARDS_CONF="$REPO/.github/scripts/guards.conf" \
        bash .github/scripts/guards.sh "$guard" 2>&1)
  RC=$?
}

# run_local <guard> — as a human runs it: no BASE_SHA, no HEAD_SHA.
run_local() {
  OUT=$(env -u BASE_SHA -u HEAD_SHA LABELS="" PR_TITLE="" GITHUB_OUTPUT="" GITHUB_ACTIONS="" \
        GUARDS_CONF="$REPO/.github/scripts/guards.conf" \
        bash .github/scripts/guards.sh "$1" 2>&1)
  RC=$?
}

# conf <line> — add a config line as part of the BASE state, so the conf edit
# itself is not in the diff under test.
conf() { printf '%s\n' "$1" >> .github/scripts/guards.conf; commit "conf"; BASE=$(git rev-parse HEAD); }
lacks() { if has "$2"; then FAIL=$((FAIL+1)); echo "  FAIL $1 — message mentions '$2'"; echo "$OUT" | sed 's/^/       /'; else PASS=$((PASS+1)); echo "  ok   $1"; fi; }

# Substring test with no pipe: `printf | grep -q` under pipefail is the very
# race guards.sh bans, and the pipefail cases below produce large OUTs.
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
ok()   { if [ "$RC" -eq 0 ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected pass)"; echo "$OUT" | sed 's/^/       /'; fi; }
bad()  { if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected fail)"; echo "$OUT" | sed 's/^/       /'; fi; }
says() { if has "$2"; then PASS=$((PASS+1)); echo "  ok   $1"; else FAIL=$((FAIL+1)); echo "  FAIL $1 — message never mentions '$2'"; echo "$OUT" | sed 's/^/       /'; fi; }

commit() { git add -A >/dev/null; git commit -qm "$1"; }
bump()   { printf '%s\n' "$1" > VERSION; }
entry()  { printf '# Changelog\n\n## %s — 2026-01-02\n\n%s\n\n## 1.0.0 — 2026-01-01\n\n- base\n' "$1" "${2:-- change}" > CHANGELOG.md; }

# ---------------------------------------------------------------------------
echo "docs"
setup
  echo more >> src/thing.py; commit "code only"
  run docs;                     bad  "code with no doc fails"
  says "names the offender" "src/thing.py"
  run docs docs-exempt;         ok   "docs-exempt label passes"
teardown

setup
  echo more >> src/thing.py; echo x > docs/note.md; commit "code + doc"
  run docs;                     ok   "code with a doc passes"
teardown

setup
  echo more >> src/thing.py; commit "code [skip docs]"
  run docs;                     ok   "[skip docs] in the subject passes"
teardown

setup
  # The failure this exists for: a commit BODY that merely explains the tag.
  echo more >> src/thing.py
  git add -A >/dev/null
  git commit -q -m "code" -m "You can bypass this with [skip docs] mid-sentence."
  run docs;                     bad  "a tag discussed in prose does NOT exempt"
teardown

echo "tests"
setup
  echo more >> src/thing.py; commit "code only"
  run tests;                    bad  "code with no test fails"
  echo t > tests/test_thing.py; commit "add test"
  run tests;                    ok   "code with a test passes"
teardown

echo "changelog"
setup
  echo more >> src/thing.py; commit "no changelog"
  run changelog;                bad  "untouched changelog fails"
teardown

setup
  bump 1.0.1; entry 1.0.1; commit "bump"
  run changelog;                ok   "matching VERSION and entry passes"
teardown

setup
  bump 1.0.1; entry 1.0.2; commit "mismatch"
  run changelog;                bad  "VERSION disagreeing with the header fails"
  says "explains the mismatch" "does not match"
teardown

setup
  # Appending a bullet to an already-released entry.
  printf '# Changelog\n\n## 1.0.0 — 2026-01-01\n\n- base\n- snuck in\n' > CHANGELOG.md
  commit "append to a shipped entry"
  run changelog;                bad  "editing a released entry fails"
  says "says the entry is closed" "already exists on the base branch"
teardown

setup
  bump 0.9.0; entry 0.9.0; commit "go backwards"
  run changelog;                bad  "a non-monotonic version fails"
teardown

echo "changelog-archive"
setup
  printf '# Changelog\n\n## 1.1.0 — d\n\n- a\n\n## 1.0.0 — d\n\n- b\n' > CHANGELOG.md
  commit "two series"
  run changelog-archive;        bad  "two minor series fails"
teardown

echo "version-sync"
setup
  printf '{"version": "1.0.0"}\n' > package.json
  sed -i.bak 's|VERSION_MIRRORS=""|VERSION_MIRRORS="./package.json"|' .github/scripts/guards.conf
  commit "mirror in sync"
  run version-sync;             ok   "matching mirror passes"
  printf '{"version": "0.4.1"}\n' > package.json; commit "drift"
  run version-sync;             bad  "a drifted mirror fails"
  says "names both values" "0.4.1"
teardown

setup
  # The failure the first version had: a dependency pin precedes the project's
  # own version, and "first version-shaped string" read the pin.
  cat > package.json <<'JSON'
{
  "name": "x",
  "dependencies": { "left-pad": { "version": "9.9.9" }, "b": "1.0.0" },
  "engines": { "node": "22.1.0" },
  "version": "0.4.1"
}
JSON
  sed -i.bak 's|VERSION_MIRRORS=""|VERSION_MIRRORS="./package.json"|' .github/scripts/guards.conf
  commit "dependency first, own version drifted"
  run version-sync;             bad  "a nested/dependency version does not satisfy the mirror"
  says "reports the TOP-LEVEL value" "says '0.4.1'"
  printf '{"dependencies":{"a":"0.4.1"},"version":"1.0.0"}' > package.json; commit "minified"
  run version-sync;             ok   "minified JSON: the top-level version is found"
  printf '{"name":"x","dependencies":{"version":"1.0.0"}}\n' > package.json; commit "no top version"
  run version-sync;             bad  "JSON with no top-level version fails"
  says "says it is missing" "no top-level"
teardown

setup
  printf '<plist><key>CFBundleShortVersionString</key><string>1.0.0</string></plist>\n' > Info.plist
  sed -i.bak 's|VERSION_MIRRORS=""|VERSION_MIRRORS="./Info.plist"|' .github/scripts/guards.conf
  commit "plist mirror"
  run version-sync;             ok   "a non-JSON (plist) mirror still works"
teardown

echo "bump-level"
setup
  mkdir -p src/tools; echo new > src/tools/brand_new.py
  bump 1.0.1; entry 1.0.1; commit "patch + new tool"
  run bump-level;               bad  "PATCH adding a capability surface is challenged"
  run bump-level patch-intentional; ok "patch-intentional passes"
teardown

setup
  bump 2.0.0; entry 2.0.0; commit "major, no breaking section"
  run bump-level;               bad  "MAJOR with no Breaking section fails"
  entry 2.0.0 "### Breaking

- the thing"; commit "add breaking"
  run bump-level;               ok   "MAJOR documenting what breaks passes"
teardown

echo "adoption (no VERSION on the base side)"
setup
  # The PR that ADOPTS these guards adds VERSION and CHANGELOG.md. If that PR
  # cannot go green, the guards get deleted on day one.
  git rm -q --cached VERSION >/dev/null; rm VERSION
  git commit -qm "pretend VERSION never existed"
  BASE=$(git rev-parse HEAD)
  printf '1.0.0\n' > VERSION; commit "add VERSION"
  run bump-level;               ok   "bump-level survives a brand-new VERSION"
  run retro;                    ok   "retro survives a brand-new VERSION"
  says "says why" "new in this PR"
teardown

echo "retro"
setup
  bump 1.1.0; entry 1.1.0; commit "minor, no retro"
  run retro;                    bad  "MINOR with no retro fails"
  echo r > docs/retros/2026-01-02-thing.md; commit "add retro"
  run retro;                    ok   "MINOR with a retro passes"
teardown

setup
  # A MAJOR resets MINOR to 0. Comparing MINOR alone reads 1 -> 0 as "went
  # backwards" and lets the biggest milestone there is ship retro-free.
  bump 1.1.0; entry 1.1.0; echo r > docs/retros/a.md; commit "minor"
  BASE=$(git rev-parse HEAD)
  bump 2.0.0; entry 2.0.0 "### Breaking

- x"; commit "major, no retro"
  run retro;                    bad  "MAJOR with no retro fails (MINOR reset to 0)"
teardown

setup
  bump 1.0.1; entry 1.0.1; commit "patch"
  run retro;                    ok   "PATCH is untaxed"
teardown

setup
  # README/TEMPLATE in the retro dir must not count as shipping a retro.
  bump 1.1.0; entry 1.1.0; echo x > docs/retros/README.md; commit "minor + readme"
  run retro;                    bad  "a README does not count as a retro"
teardown

echo "retro-debt"
setup
  {
    echo "# Changelog"; echo
    for p in 0 1 2 3 4 5 6 7 8 9; do echo "## 1.0.$p — d"; echo; echo "- x"; echo; done
  } > CHANGELOG.md
  bump 1.0.9; commit "long line"
  run retro-debt;               bad  "past the cap forces a milestone"
  run retro-debt retro-exempt;  ok   "retro-exempt passes"
teardown

echo "followups"
setup
  cat > docs/retros/r.md <<'MD'
# Retro

## Gaps found

| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | write it | deferred |
MD
  commit "bare deferred"
  run followups;                bad  "a bare 'deferred' fails"
  says "quotes the offending status" "deferred"
teardown

setup
  cat > docs/retros/r.md <<'MD'
# Retro

## Gaps found

| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | write it | landed here |
| b | test | do it | blocked: waiting on hardware |
| c | docs | x | **landed** v1.2.0 |
| d | docs | y | `blocked:` needs the Apple entitlement |
MD
  commit "all owned"
  run followups;                ok   "landed / blocked-with-reason (incl. markdown-emphasised) passes"
teardown

setup
  # tracked: #N was an owner until 2.0.0. It is the escape hatch RIA banned.
  cat > docs/retros/r.md <<'MD'
# Retro

## Gaps found

| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| c | proc | file it | tracked: #12 |
MD
  commit "tracked"
  run followups;                bad  "'tracked: #N' is no longer an owner"
  says "says why tracked fails" "'tracked: #N' is no longer an owner"
  says "quotes the offending status" "tracked: #12"
teardown

setup
  cat > docs/retros/r.md <<'MD'
# Retro

## Gaps found

| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | x | not landed yet |
MD
  commit "not landed"
  run followups;                bad  "'not landed yet' fails (must START with landed)"
  says "quotes it" "not landed yet"
teardown

setup
  cat > docs/retros/r.md <<'MD'
# Retro

## Gaps found

| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | x | blocked |
| b | docs | y | **blocked:** |
MD
  commit "empty promises"
  run followups;                bad  "'blocked' / bare 'blocked:' with no reason fail"
  says "quotes the emphasised bare blocked" "**blocked:**"
teardown

echo "pr-title"
setup
  bump 1.0.1; entry 1.0.1; commit "v1.0.1 fix: a thing"
  PR_TITLE="v1.0.1 fix: a thing" run pr-title;  ok  "matching title and subject pass"
  PR_TITLE="fix: a thing"       run pr-title;   bad "a title with no version fails"
  PR_TITLE="v1.0.1 thing"       run pr-title;   bad "a title with no conventional type fails"
teardown

# Under the standard settings (squash title = PR title) the subject never
# reaches main, so by default it is not checked; PR_TITLE_CHECK_SUBJECT=1 is
# for a repo still on GitHub's default, where a single-commit PR squashes with it.
setup
  bump 1.0.1; entry 1.0.1; commit "fix: forgot the version"
  PR_TITLE="v1.0.1 fix: a thing" run pr-title
  ok   "default: a good title passes whatever the single commit's subject says"
  lacks "and does not talk about the subject" "COMMIT SUBJECT"
teardown

setup
  conf 'PR_TITLE_CHECK_SUBJECT=1'
  bump 1.0.1; entry 1.0.1; commit "fix: forgot the version"
  PR_TITLE="v1.0.1 fix: a thing" run pr-title
  bad  "PR_TITLE_CHECK_SUBJECT=1: an unversioned single-commit SUBJECT fails"
  says "explains why the subject matters" "COMMIT SUBJECT"
teardown

# With no PR_TITLE at all — the way `make guards` runs it. This used to print
# "no PR_TITLE — skipping" and exit 0, which is how three PRs shipped with the
# version on the wrong end of the subject.
setup
  bump 1.0.1; entry 1.0.1; commit "fix: forgot the version"
  run pr-title;  bad  "no PR_TITLE still catches a bad single-commit subject"
  says "names the format it wants" "v1.0.1 <type>: <summary>"
teardown

setup
  bump 1.0.1; entry 1.0.1; commit "v1.0.1 fix: a thing"
  run pr-title;  ok   "no PR_TITLE passes when the subject is right"
teardown

# Two commits and no PR: nothing has decided the squash subject yet, so there
# is genuinely nothing to check — and the message says that rather than
# implying the guard ran.
setup
  bump 1.0.1; entry 1.0.1; commit "fix: one"
  echo x >> src/thing.py; commit "fix: two"
  run pr-title;  ok   "a multi-commit branch with no PR skips"
  says "says what it skipped and why" "no PR"
teardown

echo "scope"
setup
  echo more >> src/thing.py; commit "touch src"
  run scope; ok "scope never fails"
  says "emits the app output" "app=true"
teardown

echo "scope — SCOPE_SKIP (run by default)"
setup
  run scope; says "no SCOPE_SKIP: the suite always runs" "code=true"
teardown

setup
  conf 'SCOPE_SKIP="^docs/|\.md$"'
  echo x > docs/a.md; echo y > README.md; commit "docs only"
  run scope; says "every path skippable: code=false" "code=false"
teardown

setup
  conf 'SCOPE_SKIP="^docs/|\.md$"'
  mkdir -p brand_new_dir; echo x > brand_new_dir/thing.sh; echo y > docs/a.md; commit "new top-level dir"
  run scope; says "a new top-level dir runs the suite" "code=true"
  says "names what forced it" "brand_new_dir/thing.sh"
teardown

echo "pipefail — matches large inputs"
# The pipe race, forced: the match is in the first 64 KiB and the producer has
# far more to write, so `grep -q` exits while the producer blocks, the producer
# takes SIGPIPE, and pipefail reports a MATCH as a failure. git sorts paths, so
# "CHANGELOG.md" and "src/…" sort before the padding under "zz/".
big_diff() {
  mkdir -p zz
  local i=0
  while [ $i -lt 1500 ]; do
    : > "zz/padding_file_number_${i}_with_a_long_name_to_fill_the_pipe_buffer.txt"
    i=$((i+1))
  done
}
setup
  big_diff; echo more >> src/thing.py; bump 1.0.1; entry 1.0.1; commit "huge diff"
  run scope;      says "scope: a match on a >64 KiB diff still emits true" "app=true"
  run changelog;  ok   "changelog: an updated CHANGELOG on a >64 KiB diff is seen"
teardown

setup
  # has_tag reads `git log`; a tag on its own body line followed by a long body
  # makes the producer outlive grep.
  echo more >> src/thing.py
  git add -A >/dev/null
  # -F, not -m: a 170 KB argument exceeds Linux's per-argument limit, the commit
  # fails, and the case then passes on an empty diff for the wrong reason.
  { echo code; echo; echo "[skip docs]"; seq 1 30000; } > "$REPO/.msg"
  git commit -q -F "$REPO/.msg" || { FAIL=$((FAIL+1)); echo "  FAIL could not commit the huge message"; }
  rm -f "$REPO/.msg"
  run docs;       ok   "[skip docs] is honoured when the commit log is huge"
teardown

echo "BASE_BRANCH"
setup
  # A develop-trunk repo run locally: no BASE_SHA, trunk named in the conf.
  git branch -M develop; conf 'BASE_BRANCH="develop"'
  git checkout -q -b feat/x
  echo more >> src/thing.py; commit "code only"
  run_local docs;  bad  "with no BASE_SHA the diff is taken against BASE_BRANCH"
  says "and sees the change" "src/thing.py"
teardown

setup
  git branch -M trunk
  echo more >> src/thing.py; commit "code only"
  run_local docs;  bad  "an unresolvable BASE_BRANCH fails loudly"
  says "names the key to set" "BASE_BRANCH 'main' resolves to nothing"
teardown

setup
  # In CI the event's BASE_SHA wins, even when BASE_BRANCH names nothing.
  conf 'BASE_BRANCH="no-such-branch"'
  echo more >> src/thing.py; echo d > docs/n.md; commit "code + doc"
  run docs;        ok   "BASE_SHA from the environment beats BASE_BRANCH"
teardown

echo "all — ::group:: under Actions"
setup
  GHA=true run all
  says "groups each guard" "::group::followups"
  says "closes the group" "::endgroup::"
  run all
  lacks "no ::group:: outside Actions" "::group::"
teardown

echo "workflow-wired"
setup
  run workflow-wired;           ok   "a workflow running 'guards.sh all' passes"
teardown

setup
  rm .github/workflows/guards.yml; commit "no workflows"
  run workflow-wired;           bad  "no workflow at all fails"
  says "says nothing gates" "No workflow under .github/workflows/"
teardown

setup
  # The RIA v2.30.3 shape: guards invoked one by one, some never.
  cat > .github/workflows/guards.yml <<'YML'
jobs:
  g:
    steps:
      # - run: bash .github/scripts/guards.sh all
      - run: bash .github/scripts/guards.sh docs
      - run: bash .github/scripts/guards.sh changelog
YML
  commit "per-guard, incomplete"
  run workflow-wired;           bad  "guards never invoked by name fail (a commented 'all' does not count)"
  says "names an unwired guard" "followups"
  lacks "does not list a wired guard" " docs "
teardown

setup
  mkdir -p .github/scripts/guards.d
  cat > .github/scripts/guards.d/extra.sh <<'SH'
cmd_extra_check() { echo "✓ extra"; }
EXTRA+=(extra-check)
SH
  {
    echo "jobs:"; echo "  g:"; echo "    steps:"
    for g in scope docs tests changelog changelog-archive version-sync bump-level retro retro-debt followups pr-title retired-rules workflow-wired workflow-injection; do
      echo "      - run: bash .github/scripts/guards.sh $g"
    done
  } > .github/workflows/guards.yml
  commit "every core guard by name, project guard forgotten"
  run workflow-wired;           bad  "a guards.d guard nobody invokes fails"
  says "names the project guard" "extra-check"
  echo "      - run: bash .github/scripts/guards.sh extra-check" >> .github/workflows/guards.yml
  commit "wire it"
  run workflow-wired;           ok   "every guard invoked by name passes"
teardown

echo "workflow-injection"
setup
  run workflow-injection;       ok   "SHAs in env/run and titles in env: pass"
teardown

setup
  cat > .github/workflows/bad.yml <<'YML'
jobs:
  j:
    steps:
      - name: t
        if: github.event.pull_request.title != ''
        env:
          T: ${{ github.event.pull_request.title }}
        run: |
          echo "$T"
          echo "${{ github.event.pull_request.title }}"
      - run: gh issue comment --body '${{ steps.inference.outputs.response }}'
YML
  commit "inject"
  run workflow-injection;       bad  "a title pasted into run: fails"
  says "names file and line" "bad.yml:10"
  says "catches steps outputs too" "steps.inference.outputs.response"
  lacks "env: and if: are not flagged" "bad.yml:7"
teardown

setup
  cat > .github/workflows/bad.yml <<'YML'
jobs:
  j:
    steps:
      - run: git checkout "${{ github.head_ref }}"
      - run: git fetch origin ${{ github.event.pull_request.base.sha }}
YML
  commit "head_ref"
  run workflow-injection;       bad  "github.head_ref in run: fails"
  says "names it" "github.head_ref"
  lacks "a base SHA is not flagged" "bad.yml:5"
teardown

echo "retired-rules"
setup
  run retired-rules;            ok   "unconfigured is off"
  says "says so" "not configured"
teardown

setup
  conf 'RETIRED_RULES="deploys are manual|not git-connected|docs/DEPLOY.md (auto-deploy on merge)"'
  printf '# Project\n\nNote: Deploys are manual.\nThis repo is not git-connected.\n' > CLAUDE.md
  printf 'deploys are manual (history)\n' > docs/changelog/old.md
  commit "stale rule"
  run retired-rules;            bad  "an operative doc restating a retired rule fails"
  says "names where it moved" "docs/DEPLOY.md (auto-deploy on merge)"
  says "names file:line" "CLAUDE.md:3"
  says "the regex keeps its alternation (split on the LAST |)" "CLAUDE.md:4"
  says "where-it-moved is only the last field" "lives in: docs/DEPLOY.md"
  lacks "history is not scanned" "old.md"
  printf '# Project\n\nDeploys are automatic.\n' > CLAUDE.md; commit "fix doc"
  run retired-rules;            ok   "once the doc is fixed it passes"
teardown

echo "self-test"
st_case() {
  local d; d=$(mktemp -d)
  cp "$GUARDS" "$d/guards.sh"
  printf 'echo core-ran; exit %s\n' "$1" > "$d/guards.test.sh"
  [ "$2" = none ] || printf 'echo project-ran; exit %s\n' "$2" > "$d/guards.d.test.sh"
  OUT=$(cd "$d" && env -u BASE_SHA -u HEAD_SHA GUARDS_CONF=/nonexistent bash "$d/guards.sh" self-test 2>&1); RC=$?
  rm -rf "$d"
}
st_case 0 0;    ok   "self-test runs with no conf and no BASE_SHA"
                says "runs the template suite" "core-ran"
                says "then the project suite" "project-ran"
st_case 0 1;    bad  "a failing guards.d.test.sh fails self-test"
st_case 1 0;    bad  "a failing guards.test.sh fails self-test"
                says "and the project suite still runs" "project-ran"
st_case 0 none; ok   "no guards.d.test.sh: the template suite alone"
                says "says there were none" "no guards.d.test.sh"

echo "dependabot — an actions-only bump"
# Dependabot's actions PRs have no VERSION bump, no changelog and a title of its
# own; without this they could never go green. Keyed on the diff AND the author.
setup
  echo "# pin bumped" >> .github/workflows/guards.yml; commit "ci(deps): bump actions/checkout"
  for g in changelog docs tests bump-level retro; do
    PR_AUTHOR='dependabot[bot]' run "$g"
    ok   "$g: dependabot + .github/-only diff passes"
    says "$g: and says why" "dependabot actions bump — skipped"
  done
  PR_AUTHOR='dependabot[bot]' PR_TITLE="ci(deps): bump actions/checkout" run pr-title
  ok   "pr-title: dependabot + .github/-only diff passes"
  says "pr-title: and says why" "dependabot actions bump — skipped"
  PR_AUTHOR='someone' run changelog
  bad  "the same diff from a human still needs a changelog"
teardown

setup
  # Structural, not a bot bypass: a manifest bump changes what ships.
  echo "# pin bumped" >> .github/workflows/guards.yml; printf '{"version":"1.0.0"}\n' > package.json
  commit "build(deps): bump left-pad"
  PR_AUTHOR='dependabot[bot]' run changelog
  bad  "a dependabot PR touching a package manifest runs every guard"
  lacks "and is not skipped" "dependabot actions bump"
  PR_AUTHOR='dependabot[bot]' PR_TITLE="build(deps): bump left-pad" run pr-title
  bad  "…pr-title included"
teardown

echo "followups — table shapes"
gaps() { printf '# Retro\n\n## Gaps found\n\n%s\n' "$1" > docs/retros/r.md; commit "retro"; }
setup
  # Status is not the last column: a Notes column after it.
  gaps '| Gap | Status | Notes |
| --- | --- | --- |
| a | landed v1.2.0 | was deferred once |'
  run followups;                ok   "the Status column is found by its header, not by position"
teardown

setup
  gaps '| Gap | Status | Notes |
| --- | --- | --- |
| a | deferred | fine |'
  run followups;                bad  "…and a bad status in a middle column is still caught"
  says "quotes it" "'deferred'"
teardown

setup
  gaps '| Gap | RESOLUTION | Owner |
|:---|:---:|---:|
| a | landed | deferred-ish person |'
  run followups;                ok   "header match is case-insensitive (RESOLUTION); aligned separator skipped"
teardown

setup
  gaps '| Gap | Kind | Follow-up | Status
| --- | --- | --- | ---
| a | docs | x | landed here
| b | docs | y | blocked: waiting on hardware'
  run followups;                ok   "rows without a trailing | are read correctly"
teardown

setup
  gaps '| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | x | blocked: needs A \| B from Apple |'
  run followups;                ok   "an escaped \\| stays inside the reason"
teardown

setup
  gaps '| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | x | blocked: needs a | b |'
  run followups;                ok   "an unescaped | in a last-column reason is joined back, not read as status 'b'"
teardown

setup
  gaps '| Gap | Kind | Follow-up | Status |
| --- | --- | --- | --- |
| a | docs | x | |'
  run followups;                bad  "an EMPTY status cell has no owner"
teardown

echo "workflow-wired — anchored matching"
setup
  printf 'jobs:\n  g:\n    steps:\n      - run: bash .github/scripts/ci-guards.sh all\n' > .github/workflows/guards.yml
  commit "someone else's guards"
  run workflow-wired;           bad  "'ci-guards.sh all' is not this template's guards"
teardown

setup
  printf 'jobs:\n  g:\n    steps:\n      - run: echo "see guards.sh"\n      - run: echo "bash guards.sh all"\n' > .github/workflows/guards.yml
  commit "quoted mentions"
  run workflow-wired;           bad  "a quoted mention (quote as terminator) does not count as running it"
teardown

setup
  printf 'jobs:\n  g:\n    steps:\n      - run: guards.sh all 2>&1\n' > .github/workflows/guards.yml
  commit "bare path"
  run workflow-wired;           ok   "'guards.sh all' at the start of a run line counts"
teardown

echo "workflow-injection — inputs, env, nested braces, comments, allow-list"
setup
  cat > .github/workflows/bad.yml <<'YML'
on: workflow_dispatch
jobs:
  j:
    steps:
      - env:
          T: ${{ env.TITLE }}
        run: |
          echo "${{ inputs.name }}"
          echo "${{ env.TITLE }}"
          echo "${{ format('{0}-x', github.event.issue.title) }}"
          # ${{ github.event.comment.body }}
          git checkout "${{ github.event.pull_request.head.ref }}"
YML
  commit "more shapes"
  run workflow-injection;       bad  "inputs / env / format() / comment / head.ref fail"
  says "inputs.* is user input" "bad.yml:8"
  says "env.* is flagged" "bad.yml:9"
  says "…and told to use \$VAR" 'write "$TITLE"'
  says "format('{0}') is read to its closing }}" "bad.yml:10"
  says "…whole expression quoted" "github.event.issue.title) }}"
  says "a # line inside run: is scanned" "bad.yml:11"
  says "head.ref is attacker-chosen" "bad.yml:12"
  lacks "env: values are not pasted into shell" "bad.yml:6"
teardown

setup
  cat > .github/workflows/ok.yml <<'YML'
jobs:
  j:
    steps:
      - run: |
          git fetch origin "${{ github.event.repository.default_branch }}"
          echo "${{ github.event.repository.full_name }} ${{ github.event.repository.name }}"
          git diff "origin/${{ github.event.pull_request.base.ref }}"
          echo "${{ github.event.pull_request.number }}"
YML
  commit "repo-controlled values"
  run workflow-injection;       ok   "repo-controlled fields (default_branch, full_name, name, base.ref) pass"
teardown

# ---------------------------------------------------------------------------
# Template-only: the files that exist next to guards.sh in templates/ci but not
# in an installed project (bootstrap, the workflow templates, the skeleton).
if [ -f "$HERE/bootstrap" ] && [ -f "$HERE/workflows/guards.yml" ]; then
echo "template — workflows"
# The guards read VERSION from the working tree and compare with MERGE_BASE. On
# the default pull_request (merge-ref) checkout a PR opened before main bumped
# MINOR reads main's VERSION and `retro` misfires; guards.yml must pin the head.
WF="$HERE/workflows/guards.yml"
OUT=$(cat "$WF"); RC=0
says "guards.yml checks out the PR's head SHA, not the merge ref" \
  'ref: ${{ github.event.pull_request.head.sha || github.sha }}'
says "guards.yml hands PR_AUTHOR to the guards" \
  'PR_AUTHOR: ${{ github.event.pull_request.user.login }}'

setup
  # What the pinned checkout prevents, reproduced: main bumps MINOR (with its
  # retro) after the branch is cut; the PR itself only touches code + docs.
  git checkout -q -b feat
  echo more >> src/thing.py; echo d > docs/n.md; commit "code"
  HEAD_PR=$(git rev-parse HEAD)
  git checkout -q -
  bump 1.1.0; entry 1.1.0; echo r > docs/retros/m.md; commit "main: 1.1.0"
  BASE_MAIN=$(git rev-parse HEAD)
  git checkout -q feat
  OUT=$(BASE_SHA="$BASE_MAIN" HEAD_SHA="$HEAD_PR" LABELS="" GITHUB_OUTPUT="" GITHUB_ACTIONS="" \
        GUARDS_CONF="$REPO/.github/scripts/guards.conf" bash .github/scripts/guards.sh retro 2>&1); RC=$?
  ok   "on the PR's head checkout, retro sees no bump"
  git merge -q --no-edit "$BASE_MAIN" >/dev/null 2>&1
  OUT=$(BASE_SHA="$BASE_MAIN" HEAD_SHA="$HEAD_PR" LABELS="" GITHUB_OUTPUT="" GITHUB_ACTIONS="" \
        GUARDS_CONF="$REPO/.github/scripts/guards.conf" bash .github/scripts/guards.sh retro 2>&1); RC=$?
  bad  "on a merge-ref working tree it misfires (why guards.yml pins head.sha)"
teardown

setup
  cp "$HERE/workflows/guards.yml" .github/workflows/guards.yml
  cp "$HERE/workflows/ci.example.yml" .github/workflows/ci.yml
  commit "the template's own workflows"
  run workflow-injection;       ok   "the template's own workflows pass workflow-injection"
  run workflow-wired;           ok   "…and workflow-wired"
teardown

echo "template — guards.d.test.sh skeleton"
sk_case() {
  local d; d=$(mktemp -d)
  cp "$HERE/guards.sh" "$HERE/guards.d.test.sh" "$d/"
  if [ "$1" = with-guard ]; then
    mkdir -p "$d/guards.d"; printf 'cmd_x() { :; }\nEXTRA+=(x)\n' > "$d/guards.d/x.sh"
  fi
  OUT=$(bash "$d/guards.d.test.sh" 2>&1); RC=$?
  rm -rf "$d"
}
sk_case with-guard; bad "zero cases with a guards.d guard present fails"
                    says "says it ran nothing" "ZERO cases"
sk_case none;       ok  "zero cases with no guards.d guards is fine (fresh install)"

echo "template — bootstrap"
STUBBIN=$(mktemp -d); printf '#!/bin/sh\nexit 1\n' > "$STUBBIN/gh"; chmod +x "$STUBBIN/gh"
# bs <target> [args…] — run bootstrap with a gh that is always offline.
bs() { OUT=$(PATH="$STUBBIN:$PATH" bash "${BS:-$HERE/bootstrap}" "$@" 2>&1); RC=$?; }
bs_repo() {
  T=$(mktemp -d); T=$(cd "$T" && pwd -P)
  git -C "$T" init -q -b "$1"
  git -C "$T" config user.email t@t; git -C "$T" config user.name t
  git -C "$T" config commit.gpgsign false
  git -C "$T" commit -q --allow-empty -m init
}

# BASE_BRANCH: never the branch bootstrap happens to run on.
bs_repo develop
BARE=$(mktemp -d); git init -q --bare "$BARE"
git -C "$T" remote add origin "$BARE"; git -C "$T" push -q origin develop 2>/dev/null
git -C "$BARE" symbolic-ref HEAD refs/heads/develop
git -C "$T" checkout -q -b feat/x
bs "$T"
OUT=$(cat "$T/.github/scripts/guards.conf"); RC=0
says "no origin/HEAD: BASE_BRANCH comes from the remote's HEAD" 'BASE_BRANCH="develop"'
lacks "…never the current feature branch" 'BASE_BRANCH="feat/x"'
rm -rf "$T" "$BARE"

bs_repo trunk; git -C "$T" checkout -q -b feat/y
bs "$T"
OUT=$(cat "$T/.github/scripts/guards.conf"); RC=0
says "no remote and gh offline: BASE_BRANCH falls back to main" 'BASE_BRANCH="main"'
rm -rf "$T"

# No other workflow: the ci skeleton is installed INERT, with a next step.
bs_repo main
bs "$T"
ok   "fresh install succeeds"
says "tells the human to rename it" "git mv .github/workflows/ci.yml.example .github/workflows/ci.yml"
if [ -f "$T/.github/workflows/ci.yml.example" ] && [ ! -e "$T/.github/workflows/ci.yml" ]; then
  PASS=$((PASS+1)); echo "  ok   ci skeleton is ci.yml.example, not a live ci.yml"
else
  FAIL=$((FAIL+1)); echo "  FAIL ci skeleton should be an inert ci.yml.example"; ls "$T/.github/workflows" | sed 's/^/       /'
fi
bs "$T"
says "a re-run keeps it and still reminds" "· kept    .github/workflows/ci.yml.example"
rm -rf "$T"

bs_repo main; mkdir -p "$T/.github/workflows"; echo 'on: push' > "$T/.github/workflows/test.yml"
bs "$T"
lacks "a repo with its own workflow gets no skeleton" "ci.yml.example"; lacks "…and no rename step" "git mv"
rm -rf "$T"

# Upgrade: an old-but-unmodified install is replaced quietly; a hand edit is
# named in a WARNING before it is thrown away — in a --dry-run too.
TPL=$(mktemp -d); cp -R "$HERE"/. "$TPL"/
( cd "$TPL" && printf '1.0.0\n' > VERSION && git init -q . && git config user.email t@t \
  && git config user.name t && git config commit.gpgsign false \
  && git add -A && git commit -qm "template 1.0.0" ) >/dev/null
BS="$TPL/bootstrap"
bs_repo main; bs "$T"
( cd "$TPL" && echo '# 1.1.0' >> guards.sh && printf '1.1.0\n' > VERSION \
  && git commit -qam "template 1.1.0" ) >/dev/null
bs "$T" --dry-run
lacks "an unmodified old install is not called edited" "WARNING"
echo "# my local hack" >> "$T/.github/scripts/guards.test.sh"
bs "$T" --dry-run
says "--dry-run warns about a locally modified template file" "WARNING: these template-owned files were modified locally"
OUT=$(printf '%s\n' "$OUT" | sed -n '/^WARNING/,/^  Move/p')
says "…naming it" ".github/scripts/guards.test.sh"
lacks "…and not the unmodified one" "scripts/guards.sh"
bs "$T"
says "a real upgrade warns too" "WARNING: these template-owned files"
unset BS
rm -rf "$T" "$TPL" "$STUBBIN"
fi

# ---------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
