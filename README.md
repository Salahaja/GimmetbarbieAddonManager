# Gimmetbarbie Addon Manager (v1.0.3)

An in-game addon manager for WoW 1.12 (vanilla) clients that don't ship one of their own — enable/disable addons, quick-launch their slash commands, catch Lua errors from any addon, and tidy up your minimap.

## Features

### Enable / Disable
- Lists every installed addon in two tabs: **Enabled** and **Disabled**.
- Click an addon's state button to toggle it. Like the character-select AddOns screen, the client only reads enable/disable state at login — changes need a `/reloadui`, which the window reminds you of with a banner and a per-row `*reload needed*` marker.
- Addons that fail to load for another reason (missing dependency, wrong interface version, etc.) show the reason inline.

### Quick-launch commands (auto-discovered)
- Addons register slash commands as plain globals (`SLASH_X1 = "/x"`, `SlashCmdList["X"] = ...`), which are visible to every other addon via `_G`.
- Gimmetbarbie watches each addon's `ADDON_LOADED` event and diffs `_G` for new `SLASH_*` entries that appear during that addon's load, attributing them automatically. A newly installed addon gets a quick-launch button with **zero manual setup**.
- A small hand-picked override table takes priority for a few addons where the auto-picked command isn't the most useful one to surface (e.g. showing both a status command and a help command for a single addon).

### Error log
- Hooks `seterrorhandler()` — the same mechanism tools like BugSack use — to catch every Lua error thrown by *any* addon, not just this one. It chains through whatever handler was already installed, so it doesn't break normal error display/behavior.
- Errors are timestamped and persisted across sessions.
- Shown in a scrollable, selectable text box — click in, `Ctrl+A`, `Ctrl+C`. There's no OS clipboard API exposed to addons in this client, so select-and-copy is the standard vanilla trick for getting text out.

### Minimap button drawer
- A single minimap icon collects other addons' stray minimap buttons into a flyout drawer, instead of leaving a dozen icons cluttering the ring.
  - **Left-click**: open the addon list.
  - **Right-click**: open/close the drawer.
- The drawer's grid shape scales with how many icons there actually are — a tight single row for 3 icons, a clean 8×2 block for 16, instead of a fixed-width grid that looks sparse or lopsided depending on count.
- The **Settings** tab lists every icon currently in the drawer, with a **Release** button to put one back on the minimap if it doesn't belong there, and a **Recollect** button to undo that.

## Slash commands

```
/am              toggle the addon list window
/am reload       reloads the UI (applies pending enable/disable changes)
/am rescan       force a minimap-button collection pass
/am probe        dumps GetAddOnInfo(1)'s raw return values, for diagnosing
                 field-order differences across client builds
/am commands     lists how many slash commands were auto-discovered per addon
```

## Installation

The client identifies an addon by its folder name, which must contain a matching `.toc` file — this repo's name, folder, `.toc`, and `.lua` are all `GimmetbarbieAddonManager`, so no renaming is needed at any step.

**Recommended:** download the zip from [Releases](../../releases) and extract it straight into `Interface\AddOns\`.

**If cloning instead:**
1. Clone this repo into `Interface\AddOns\` (or clone anywhere and copy the folder in).
2. You should end up with `Interface\AddOns\GimmetbarbieAddonManager\GimmetbarbieAddonManager.toc`.
3. `/reloadui` or restart the client.

## Known limitations

- **`GetAddOnInfo`'s exact return signature isn't identical across every client build.** This addon detects the `loadable` boolean and `reason` string by *type* rather than trusting a fixed position, which should hold regardless of slot order — but if enable/disable state ever looks wrong on your client, run `/am probe` and compare.
- **Enabling/disabling an addon can't take effect live.** The client only reads that state at login, same as the character-select screen — there's no way around this from an addon.
- **The minimap-button detection is a heuristic** (any named `Button` child of `Minimap`, roughly icon-sized, not on a hardcoded exclude list of Blizzard's own default widgets). It's designed to fail safe, but if it ever grabs something it shouldn't, use Release in the Settings tab.

## Author

Built for [Salahaja](https://github.com/Salahaja).
