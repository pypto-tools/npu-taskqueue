# Documentation and File Length

## Limits

| File type | Limit |
|---|---|
| Markdown docs (`*.md`) | ≤500 lines |
| Rules (`.claude/rules/`) | ≤200 lines |
| Skills (`.claude/skills/`) | ≤200 lines |
| Shell scripts | no hard limit, but see below |

Current state: `task-submit.sh` is 1,306 lines and `task-daemon.sh` is 797.
Neither is required to shrink, but do not grow them with content that belongs in
a new function or a doc.

## Over the limit? Condense first, split second

**500-700 lines → condense.**

- Tables instead of paragraphs for anything comparative.
- One representative example per concept, not five variations.
- Cut "why" that the reader can infer; keep "why" that cost someone a weekend.
  The incident write-ups in `ISSUES.md` are the second kind — they are why the
  code looks the way it does. Do not condense those away.
- Cross-reference instead of repeating. `GUIDE.md` should not restate `README.md`.

**>700 lines → split by topic**, one file per topic under `docs/`:

```text
docs/
├── interactive-mode.md     stdin forwarding via FIFO
├── device-allocation.md    whitelist, pools, auto vs explicit  (example)
└── kill-paths.md           the five termination sites          (example)
```

Split when the sections are genuinely independent and each stands alone. A file
that is long because one mechanism is intricate should stay one file.

## Structure

Written for someone scanning, and for an agent acting on it:

- Headings that name the thing (`## Changing the device pool`), not the category
  (`## Configuration`).
- Code blocks with a language tag, containing commands that actually run.
- Tables for comparisons and mappings (source file → installed path).
- The instruction before the explanation. A reader who already knows *why* wants
  the command in the first two lines.

For rules and skills specifically: essential content only, decision criteria
over prose, and reference the other file instead of duplicating it.

## Checklist

- [ ] Within the limit for its type
- [ ] Every command shown has been run, or is marked as an example
- [ ] No content duplicated from another file in the repo
- [ ] Comparisons are tables
- [ ] Cross-references point at files that exist
- [ ] Understandable in two minutes of scanning

## Exceptions

Ask the user before exceeding a limit. Reference material (a full option
reference, a protocol description) and step-by-step migration guides are the
usual legitimate cases. Try condensing first.
