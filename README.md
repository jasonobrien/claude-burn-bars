# Claude Statusline Burn Bars

Don't you hate it when your Claude usage allowance runs out mid-flow and you're stuck waiting for the window to reset? These scripts give you a heads-up before that happens — compact burn-rate bars you can drop into your [Claude Code status line](https://code.claude.com/docs/en/statusline).

```
5h ▓▓░░░ 🟢 │ 7d ▓▓░░░ 🟢
```

The **5h bar** shows your current context-window usage. The **7d bar** tracks your rolling 7-day API utilization, calculates your burn rate per work day, and warns you if you're on pace to hit the limit before the window resets.

Credit due: Inspired by [this post](https://codelynx.dev/posts/claude-code-usage-limits-statusline)

## Scripts

| Script | What it does |
|---|---|
| `claude-usage-7d.sh` | Fetches 7-day utilization from the Anthropic API, projects burn rate per work day, warns if you'll exceed the limit. Supports caching, configurable weekends, and a compact `--bar` mode for status lines. |
| `claude-usage-5h.sh` | Reads Claude Code's [status line JSON](https://code.claude.com/docs/en/statusline#full-json-schema) from stdin and renders context-window usage as a compact bar. |
| `statusline.sh` | Example status line script showing how to combine both bars into your own setup. |

## Install

These scripts are for Mac and use the `security` command-line tool to read the needed credentials.
If you are not using a Mac, you will need an alternative method to authorize for Anthropic API access.

```bash
git clone https://github.com/guyw/claude-statusline-burn-bars.git
cd claude-statusline-burn-bars
chmod +x *.sh
# Copy to a folder on your PATH
cp claude-usage-7d.sh claude-usage-5h.sh <somewhere-on-your-PATH>/
```

## Add to your status line

Call the scripts from your own Claude Code status line script. Here's a minimal example:

```bash
#!/bin/bash
input=$(cat)

# 5h context bar (reads status line JSON from stdin)
bar_5h=$(echo "$input" | claude-usage-5h.sh)

# 7d burn rate bar (cached, skips Sat+Sun)
bar_7d=$(claude-usage-7d.sh -b -w 6,7)

echo "$bar_5h │ $bar_7d"
```

Save it as `~/.claude/statusline.sh`, make it executable, and point your settings at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

See `statusline.sh` in this repo for a fuller example with model name and project folder.

## 7-day burn rate

```bash
# Full report
claude-usage-7d.sh

# 7-day utilization:   35.0%
# Window:              2026-02-22 → 2026-03-01
# Work days elapsed:   4
# Avg usage/work day:  8.7%
# Remaining work days: 3
# Remaining budget:    65.0%
# Projected remaining: 26.1%
```

### Options

```bash
claude-usage-7d.sh --bar           # Compact output: 7d ▓▓░░░ 🟢
claude-usage-7d.sh -w 6,7          # Skip Sat+Sun
claude-usage-7d.sh -w 5,6          # Skip Fri+Sat
claude-usage-7d.sh -t ""           # Disable cache (always fetch live)
claude-usage-7d.sh -t 300          # Cache for 5 minutes
claude-usage-7d.sh --help          # Full help
```

### Bar icons

- 🟢 Projected usage fits within the remaining budget
- 🔴 On track to exceed the limit before the window resets

### Weekend days

By default every day counts. Use `-w` to skip weekend days (1=Mon ... 7=Sun):

| Flag | Weekend |
|---|---|
| `-w 6,7` | Saturday + Sunday (most common) |
| `-w 5,6` | Friday + Saturday |
| *(omitted)* | None — all days count |

### Caching

The API response is cached at `~/.cache/claude-usage/7d-response.json` with a default TTL of 1 hour. This avoids hitting the API on every status line refresh. Both the cache directory (`-c`) and TTL (`-t`) are configurable. Pass `-t ""` to disable caching entirely.

## 5-hour context window

Reads `context_window.used_percentage` from stdin (the JSON that Claude Code pipes to status line scripts):

```bash
echo '{"context_window":{"used_percentage":42}}' | claude-usage-5h.sh
# 5h ▓▓░░░ 🟢
```

### Icons by threshold

- 🟢 Under 50%
- 🟡 50% – 89%
- 🔴 90%+

## Progress bar

Both scripts use a 5-slot bar where each slot represents 20%:

```
 10%  ▓░░░░
 30%  ▓▓░░░
 50%  ▓▓▓░░
 70%  ▓▓▓▓░
 90%  ▓▓▓▓▓
```

## Requirements

- macOS (uses BSD `date` and Keychain)
- [jq](https://jqlang.github.io/jq/)
- curl, bc (pre-installed on macOS)
- An active [Claude Code](https://claude.ai/code) subscription with OAuth credentials in Keychain

## License

[MIT](LICENSE)
