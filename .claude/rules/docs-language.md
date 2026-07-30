# Documentation Language

## The rule

**Every Markdown file in this repository is written in English.** That includes
`README.md`, `GUIDE.md`, `ISSUES.md`, everything under `docs/`,
`claude-skill/`, and `.claude/` itself.

**The GitHub repository description ("About") and topics are English too.**
`better-ci/npu-taskqueue` is public; the About line is the first thing a reader
outside the team sees.

## The one sanctioned translation

`GUIDE_ZH.md` is a Chinese mirror of `GUIDE.md`. It exists because `GUIDE.md`'s
readers are the people on this machine, not the internet.

- **Edit both, in the same commit.** A `GUIDE.md` change without the matching
  `GUIDE_ZH.md` change leaves users reading stale instructions in the language
  they actually use — worse than having no translation.
- `GUIDE.md` is the source; `GUIDE_ZH.md` follows it.
- Each file links to the other at the top. Keep those links.
- **Do not add more `_ZH` pairs** without asking. Every pair is a drift risk;
  this one is justified by its audience, and `README`, `ISSUES`, `docs/` and
  `.claude/` are not.

## What stays in Chinese

**Anything the scripts print, and the comments explaining them.** The people who
run `task-submit` on this machine read Chinese; their error messages, prompts,
and daemon log lines are a product surface, not documentation. Do not translate
them as a drive-by change — that is a user-visible behaviour change and belongs
in its own commit, with the owner's agreement.

| Artifact | Language |
|---|---|
| `*.md` (all of them) | English |
| GitHub About, topics, release notes | English |
| Commit messages, PR titles and bodies, issue text | English |
| Comments inside `*.sh` | Chinese (match the file you are editing) |
| `echo` / `log` strings shown to users | Chinese |
| Identifiers, file names, config keys | English (already true) |

## Quoting Chinese output inside an English doc

Quote it **verbatim**. A translated quote cannot be grepped for, and the reader
will be looking at the Chinese string on their terminal:

```markdown
✅ The reaper writes "任务被中断（daemon 停止或重启）" into the log, so a
   successful task looks killed.

❌ The reaper writes "task interrupted (daemon stopped or restarted)" into the
   log — no such string exists in the code.
```

The same applies to file paths, option names, and log prefixes: reproduce what
the code actually emits.

## Applying it to existing files

- New Markdown file → English, no exceptions.
- Editing an existing English file → stay English.
- Touching a Chinese Markdown file that predates this rule → convert the whole
  file if you are substantially rewriting it; otherwise leave the surrounding
  text alone rather than leaving a half-translated file behind.

As of 2026-07-29 all Markdown in the repository has been converted, so in
practice you should never meet the third case.

## Writing style

Plain, specific English. This documentation is read by people who are not
reading in their first language, and by agents that will act on it.

- Prefer short sentences and concrete nouns over idiom.
- Say what happens, not what "should" happen. `--max-time` defaults to 300s and
  kills the task; do not write "tasks are expected to be short".
- Keep the imperative for instructions: "Run `deploy.sh` from this repository",
  not "one should deploy via `deploy.sh`".
- Tables for comparisons, code blocks for anything a reader will copy.
