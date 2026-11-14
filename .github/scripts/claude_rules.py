#!/usr/bin/env python3
"""Path-scoped rules (`.claude/rules/*.md`) and the context budget (v2.96.0).

One module, three readers, so they cannot disagree about which rule covers a file:

* **Claude Code** loads these itself in an interactive session.
* **RIA's dispatch worker** loads nothing of the repo's (`setting_sources=[]`),
  so `server/dispatch_worker.py` does the loading in its hooks, from this module.
* **CI** (`ci-guards.sh claude-context`, and the template's `guards.sh`) checks
  the budget, the globs and the pointers with this file's CLI.

Stdlib only, and runnable as a plain script: `templates/ci/claude_rules.py` is a
symlink to this file, and `bootstrap` copies it into projects that have no RIA.

**What a glob matches is measured, not guessed** (Claude Code 2.1.325,
2026-11-14, a scratch repo with one rule per pattern and `deep/x/y.py` read):

    "deep/**"  "**/*.py"  "deep"  "deep/"  "*"  "deep/*"   loaded
    "*.py"     "deep/*.py"                                   not loaded

So a pattern is anchored at the repo root, `*` stays inside one segment, and a
pattern that matches a directory (`deep`, `*`, `deep/*`) covers everything
under it. There is no gitignore-style "a bare `*.py` matches at any depth".
Brace sets (`lib/{b,c}.py`) work; `paths:` may be a block list, a flow list
(`[a/**, b/**]`), or one string, quoted or not (`paths: **/*.py` works), and a
trailing `# comment` is stripped. **A brace set inside a flow list makes the CLI
drop the whole rule** (YAML reads `{x,z}` as a mapping), so that shape is a bad
glob here and `check` names it. A rule with no `paths:` loads every session. A
rule reaches the model after a Read of a matching file, and after a Write that
creates one: after the write, not before.

    python3 claude_rules.py check [--root R] [--base SHA] [--ignore GLOB]
                                  [--ref-root DIR]           the CI guard
    python3 claude_rules.py which <file> [--root R]          rules for one path
    python3 claude_rules.py list [--root R]                  every rule and its globs
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field

RULES_DIR = ".claude/rules"
# What loads every session: the root CLAUDE.md, what it @-imports, and every rule
# with no `paths:`. Per file: each rule and each nested CLAUDE.md, which load on
# demand but should stay a page, not become a second root file.
DEFAULT_ALWAYS_MAX = 8192
DEFAULT_FILE_MAX = 6144
_IMPORT_DEPTH = 5   # Claude Code follows @-imports five hops deep


@dataclass
class Rule:
    path: str                       # repo-relative, e.g. .claude/rules/app.md
    globs: list[str] | None         # None: no `paths:`, loads every session
    body: str
    size: int = 0
    # Globs that can't be compiled, or a shape the CLI drops (`check` reports
    # them). A bad glob never raises: one typo in a repo's rules must not stop
    # a worker, a reviewer or a ship.
    bad: list[str] = field(default_factory=list)
    _res: list = field(default_factory=list, repr=False)
    _fold: list = field(default_factory=list, repr=False)

    def __post_init__(self):
        for g in self.globs or []:
            try:
                self._res.append(_compile(g))
                self._fold.append(_compile(g, re.I))
            except (re.error, ValueError):
                self.bad.append(g)

    def applies_to(self, rel: str, fold: bool = False) -> bool:
        """`fold`: compare case-insensitively, as APFS resolves a path."""
        if self.globs is None:
            return False
        return any(_hit(r, rel) for r in (self._fold if fold else self._res))


# --- frontmatter ----------------------------------------------------------------

def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def _strip_comment(s: str) -> str:
    """A YAML ` # comment` tail outside quotes (measured: the CLI strips it)."""
    quote = ""
    for i, ch in enumerate(s):
        if quote:
            quote = "" if ch == quote else quote
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or s[i - 1].isspace()):
            return s[:i].rstrip()
    return s


# A brace set inside a `[flow, list]` is a YAML mapping, not a glob: measured,
# the CLI drops the WHOLE rule (`paths: [deep/{x,z}/y.py, other/**]` loaded for
# neither). The parser keeps that shape so `check` can name it.
FLOW_BRACES = "a brace set inside a [flow list] makes Claude Code drop this rule; use a block list"


def parse(text: str) -> tuple[list[str] | None, str]:
    """(globs, body). Globs is None when there is no `paths:` key at all. A
    `paths:` that is present but empty is `[]`: a rule that loads for nothing,
    which `check` reports rather than treating it as global."""
    if not text.startswith("---"):
        return None, text
    lines = text.split("\n")
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return None, text
    front, body = lines[1:end], "\n".join(lines[end + 1:]).lstrip("\n")
    globs: list[str] | None = None
    i = 0
    while i < len(front):
        m = re.match(r"^paths\s*:\s*(.*)$", front[i])
        if not m:
            i += 1
            continue
        rest = _strip_comment(m.group(1).strip())
        globs = []
        if rest.startswith("["):
            inner = rest[1:-1] if rest.endswith("]") else rest[1:]
            if "{" in inner:
                return [FLOW_BRACES], body
            globs = [_unquote(x) for x in inner.split(",") if x.strip()]
        elif rest:
            globs = [_unquote(rest)]
        else:
            i += 1
            while i < len(front) and re.match(r"^\s*-\s*", front[i]):
                item = _unquote(_strip_comment(re.sub(r"^\s*-\s*", "", front[i])))
                if item:
                    globs.append(item)
                i += 1
            continue
        i += 1
    return globs, body


# --- globs ----------------------------------------------------------------------

_MAX_EXPANSIONS = 256


def _braces(pat: str) -> list[str]:
    """`a/{b,c}.py` -> [a/b.py, a/c.py], nested sets included. Capped: 20 sets
    would be a million regexes."""
    out = _expand(pat)
    if len(out) > _MAX_EXPANSIONS:
        raise ValueError(f"expands to more than {_MAX_EXPANSIONS} patterns")
    return out


def _expand(pat: str) -> list[str]:
    depth, start = 0, -1
    for i, ch in enumerate(pat):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}" and depth:
            depth -= 1
            if depth == 0:
                inner, parts, d, last = pat[start + 1:i], [], 0, 0
                for j, c in enumerate(inner):
                    d += c == "{"
                    d -= c == "}"
                    if c == "," and d == 0:
                        parts.append(inner[last:j])
                        last = j + 1
                parts.append(inner[last:])
                if len(parts) == 1:
                    return [pat]
                out = []
                for p in parts:
                    out += _expand(pat[:start] + p + pat[i + 1:])
                    if len(out) > _MAX_EXPANSIONS:
                        return out
                return out
    return [pat]


def _norm(glob: str) -> str:
    g = glob.strip()
    while g.startswith("./"):
        g = g[2:]
    return g.lstrip("/").rstrip("/")


def _to_regex(glob: str) -> str:
    out, i, g = [], 0, glob
    while i < len(g):
        if g.startswith("**/", i):
            out.append("(?:[^/]+/)*")
            i += 3
        elif g.startswith("/**", i) and i + 3 == len(g):
            out.append("(?:/.*)?")
            i += 3
        elif g.startswith("**", i):
            out.append(".*")
            i += 2
        elif g[i] == "*":
            out.append("[^/]*")
            i += 1
        elif g[i] == "?":
            out.append("[^/]")
            i += 1
        elif g[i] == "[":
            j = g.find("]", i + 1)
            if j == -1:
                out.append(re.escape(g[i]))
                i += 1
            else:
                cls = g[i + 1:j]
                if cls.startswith("!"):
                    cls = "^" + cls[1:]
                out.append("[" + cls.replace("\\", "\\\\") + "]")
                i = j + 1
        else:
            out.append(re.escape(g[i]))
            i += 1
    return "".join(out)


def _compile(glob: str, flags: int = 0) -> list[re.Pattern]:
    if glob == FLOW_BRACES:
        raise ValueError(glob)
    return [re.compile(_to_regex(_norm(g)), flags) for g in _braces(glob)]


def _hit(regexes: list[re.Pattern], rel: str) -> bool:
    """The path itself, or any directory above it: `deep` covers `deep/x/y.py`."""
    rel = _norm(rel)
    parts = rel.split("/")
    candidates = ["/".join(parts[:n]) for n in range(len(parts), 0, -1)]
    return any(r.fullmatch(c) for r in regexes for c in candidates)


def glob_matches(glob: str, rel: str) -> bool:
    try:
        return _hit(_compile(glob), rel)
    except (re.error, ValueError):
        return False


# --- loading --------------------------------------------------------------------

def _git(root: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True,
                          timeout=30)


def load(root: str, rev: str | None = None, git=None) -> list[Rule]:
    """Every rule under `.claude/rules/` (any depth), sorted by path. With `rev`,
    read from that commit instead of the working tree: a worker can write its
    tree, and a rule read from there would be one it had edited. `git(cwd, *args)`
    replaces the plain runner (the worker passes `dispatch._tree_git`, whose
    environment is scrubbed)."""
    git = git or _git
    files: list[tuple[str, str]] = []
    if rev:
        ls = git(root, "ls-tree", "-r", "--name-only", rev, "--", RULES_DIR)
        for name in sorted(ls.stdout.split("\n") if ls.returncode == 0 else []):
            if name.endswith(".md"):
                show = git(root, "show", f"{rev}:{name}")
                if show.returncode == 0:
                    files.append((name, show.stdout))
    else:
        base = os.path.join(root, RULES_DIR)
        for dirpath, dirs, names in os.walk(base):
            dirs.sort()
            for n in sorted(names):
                if n.endswith(".md"):
                    full = os.path.join(dirpath, n)
                    with open(full, encoding="utf-8", errors="replace") as f:
                        files.append((os.path.relpath(full, root), f.read()))
    rules = []
    for name, text in sorted(files):
        globs, body = parse(text)
        rules.append(Rule(name, globs, body, len(text.encode())))
    return rules


def for_path(rules: list[Rule], rel: str) -> list[Rule]:
    return [r for r in rules if r.applies_to(rel)]


def always(rules: list[Rule]) -> list[Rule]:
    return [r for r in rules if r.globs is None]


# --- the checks -----------------------------------------------------------------

_IMPORT_RE = re.compile(r"(?:^|(?<=\s))@((?:~/|\.{1,2}/)?[\w.\-]+(?:/[\w.\-]+)*)")
_FENCE_RE = re.compile(r"^\s*(```|~~~)")


def _prose(text: str) -> str:
    """Text outside fenced blocks and inline code: Claude Code ignores an @ in code."""
    out, fenced = [], False
    for line in text.split("\n"):
        if _FENCE_RE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            out.append(re.sub(r"`[^`]*`", "", line))
    return "\n".join(out)


def imports(text: str, here: str, root: str, rev: str | None = None) -> list[str]:
    """Repo-relative files an `@path` in `text` pulls in, that exist (in the
    working tree, or at `rev`: the base must be measured the same way as the head,
    or every PR in a repo that imports a big file looks like growth)."""
    found = []
    for m in _IMPORT_RE.finditer(_prose(text)):
        ref = m.group(1)
        if ref.startswith("~/") or ("/" not in ref and "." not in ref):
            continue                      # a home file isn't the repo's; `@name` is a mention
        full = os.path.normpath(os.path.join(os.path.abspath(root), here, ref))
        if not full.startswith(os.path.abspath(root) + os.sep):
            continue
        rel = os.path.relpath(full, os.path.abspath(root))
        there = (_git(root, "cat-file", "-e", f"{rev}:{rel}").returncode == 0 if rev
                 else os.path.isfile(full))
        if there:
            found.append(rel)
    return found


def _read(root: str, rel: str, rev: str | None) -> str | None:
    if rev:
        show = _git(root, "show", f"{rev}:{rel}")
        return show.stdout if show.returncode == 0 else None
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def always_loaded(root: str, rev: str | None = None) -> list[tuple[str, int]]:
    """(file, bytes) for everything Claude Code loads every session in this repo."""
    out: list[tuple[str, int]] = []
    seen: set[str] = set()
    queue = [("CLAUDE.md", 0)]
    while queue:
        rel, depth = queue.pop(0)
        if rel in seen:
            continue
        text = _read(root, rel, rev)
        if text is None:
            continue
        seen.add(rel)
        out.append((rel, len(text.encode())))
        if depth < _IMPORT_DEPTH:
            queue += [(i, depth + 1) for i in imports(text, os.path.dirname(rel), root, rev)]
    rules = load(root, rev) if rev or os.path.isdir(os.path.join(root, RULES_DIR)) else []
    files = _files_at(root, rev)
    out += [(r.path, r.size) for r in rules if r.globs is None or _covers_all(r, files)]
    return out


def _files_at(root: str, rev: str | None) -> list[str]:
    if not rev:
        try:
            return tracked(root)
        except RuntimeError:
            return []
    ls = _git(root, "ls-tree", "-r", "--name-only", "-z", rev)
    return [p for p in ls.stdout.split("\0") if p] if ls.returncode == 0 else []


def _covers_all(rule: Rule, files: list[str]) -> bool:
    """A rule whose globs cover every tracked file (`**`, `*`) loads on the first
    Read of anything, so it is as global as no `paths:` at all and is budgeted so."""
    return bool(rule.globs) and bool(files) and all(rule.applies_to(f) for f in files)


def tracked(root: str) -> list[str]:
    ls = _git(root, "ls-files", "-z")
    if ls.returncode != 0:
        raise RuntimeError(f"git ls-files: {ls.stderr.strip()}")
    return [p for p in ls.stdout.split("\0") if p]


def _base_size(root: str, base: str | None, rel: str) -> int:
    if not base:
        return 0
    text = _read(root, rel, base)
    return len(text.encode()) if text is not None else 0


def check_budget(root: str, base: str | None, always_max: int, file_max: int,
                 files: list[str]) -> list[str]:
    """A ratchet, not a wall: over the cap fails only when the PR made it bigger.
    A repo already over (Claros was 243 KB) can ship anything that doesn't add to
    it, and every PR that trims it moves the line down for good."""
    errors = []
    now = always_loaded(root)
    total = sum(n for _, n in now)
    was = sum(n for _, n in always_loaded(root, base)) if base else 0
    if total > always_max and total > was:
        parts = ", ".join(f"{p} {n}" for p, n in now)
        errors.append(f"always-loaded context is {total} bytes, over {always_max}"
                      + (f" and up from {was}" if base else "")
                      + f" ({parts}). Move a section into a path-scoped rule under "
                      f"{RULES_DIR}/, a skill, or docs/ with a pointer.")
    rules = {r.path: r for r in load(root)} if os.path.isdir(os.path.join(root, RULES_DIR)) else {}
    per_file = [p for p in files if p in rules and rules[p].globs is not None
                and not _covers_all(rules[p], files)]
    per_file += [p for p in files if os.path.basename(p) == "CLAUDE.md" and p != "CLAUDE.md"]
    for p in sorted(set(per_file)):
        size = os.path.getsize(os.path.join(root, p))
        if size > file_max and size > _base_size(root, base, p):
            errors.append(f"{p} is {size} bytes, over {file_max}"
                          + (f" and up from {_base_size(root, base, p)}" if base else "")
                          + ". Split it by the paths it covers.")
    return errors


def check_paths(root: str, files: list[str]) -> list[str]:
    """Every glob must cover at least one tracked file. A rename that strands a
    glob is a rule that silently never loads again: the shape of the ria-2.0/
    flatten, which pointed seven `__file__` paths at the home directory."""
    errors = []
    if not os.path.isdir(os.path.join(root, RULES_DIR)):
        return errors
    dirs = {"/".join(p.split("/")[:n]) for p in files for n in range(1, p.count("/") + 1)}
    universe = sorted(set(files) | dirs)
    for r in load(root):
        for g in r.bad:
            errors.append(f"{r.path}: {g}." if g == FLOW_BRACES else
                          f"{r.path}: `{g}` is not a glob that can be read (a bad [class] "
                          "or too many {{sets}}), so it covers nothing.")
        if r.globs is not None and not r.globs:
            errors.append(f"{r.path}: `paths:` is empty, so it loads for nothing. "
                          "Name its paths, or drop the key to make it global.")
        for g in r.globs or []:
            if g in r.bad:
                continue
            if not any(glob_matches(g, f) for f in universe):
                errors.append(f"{r.path}: `{g}` matches no tracked file, so this rule never "
                              "loads. Fix the glob to where the code is now.")
    return errors


# A pointer worth checking: a relative path with a directory and an extension,
# in backticks or a markdown link. Placeholders (`<id>`, `{x}`, `*`, `$V`) and home
# or absolute paths are the doc talking about a shape, not naming a file.
_REF_RE = re.compile(r"`([^`\s]+)`|\]\(([^)\s#]+)(?:#[^)]*)?\)")
_EXT_RE = re.compile(r"\.[A-Za-z][A-Za-z0-9]{0,7}$")


def refs(text: str) -> list[str]:
    out = []
    for m in _REF_RE.finditer(text):
        ref = (m.group(1) or m.group(2) or "").rstrip(".,;:").lstrip("@")
        ref = re.sub(r":\d+(?::\d+)?$", "", ref)          # file.py:12 is still file.py
        if not ref or re.search(r"[<>{}*$~?|\\\[\]]", ref) or ref.startswith(("/", "http", "-")):
            continue
        if "://" in ref or "/" not in ref.strip("/") or not _EXT_RE.search(ref):
            continue
        while ref.startswith("./"):
            ref = ref[2:]
        out.append(ref)
    return out


def check_refs(root: str, files: list[str], ignore: list[str],
               ref_roots: tuple[str, ...] | list[str] = ()) -> list[str]:
    """Every file CLAUDE.md or a rule points at must exist. Once CLAUDE.md is a
    summary and a pointer, a dead pointer is the rule itself gone. A pointer is
    looked up from the repo root, from the doc's own folder, and from each of
    `ref_roots`: a monorepo whose docs say `src/lib/x.ts` for `apps/frontend/src/lib/x.ts`
    names those folders rather than ignoring its pointers (Claros, v2.96.0)."""
    errors = []
    present = set(files) | {"/".join(p.split("/")[:n]) for p in files for n in range(1, p.count("/") + 1)}
    docs = [p for p in files if os.path.basename(p) == "CLAUDE.md"
            or (p.startswith(RULES_DIR + "/") and p.endswith(".md"))]
    for doc in sorted(docs):
        text = _read(root, doc, None) or ""
        here = os.path.dirname(doc)
        for ref in sorted(set(refs(text))):
            if any(glob_matches(i, ref) for i in ignore):
                continue
            cands = {os.path.normpath(ref), os.path.normpath(os.path.join(here, ref)),
                     *(os.path.normpath(os.path.join(r, ref)) for r in ref_roots)}
            if not cands & present:
                errors.append(f"{doc}: points at `{ref}`, which isn't in the repo. Fix the "
                              "path, or add it to the ignore list if it lives outside git.")
    return errors


def check(root: str, base: str | None, always_max: int, file_max: int,
          ignore: list[str], ref_roots: list[str] = ()) -> list[tuple[str, list[str]]]:
    files = tracked(root)
    return [("budget", check_budget(root, base, always_max, file_max, files)),
            ("rule-paths", check_paths(root, files)),
            ("doc-refs", check_refs(root, files, ignore, ref_roots))]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="claude_rules.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--root", default=".")
    c.add_argument("--base", default=os.environ.get("CLAUDE_BASE") or None)
    c.add_argument("--always-max", type=int,
                   default=int(os.environ.get("CLAUDE_ALWAYS_MAX") or DEFAULT_ALWAYS_MAX))
    c.add_argument("--file-max", type=int,
                   default=int(os.environ.get("CLAUDE_FILE_MAX") or DEFAULT_FILE_MAX))
    c.add_argument("--ignore", action="append",
                   default=[g for g in (os.environ.get("CLAUDE_REFS_IGNORE") or "").split() if g])
    c.add_argument("--ref-root", action="append", dest="ref_roots",
                   default=[g for g in (os.environ.get("CLAUDE_REF_ROOTS") or "").split() if g],
                   help="another folder pointers may be relative to (repeatable)")
    w = sub.add_parser("which")
    w.add_argument("file")
    w.add_argument("--root", default=".")
    ls = sub.add_parser("list")
    ls.add_argument("--root", default=".")
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    if a.cmd == "which":
        rel = os.path.relpath(os.path.abspath(a.file), root) if os.path.isabs(a.file) else a.file
        for r in always(load(root)) + for_path(load(root), rel):
            print(r.path)
        return 0
    if a.cmd == "list":
        for r in load(root):
            print(f"{r.path}\t{r.size}\t" + ("(every session)" if r.globs is None else " ".join(r.globs)))
        return 0
    rc = 0
    for name, errors in check(root, a.base, a.always_max, a.file_max, a.ignore, a.ref_roots):
        for e in errors:
            print(f"::error::{name}: {e}")
        if errors:
            rc = 1
        else:
            print(f"✓ {name}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
