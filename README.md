# ClaudeUsageBar

macOS menu bar app showing Claude Code usage limits — the same numbers as `/usage`, without spinning up a session.

The menu bar shows `CC 42%` (the max of your session and weekly utilization, ⚠️ at ≥80%). Click for the full breakdown with reset times.

## How it works

- Reads Claude Code's OAuth token from the macOS Keychain (`Claude Code-credentials`). First run triggers a Keychain prompt — click **Always Allow**.
- Calls `GET https://api.anthropic.com/api/oauth/usage` (the endpoint behind `/usage`) every 5 minutes.
- Renders whichever limit buckets your plan has (session 5h, weekly all-models, weekly Opus/Sonnet).

If the token expires (401), the bar shows `CC –` with "Token stale — open Claude Code to refresh" in the dropdown. Claude Code rotates the token whenever it runs, so this resolves itself the next time you use it.

## Install

```sh
make install   # builds, bundles into /Applications/ClaudeUsageBar.app, launches
```

Toggle **Launch at login** from the dropdown menu.

## Uninstall

```sh
make uninstall
```
