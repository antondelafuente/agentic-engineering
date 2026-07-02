# The CLOUD-SHIP RUN record contract

The one machine-readable seam between the cloud author/review leg and the box-side close. The cloud leg posts
exactly one comment of this shape on the issue; `close-cloud-ship.sh` parses its header lines and copies the
whole thing onto the PR it opens.

## Shape

```
CLOUD-SHIP RUN (do not merge by hand — box closes the loop)
Branch: <branch>
Reviewed-Head: <40-hex sha of the final reviewed commit>
Verdict: PASS
Rounds: design=<n> code=<n>

<final codex design-review verdict text>

<final codex code-review text>
```

## Parsing rules (what the gate enforces, fail-closed)

- The record's first **non-blank** line must start with `CLOUD-SHIP RUN`.
- `Branch:` — the first line matching `^Branch:[[:space:]]*<token>$`. Must equal the branch the box was asked
  to close (anti-replay: a PASS record copied from another branch can't authorize this one).
- `Reviewed-Head:` — the first line matching `^Reviewed-Head:[[:space:]]*<hex>$`. Must be a **full 40-hex**
  object id (a short/symbolic ref would not pin the merge), and must equal the live branch head at close time
  (anti-post-review-push: the box merges only the exact reviewed sha).
- `Verdict:` — the first line matching `^Verdict:[[:space:]]*<token>$`. Must be exactly `PASS`; anything else
  (incl. `FAIL`, empty, or a trailing extra token like `PASS now`) refuses.
- `Rounds:` and the review text are **not** gated — they are the durable human/audit trail the box copies
  onto the PR.

## Producer contract (the cloud leg)

- Post the record only after the branch is pushed and the review is `VERDICT: PASS`.
- `Reviewed-Head` MUST be the sha you pushed. After posting the record, do **not** push another commit — a
  post-review push moves the head off `Reviewed-Head` and the box gate refuses to merge.
- Post as the connecting user (a cloud VM has no bot keys). Do not open a PR; do not touch main.
