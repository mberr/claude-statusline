# claude-statusline

A three-line [status line](https://code.claude.com/docs/en/statusline) for Claude Code that shows where you are, the state of the current session, and your usage limits and cost. It fits itself to the terminal width.

```
user@host                 · ~/code/my-project         · main
Opus 5.5        ·high     · ctx  12%( 24.0k/200.0k)   · cache  91%( 21.8k rd) ⏱   42m
5h  34%→15:20             · 7d  75%→ Wed 20:53        · $  3.14
```

| Line | Shows |
|---|---|
| 1. Location | `user@host`, working directory (`~` for your home directory), git branch |
| 2. Session | Model and reasoning effort; context window used (% and tokens used / window size); prompt-cache hit rate, tokens read from cache, and time left before the cache expires |
| 3. Billing | Usage of the 5-hour and 7-day rate-limit windows, with reset times; estimated session cost in USD |

## Install

Requirements: `bash` 4.3+, `jq`, `git`, `awk`, `sed`, and GNU `date` (the script uses `date -d`, so it works on Linux; macOS needs coreutils).

This follows the manual setup in the Claude Code docs: [Manually configure a status line](https://code.claude.com/docs/en/statusline#manually-configure-a-status-line).

1. Save the script, for example as `~/.claude/statusline.sh`.
2. Add it to `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh",
       "refreshInterval": 10
     }
   }
   ```

`refreshInterval` re-runs the script every 10 seconds even when nothing else happens, so the cache time-to-live countdown stays current.

If the status line doesn't appear, see the docs' [Troubleshooting](https://code.claude.com/docs/en/statusline#troubleshooting) section.

## Layout

The script reads the terminal width from `$COLUMNS`, which Claude Code sets, and leaves a margin of 6 columns because Claude Code cuts off lines that fill the full width.

- **Wide enough:** all three lines form one grid with aligned columns, stretched to the full width. If a long path or branch would make the grid too wide, line 1 is laid out on its own (branch on the right), and only lines 2 and 3 stay aligned.
- **Too narrow:** each line wraps at the ` · ` separators, never inside a segment. A path or branch that is wider than the terminal on its own is shortened with `…`: paths keep their end, branches keep their start.
- **No `$COLUMNS`:** the lines are aligned but not stretched or wrapped.

Every field is always shown, with a fixed width, so nothing moves between refreshes. Missing data shows as `--`.

## Warnings

A value that crosses a threshold is shown on a yellow background (warning) or red background (critical). The thresholds are set at the top of the script:

| Value | Warning | Critical |
|---|---|---|
| Context used | ≥ 60% | ≥ 80% |
| 5h / 7d rate limit used | ≥ 70% | ≥ 90% |
| Prompt-cache hit rate | < 70% | < 40% |
| Cache time left | ≤ 10 min | ≤ 2 min, or expired |

## Notes on the data

- **Rate limits** are only reported for claude.ai Pro and Max subscriptions (or behind a Claude apps gateway with spend limits), and only after the first response of a session. Otherwise they show as `--`.
- **Cost** is Claude Code's own estimate for the current session, calculated from token counts at API list prices. On a subscription it is not what you pay. To see your usage-credit spend, run `/usage`, or open [Settings → Usage](https://claude.ai/settings/usage) on claude.ai for your credit balance.
- **Weekday names** for the 7-day reset follow your system language (`LC_TIME`).

## License

[MIT](LICENSE)
