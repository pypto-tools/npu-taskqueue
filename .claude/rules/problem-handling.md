# Problem Handling and Issue Tracking

## Core principle

**Classify every technical problem you hit as blocking or non-blocking, then act
accordingly.** Never silently work around one, and never assume away a
discrepancy between what the code does and what the documentation says.

```text
Problem found
├─ Does it block the current task?
│  ├─ YES → stop, describe it, present options, wait for the user
│  └─ NO  → record it (see routing below), continue the current task
```

## Blocking problems

You cannot make correct progress without an answer. Examples: the installed copy
of a script differs from the repository and you do not know which is intended;
a change would alter what queue users see on their terminals; the whitelist in
`conf/` contradicts the documented device partition and your change depends on
which is right.

Stop. Describe what you found, what you expected, and why it blocks. Lay out the
options with their trade-offs. Wait. Do not pick one and continue.

When unsure whether something is blocking, ask — this repository schedules other
people's work on shared hardware, and a wrong assumption costs them hours.

## Non-blocking problems: where they go

Two files, and the split is about **publication**, not importance.

| | `ISSUES.md` | `KNOWN_ISSUES.md` |
|---|---|---|
| Committed | Yes | No — git-ignored |
| Audience | Anyone on the internet | Whoever has a checkout |
| Contains | Defect description, affected file:line, intended fix | Exploitation detail, reproduction steps, working PoC |

**`better-ci/npu-taskqueue` is a public repository.** A reproduction for an
unfixed privilege-escalation or credential-disclosure bug in `ISSUES.md` is a
disclosure against a machine that ~50 people are logged into right now.

### Routing

1. **Security defect, not yet fixed** — full detail (repro, PoC, fix sketch) goes
   in `KNOWN_ISSUES.md`. `ISSUES.md` gets a one-line entry naming the defect and
   the file, with **no reproduction**: "daemon does not verify task-file
   ownership … Fix: derive the user from `stat -c %U`" is right; a copy-pasteable
   forged task file is not.
2. **Security defect, fixed and deployed** — move the full detail into
   `ISSUES.md` as a resolved entry (past tense, struck-through title, like issues
   4 and 11) and delete it from `KNOWN_ISSUES.md`. The incident write-up is the
   most valuable thing in that file; it just has to land *after* the fix.
3. **Everything else** — straight into `ISSUES.md`, numbered, under P0 / P1 / P2.

**`ISSUES.md` must never reference `KNOWN_ISSUES.md`**, by name or implication.
An external reader cannot see it, and "see the local file" advertises that
something is being withheld.

## Entry quality

Both files hold the same bar: an entry is **self-contained**. A reader in two
months — you, or a new maintainer — must understand the problem without
re-deriving it.

- **State the actual and the expected behaviour, and the consequence.**
  ✅ "`reap_orphans` finalizes a task while `run_task` is still sweeping it, so a
  successful task is reported to `--wait` as killed and its device is freed while
  processes still hold it."
  ❌ "Race in the reaper."
- **Anchor it**: `file.sh:120-140`, or a function name. Line numbers drift;
  include the function too.
- **Show the evidence.** The smallest artefact that demonstrates it: the exact
  command and its output, a four-line shell snippet, the log lines. If you
  verified a claim experimentally, paste the transcript — `ISSUES.md` issue 3 was
  wrong for months because nobody ran the two-line check that disproves it.
- **Say what the fix is**, in one or two sentences. An entry with no direction is
  a complaint.

If you cannot produce concrete evidence, treat that as a sign the problem is not
yet understood, and say so to the user rather than filing a vague entry.

## Do not log

- Something you are fixing in this task — fix it.
- A limitation already documented in `README.md` or `GUIDE.md`.
- A user misconfiguration.
- A duplicate. Read the existing entries first; the numbering runs to 24.

## On task completion

Before you finish:

1. Re-read both files.
2. Remove entries your change resolved — from `ISSUES.md` by striking the title
   through and dating the resolution (that history is deliberate); from
   `KNOWN_ISSUES.md` by deleting the entry after promoting it.
3. Summarize what remains for the user. Do not ask them to fix it now.
