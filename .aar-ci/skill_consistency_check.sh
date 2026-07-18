#!/usr/bin/env bash
# skill_consistency_check.sh (agentic-engineering#54) — five deterministic passes over every
# plugins/*/skills/*/SKILL.md, so the docs-as-policy layer doesn't drift from the tooling or itself:
#   1. wf.sh command existence (verb + scripts/<name> resolution)               — hard-fail
#   2. single-sourced routing (a canonical `<!-- ROUTING:<slug> --> paragraph`)  — flag only
#   3. frontmatter/body agreement (the pipeline-first preference, ship/cloud)   — hard-fail
#   4. retired-phrase denylist (RETIRED_PHRASES.txt, outside marked LEGACY)     — hard-fail
#   5. prohibited-op grep (a fenced-block ambient `gh` WRITE prescription)      — hard-fail
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
# shared: legacy-span computation (pass 4 + pass 5's carve-out)
# ---------------------------------------------------------------------------
LEGACY_START = "<!-- LEGACY:START -->"
LEGACY_END = "<!-- LEGACY:END -->"


def legacy_spans(text):
    spans = []
    pos = 0
    while True:
        s = text.find(LEGACY_START, pos)
        if s == -1:
            break
        e = text.find(LEGACY_END, s)
        if e == -1:
            spans.append((s, len(text)))
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
    for m in re.finditer(r'^([A-Za-z][A-Za-z0-9_-]*(?:\|[A-Za-z0-9_-]+)*)\)', wf_text, re.M):
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
        warn("pass1: could not extract wf.sh's 'issue' sub-verb allowlist — issue sub-verbs will not be checked")
    if not fdispo_subverbs:
        warn("pass1: could not extract wf.sh's 'fdispo' sub-verb allowlist — fdispo actions will not be checked")
else:
    err(f"pass1: wf.sh not found at {relpath(WF_PATH)} — cannot validate wf.sh verbs")


def clean_token(tok):
    return tok.strip('`*_,.()')


def first_real_token(tokens):
    for tok in tokens:
        ctok = clean_token(tok)
        if ctok and not ctok.startswith('<'):
            return ctok
    return None


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
            sub = first_real_token(rest)
            if sub is not None:
                pieces = [clean_token(p) for p in sub.split('|')]
                bad = [p for p in pieces if p and p not in issue_subverbs]
                if bad:
                    err(f"pass1: {rel}: prescribes 'wf.sh issue ... {sub}' — unknown issue sub-verb(s) {bad}")
        if verb == "fdispo" and fdispo_subverbs:
            sub = first_real_token(rest)
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
else:
    err(f"pass4: retired-phrase denylist not found at {relpath(DENYLIST_PATH)}")

pass4_hits = 0
for path, text in docs.items():
    rel = relpath(path)
    spans = legacy_spans(text)
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
# Pass 5 — prohibited-op grep: a fenced-block ambient `gh` WRITE prescription (hard-fail)
# ---------------------------------------------------------------------------
ISSUE_WRITE_VERBS = {"create", "edit", "close", "delete", "lock", "reopen", "transfer", "pin", "unpin"}
PR_WRITE_VERBS = {
    "create", "edit", "close", "delete", "lock", "merge", "reopen", "ready", "review", "comment",
    "update-branch",
}
NEGATION_RE = re.compile(r"\b(never|not|don'?t|avoid|no bare|against|prohibited|forbidden)\b", re.I)
RESEARCHER_RE = re.compile(r"researcher", re.I)
GH_WRITE_RE = re.compile(r"\bgh\s+(issue|pr)\s+([a-z][a-z-]*)", re.I)


def fenced_blocks(text):
    spans = []
    offset = 0
    open_at = None
    for line in text.split("\n"):
        if line.strip().startswith("```"):
            if open_at is None:
                open_at = offset
            else:
                spans.append((open_at, offset + len(line)))
                open_at = None
        offset += len(line) + 1
    return spans


pass5_checked = 0
for path, text in docs.items():
    rel = relpath(path)
    spans = legacy_spans(text)
    for fstart, fend in fenced_blocks(text):
        block = text[fstart:fend]
        for m in GH_WRITE_RE.finditer(block):
            pass5_checked += 1
            noun, verb = m.group(1).lower(), m.group(2).lower()
            verbs = ISSUE_WRITE_VERBS if noun == "issue" else PR_WRITE_VERBS
            if verb not in verbs:
                continue
            abs_pos = fstart + m.start()
            if in_spans(abs_pos, spans):
                continue
            preceding = text[max(fstart, abs_pos - 60): abs_pos]
            if NEGATION_RE.search(preceding):
                continue
            researcher_window = text[max(fstart, abs_pos - 200): abs_pos]
            if RESEARCHER_RE.search(researcher_window):
                continue
            line_no = text.count("\n", 0, abs_pos) + 1
            err(
                f"pass5: {rel}:{line_no}: fenced block prescribes ambient 'gh {noun} {verb}' (a WRITE op) "
                f"outside a researcher-action or legacy-marked context"
            )

note(f"pass5: checked {pass5_checked} fenced 'gh issue|pr' mention(s)")

print("[skill-consistency] " + ("FAIL" if fail else "PASS"), file=sys.stderr)
sys.exit(1 if fail else 0)
PY
