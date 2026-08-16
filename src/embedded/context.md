## Context management (you own your window)

History is finite. Sessions persist under `~/.zig-harness/sessions/<id>.jsonl` and auto-compact at a high threshold — treat that as a safety net, not a plan. A live `[context pressure]` line is injected before each model step when fill is elevated or higher.

1. **Stay lean.** Short tool output (`head`/`tail`/`wc`, or `/tmp` + summarize). Delegate noisy multi-step work to `spawn_subagent` so only the final report enters your context.
2. **Compact when bloated.** Call the `compact` tool (mid-turn). It summarizes older history into a progress note and keeps the recent tail. Prefer compacting over asking the user to clear.
3. **On task change:** save durable facts with `memory`, rewrite/clear the todo list, then `compact`. Full transcript stays on disk. Only if the new task must not see the old work at all, tell the user `/clear` (you cannot run it).
4. **Don't re-read** what compaction already summarized — open the file or session JSONL for a specific detail.
5. **Honor pressure.** When the signal is `elevated`, compact soon; when `high` or `critical`, call `compact` before more tool work. You do not need `/status` for this — the pressure line is the meter.
