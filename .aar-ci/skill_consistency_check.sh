#!/usr/bin/env bash
# skill_consistency_check.sh (agentic-engineering#54) — four deterministic passes over every
# plugins/*/skills/*/SKILL.md, so the docs-as-policy layer doesn't drift from the tooling or itself:
#   1. wf.sh command existence (verb + scripts/<name> resolution)               — hard-fail
#   2. single-sourced routing (a canonical `<!-- ROUTING:<slug> --> paragraph`)  — flag only
#   3. frontmatter/body agreement (the pipeline-first preference, ship/cloud)   — hard-fail
#   4. retired-phrase denylist (RETIRED_PHRASES.txt, outside marked LEGACY)     — hard-fail
# Ambient `gh` write hygiene is intentionally NOT a pass here: it's enforced at RUNTIME by ship-change's
# gh-guard.sh, which blocks the write and redirects to the wf.sh path. A former pass 5 tried to mirror the
# guard's argument parser at doc-time and was removed as an unmaintainable divergence burden — deliberate
# researcher decision, 2026-07-18, deviating from this issue's original five-pass design (see
# agentic-engineering#57's review history).
# Runs unconditionally against the FULL plugins/ tree (doc consistency is a whole-tree invariant, not an
# incremental-diff property) — no non-goal semantic/LLM checking, no enforcement outside plugins/.
# Usage: skill_consistency_check.sh [root]   — root defaults to this script's own repo (optional override
# lets skill_consistency_check_smoke.sh point it at a fixture tree instead of the real repo).
set -uo pipefail
if [ "$#" -ge 1 ]; then
  ROOT="$1"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

python3 - "$ROOT" <<'PY'
import glob
import os
import re
import sys

ROOT = sys.argv[1]
fail = False


def note(msg):
    print(f"  {msg}", file=sys.stderr)


def warn(msg):
    print(f"  WARN: {msg}", file=sys.stderr)


def err(msg):
    global fail
    print(f"  FAIL: {msg}", file=sys.stderr)
    fail = True


def relpath(p):
    return os.path.relpath(p, ROOT)


skill_files = sorted(glob.glob(os.path.join(ROOT, "plugins", "*", "skills", "*", "SKILL.md")))
docs = {}
for p in skill_files:
    with open(p, encoding="utf-8") as f:
        docs[p] = f.read()

note(f"scanning {len(docs)} SKILL.md file(s) under plugins/")


def split_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            return text[4:end], text[end + 4:]
    return "", text


# ---------------------------------------------------------------------------
# shared: legacy-span computation (pass 4's carve-out)
# ---------------------------------------------------------------------------
LEGACY_START = "<!-- LEGACY:START -->"
LEGACY_END = "<!-- LEGACY:END -->"


def legacy_spans(text, rel):
    spans = []
    pos = 0
    while True:
        s = text.find(LEGACY_START, pos)
        if s == -1:
            break
        e = text.find(LEGACY_END, s)
        if e == -1:
            err(f"legacy: {rel}: unmatched <!-- LEGACY:START --> at offset {s} with no matching "
                "<!-- LEGACY:END --> — fails closed (no legacy carve-out for the rest of the file)")
            break
        spans.append((s, e + len(LEGACY_END)))
        pos = e + len(LEGACY_END)
    # A markdown heading whose text contains the word LEGACY marks a section that runs to the next
    # heading of equal-or-shallower depth (or EOF) — matches agentic-engineering#51's real convention
    # (e.g. "### LEGACY — the dispatcher contract (fallback path only)") without requiring it verbatim.
    headings = [(m.start(), len(m.group(1)), m.group(0)) for m in re.finditer(r'^(#{1,6})[^\n]*$', text, re.M)]
    for i, (hstart, depth, htext) in enumerate(headings):
        if re.search(r'\bLEGACY\b', htext):
            hend = len(text)
            for j in range(i + 1, len(headings)):
                if headings[j][1] <= depth:
                    hend = headings[j][0]
                    break
            spans.append((hstart, hend))
    return spans


def in_spans(pos, spans):
    return any(s <= pos < e for s, e in spans)


# ---------------------------------------------------------------------------
# Pass 1 — wf.sh command existence + scripts/<name> resolution (hard-fail)
# ---------------------------------------------------------------------------
WF_PATH = os.path.join(ROOT, "plugins", "aar-engineering", "skills", "ship-change", "scripts", "wf.sh")
top_verbs = set()
issue_subverbs = set()
fdispo_subverbs = set()

if os.path.isfile(WF_PATH):
    wf_text = open(WF_PATH, encoding="utf-8").read()
    # Top-level case labels sit at column 0 inside `case "$CMD" in ... esac`; nested case blocks (the
    # issue/fdispo sub-dispatch) are indented, so a column-0 anchor safely extracts only the real verbs.
    # A verb retired down to a bare `die "... retired ..."` body (e.g. `classify`,
    # automated-researcher#248) is excluded — inspecting the arm's first non-comment statement keeps this
    # self-maintaining for future retirements.
    RETIRED_DIE_RE = re.compile(r'^die\s+"[^"]*retired')
    verb_matches = list(re.finditer(r'^([A-Za-z][A-Za-z0-9_-]*(?:\|[A-Za-z0-9_-]+)*)\)', wf_text, re.M))
    for i, m in enumerate(verb_matches):
        body_end = verb_matches[i + 1].start() if i + 1 < len(verb_matches) else len(wf_text)
        first_stmt = None
        for line in wf_text[m.end():body_end].split('\n'):
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            first_stmt = stripped
            break
        if first_stmt and RETIRED_DIE_RE.match(first_stmt):
            continue
        top_verbs.update(m.group(1).split('|'))
    m = re.search(
        r"only '([a-zA-Z_-]+)', '([a-zA-Z_-]+)', '([a-zA-Z_-]+)', '([a-zA-Z_-]+)', '([a-zA-Z_-]+)' are allowed",
        wf_text,
    )
    if m:
        issue_subverbs.update(m.groups())
    m = re.search(r'wf\.sh fdispo <worktree> <author> <([a-z|]+)>', wf_text)
    if m:
        fdispo_subverbs.update(m.group(1).split('|'))
    if not top_verbs:
        err("pass1: could not extract any top-level wf.sh verbs from wf.sh — parser or wf.sh itself may be broken")
    if not issue_subverbs:
        err("pass1: could not extract wf.sh's 'issue' sub-verb allowlist — a wf.sh format change must break "
            "this check visibly, not silently disable it")
    if not fdispo_subverbs:
        err("pass1: could not extract wf.sh's 'fdispo' sub-verb allowlist — a wf.sh format change must break "
            "this check visibly, not silently disable it")
elif not os.path.isdir(os.path.join(ROOT, "plugins", "aar-engineering")):
    # agentic-engineering#61: a self-hosted install of the GitHub-native SWE pipeline (workflows +
    # .aar-ci/) need not ship the aar-engineering plugin. wf.sh is that plugin's own tooling, so its
    # presence is required exactly when the plugin is present — a target repo's OWN skills still get
    # every plugin-agnostic pass (scripts/<name> resolution, routing, retired phrases when a denylist
    # exists), and any `wf.sh <verb>` they prescribe still fails pass 1 (no verbs extractable).
    note("pass1: plugins/aar-engineering not present (self-hosted install without the aar-engineering plugin) — skipping wf.sh verb validation")
else:
    err(f"pass1: wf.sh not found at {relpath(WF_PATH)} — cannot validate wf.sh verbs")


def clean_token(tok):
    return tok.strip('`*_,.()')


def token_at(tokens, idx):
    # The real wf.sh CLI shapes are POSITIONAL, not "first concrete word": `wf.sh issue <family>
    # <subverb> ...` puts the sub-verb right after the family token (claude/codex) regardless of
    # whether the family itself is a placeholder or a concrete worked-example value (`wf.sh issue codex
    # create` — `codex` is NOT the sub-verb even though it's the first non-placeholder token); `wf.sh
    # fdispo <worktree> <author> <disposition>` puts two positional args before the disposition. So we
    # index by fixed position and only skip validation when THAT position is itself an angle-bracket
    # placeholder (a generic usage line, not a concrete prescription).
    if idx >= len(tokens):
        return None
    ctok = clean_token(tokens[idx])
    if not ctok or ctok.startswith('<'):
        return None
    return ctok


def wf_calls(text):
    for m in re.finditer(r'wf\.sh\s+([A-Za-z][A-Za-z0-9_-]*)((?:\s+\S+){0,3})', text):
        yield m.group(1), m.group(2).split()


pass1_checked = 0
for path, text in docs.items():
    rel = relpath(path)
    for verb, rest in wf_calls(text):
        pass1_checked += 1
        if verb not in top_verbs:
            err(f"pass1: {rel}: prescribes 'wf.sh {verb}' — no such wf.sh verb")
            continue
        if verb == "issue" and issue_subverbs:
            sub = token_at(rest, 1)  # rest[0] is the family (claude|codex); the sub-verb follows it
            if sub is not None:
                pieces = [clean_token(p) for p in sub.split('|')]
                bad = [p for p in pieces if p and p not in issue_subverbs]
                if bad:
                    err(f"pass1: {rel}: prescribes 'wf.sh issue ... {sub}' — unknown issue sub-verb(s) {bad}")
        if verb == "fdispo" and fdispo_subverbs:
            sub = token_at(rest, 2)  # rest[0], rest[1] are worktree, author; the disposition follows them
            if sub is not None:
                pieces = [clean_token(p) for p in sub.split('|')]
                bad = [p for p in pieces if p and p not in fdispo_subverbs]
                if bad:
                    err(f"pass1: {rel}: prescribes 'wf.sh fdispo ... {sub}' — unknown fdispo action(s) {bad}")

    for m in re.finditer(r'scripts/[A-Za-z0-9_.-]+', text):
        ref = m.group(0)
        candidate = os.path.join(os.path.dirname(path), ref)
        if not os.path.isfile(candidate):
            err(f"pass1: {rel}: references '{ref}' which does not resolve to a file at {relpath(candidate)}")

note(f"pass1: checked {pass1_checked} wf.sh invocation(s)")

# ---------------------------------------------------------------------------
# Pass 2 — single-sourced routing (flag-only; never sets fail)
# ---------------------------------------------------------------------------
STOPWORDS = set("""
about above after again against all also although always among another any anyone anything around
because been before being below between cloud-ship could deployment doesn't does every everyone
first from further ready-gated shall should skill skills their there these those which while would
""".split())


def significant_words(sentence):
    words = re.findall(r"[a-zA-Z']{5,}", sentence.lower())
    return {w for w in words if w not in STOPWORDS}


ROUTING_RE = re.compile(r'<!--\s*ROUTING:([a-zA-Z0-9_-]+)\s*-->')
ROUTING_END_RE = re.compile(r'<!--\s*ROUTING-END:([a-zA-Z0-9_-]+)\s*-->')

anchors = {}
for path, text in docs.items():
    for m in ROUTING_RE.finditer(text):
        slug = m.group(1)
        end_m = ROUTING_END_RE.search(text, m.end())
        if end_m and end_m.group(1) == slug:
            block_end = end_m.end()
        else:
            nxt = text.find("\n\n", m.end())
            block_end = nxt if nxt != -1 else len(text)
        anchors.setdefault(slug, []).append((path, m.start(), block_end))

if not anchors:
    note("pass2: no <!-- ROUTING:<slug> --> anchors registered yet — nothing to cross-check")

for slug, locs in anchors.items():
    if len(locs) > 1:
        warn(
            f"pass2: routing concern '{slug}' has {len(locs)} canonical anchors (expected exactly one): "
            + ", ".join(relpath(p) for p, _, _ in locs)
        )
        continue
    path, start, end = locs[0]
    text = docs[path]
    block = text[start:end]
    first_sentence = re.split(r'(?<=[.!?])\s', block, maxsplit=1)[0]
    fingerprint = significant_words(first_sentence)
    if len(fingerprint) < 3:
        continue
    for other_path, other_text in docs.items():
        for m in re.finditer(r'[^\n]+', other_text):
            if other_path == path and start <= m.start() < end:
                continue
            line = m.group(0)
            overlap = fingerprint & significant_words(line)
            if len(overlap) >= min(3, len(fingerprint)):
                warn(
                    f"pass2: possible restatement of routing concern '{slug}' (canonical: {relpath(path)}) "
                    f"in {relpath(other_path)}: {line.strip()[:140]}"
                )

# ---------------------------------------------------------------------------
# Pass 3 — frontmatter/body agreement (hard-fail on detected drift)
# ---------------------------------------------------------------------------
SHIP_CHANGE = os.path.join(ROOT, "plugins", "aar-engineering", "skills", "ship-change", "SKILL.md")
CLOUD_SHIP = os.path.join(ROOT, "plugins", "aar-engineering", "skills", "cloud-ship", "SKILL.md")

UNQUALIFIED_PREF_RE = re.compile(r"prefer\w*\s+(?:the\s+)?(?:sibling\s+)?`?cloud-ship`?", re.I)
QUALIFIER_RE = re.compile(r"without|non-pipeline|not run|does ?n[o']t run", re.I)
SUBORDINATION_RE = re.compile(
    r"cloud-ship`?\s*(?:skill)?[^.\n]{0,80}\b(without the pipeline|non-pipeline repos)\b", re.I
)

unqualified_hits = []
subordination_hits = []
for path in (SHIP_CHANGE, CLOUD_SHIP):
    text = docs.get(path)
    if text is None:
        continue
    fm, body = split_frontmatter(text)
    for region_name, region_text in (("frontmatter", fm), ("body", body)):
        for m in UNQUALIFIED_PREF_RE.finditer(region_text):
            window = region_text[max(0, m.start() - 60): m.end() + 120]
            if not QUALIFIER_RE.search(window):
                unqualified_hits.append((path, region_name, m.group(0)))
        for m in SUBORDINATION_RE.finditer(region_text):
            subordination_hits.append((path, region_name, m.group(0)))

if unqualified_hits and subordination_hits:
    subord_desc = "; ".join(f"{relpath(p)} ({r}): {s!r}" for p, r, s in subordination_hits)
    for path, region, snippet in unqualified_hits:
        err(
            f"pass3: {relpath(path)} ({region}): unqualified cloud-ship preference ({snippet!r}) contradicts "
            f"a pipeline-first subordination claim found elsewhere ({subord_desc}) — the pipeline-first "
            f"preference assertion must agree across ship-change/cloud-ship frontmatter + body"
        )
else:
    note("pass3: pipeline-first preference assertion — no drift detected")

# ---------------------------------------------------------------------------
# Pass 4 — retired-phrase denylist (hard-fail)
# ---------------------------------------------------------------------------
DENYLIST_PATH = os.path.join(ROOT, "plugins", "aar-engineering", "RETIRED_PHRASES.txt")
phrases = []
if os.path.isfile(DENYLIST_PATH):
    for line in open(DENYLIST_PATH, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            phrases.append(line)
elif not os.path.isdir(os.path.join(ROOT, "plugins", "aar-engineering")):
    # agentic-engineering#61: same rationale as pass 1 — the denylist ships with the aar-engineering
    # plugin, so only its presence makes the denylist required.
    note(f"pass4: retired-phrase denylist not found at {relpath(DENYLIST_PATH)} and plugins/aar-engineering not present — skipping")
else:
    err(f"pass4: retired-phrase denylist not found at {relpath(DENYLIST_PATH)}")

legacy_spans_by_path = {path: legacy_spans(text, relpath(path)) for path, text in docs.items()}

pass4_hits = 0
for path, text in docs.items():
    rel = relpath(path)
    spans = legacy_spans_by_path[path]
    lower = text.lower()
    for phrase in phrases:
        plower = phrase.lower()
        start = 0
        while True:
            idx = lower.find(plower, start)
            if idx == -1:
                break
            start = idx + 1
            if in_spans(idx, spans):
                continue
            pass4_hits += 1
            line_no = text.count("\n", 0, idx) + 1
            err(f"pass4: {rel}:{line_no}: retired phrase '{phrase}' appears outside a marked legacy section")

note(f"pass4: checked {len(phrases)} retired phrase(s) against {len(docs)} file(s), {pass4_hits} unmarked hit(s)")

# ---------------------------------------------------------------------------
# (No pass 5 here.) Ambient `gh` write hygiene is enforced at RUNTIME by ship-change's gh-guard.sh, which
# blocks the write and redirects to the wf.sh path. A doc-time textual mirror of the guard's argument
# parser was removed as unmaintainable (see this PR's review history) — deliberate researcher decision,
# 2026-07-18, deviating from agentic-engineering#54's original five-pass design.
# ---------------------------------------------------------------------------

print("[skill-consistency] " + ("FAIL" if fail else "PASS"), file=sys.stderr)
sys.exit(1 if fail else 0)
PY
