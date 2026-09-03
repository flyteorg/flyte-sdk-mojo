---
name: gtm
description: >
  Union's GTM content factory — blog posts, video scripts, social posts
  (LinkedIn/Bluesky/Reddit/HackerNews), conference abstracts, presentations,
  media commentary, and partner co-marketing — lives in the `gtm/` submodule
  (`unionai/gtm`). Use this skill whenever the user wants to draft, plan, or
  research any GTM content for Union or Flyte, apply Niels's writing voice,
  work a partner engagement (MongoDB or new partners), capture a press/media
  commentary request, or push drafts to Notion review — even if they don't
  say "gtm" by name. The executable procedures are slash-command skills inside
  the submodule; read the matching command file before doing the work.
---

# GTM content — `gtm/` submodule

`gtm/` is a git submodule of `unionai/gtm`: a **content factory** where each
task is a procedure file that researches the topic, drafts canonical Markdown,
and saves it under `content/`. The procedures are Claude Code slash commands in
`gtm/.claude/commands/`; they are complete, self-contained runbooks — **read
the matching file in full before doing the work**, then follow it. Do not
improvise the research or the output format around them.

## Routing

| Task | Read this procedure first |
|---|---|
| Research a topic across Slack/Notion/docs/GitHub | `gtm/.claude/commands/gather-context.md` |
| Blog post → `content/blogs/` | `gtm/.claude/commands/write-blog.md` |
| Video script → `content/video-scripts/` | `gtm/.claude/commands/write-video-script.md` |
| Code snippets + visuals for a script's shot table | `gtm/.claude/commands/write-video-assets.md` |
| LinkedIn/Bluesky/Reddit/HackerNews posts | `gtm/.claude/commands/write-social-posts.md` |
| Conference talk title + abstract | `gtm/.claude/commands/write-conference-abstract.md` |
| AI Engineer NYC 2026 CFP abstract | `gtm/.claude/commands/write-aie-nyc-abstract.md` |
| Slide-deck outline (then deck generation) | `gtm/.claude/commands/write-presentation.md` |
| Journalist/press commentary request | `gtm/.claude/commands/media-commentary.md` |
| Push `status: draft` files to Notion review | `gtm/.claude/commands/sync-to-notion.md` |
| Apply Niels Bantilan's voice to a draft | `gtm/.claude/commands/niels-bantilan-style.md` |
| Scaffold `partner/<slug>/` workspace | `gtm/.claude/commands/partner-kickoff.md` |
| Summarize a partner meeting transcript | `gtm/.claude/commands/partner-meeting-notes.md` |
| Joint/co-branded partner blog post | `gtm/.claude/commands/partner-blog.md` |
| Tiered partner integration proposal | `gtm/.claude/commands/partner-proposal.md` |

## Conventions (from `gtm/CLAUDE.md` — read it for the full picture)

- Filenames: `YYYY-MM-DD-<kebab-slug>.md`; the date is the intended publish
  date. Slugs short and topical.
- Draft lifecycle: `status: draft` frontmatter → `/sync-to-notion` → team
  reviews in Notion → author updates → `status: published` when live.
- Write commands check for an existing draft on the same topic first, so
  blog + video + social on one topic don't re-research.
- Notion review pages (blog/video/social/media) and the canonical source
  URLs (Union/Flyte user guides, example repos, blogs) are tabulated in
  `gtm/CLAUDE.md` — use those, not guessed links.
- Audience: ML engineers, MLOps, platform engineers. Technical accuracy over
  marketing claims; concrete code over abstractions; honest tradeoffs.

## Submodule mechanics

- New checkout: `git submodule update --init gtm` (or `--init --recursive`).
- Changes inside `gtm/` are commits to `unionai/gtm`, not to this repo:
  branch, commit, and push **inside `gtm/`**, then update the submodule pin
  here only when the pointer should move.
- The command files reference Notion/Slack MCP tools from their Claude Code
  home. If those tools aren't available in the current harness, do the local
  work (research notes, drafts) and tell the user which fetches to run or
  which credentials to supply.
