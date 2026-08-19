# Herdr Agents

![herdr-agents](./assets/herdragents.png)

A live agent-status widget for the [Omarchy](https://omarchy.org/) bar that
watches your [Herdr](https://herdr.dev) session.

One bar icon, one panel: every running Herdr agent with its current state,
what it is doing right now, and the Herdr workspace it is working in. Click an
agent and you land on it inside Herdr — no matter which desktop or window you
are looking at.

## What it does

The plugin adds two things to your Omarchy bar:

1. **Bar icon** — a static sheep glyph tinted by fleet state:
   - **accent** while any agent is working,
   - **urgent** when any agent needs attention,
   - a **count badge** of busy agents (working / blocked / done).

2. **Panel** — click the icon to open a list, one row per agent:
   - status dot + label (`WORKING`, `BLOCKED`, `DONE`, `IDLE`, `UNKNOWN`),
   - agent name,
   - the agent's **current activity** (its live terminal title),
   - the **Herdr workspace** it is in, and the project folder,
   - a `FOCUSED` mark on the agent currently under the Herdr cursor.

### Notifications

Desktop toasts when agents change state (both toggleable in plugin settings):

- **Needs attention** — an agent entered `blocked` and is waiting for input.
- **Finished** — a working agent transitioned to `done` (background work done).

### Click to jump

Click (or keyboard-Enter) an agent row and the plugin:

1. runs `herdr agent focus <pane>` to focus the agent inside the Herdr TUI,
2. locates the Herdr terminal window and raises it with a Hyprland dispatch.

The active Hyprland workspace follows the Herdr window, so the jump works from
anywhere on the desktop.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `refreshIntervalSec` | `2` | How often the Herdr session snapshot is polled. |
| `notifyOnBlocked` | `on` | Toast when an agent needs attention. |
| `notifyOnFinished` | `on` | Toast when an agent finishes background work. |

## Requirements

- [Herdr](https://herdr.dev) — the plugin polls `herdr api snapshot`.
- Omarchy with the Quickshell bar.

## Dependencies

- `herdr` — shelled out to for `herdr api snapshot` (polling) and
  `herdr agent focus <pane>` (click-to-jump). No network calls; both talk to
  the local Herdr server only.
- `hyprctl` — shelled out to by `bin/omarchy-herdr-focus` to locate and raise
  the Herdr window via a Hyprland dispatch.
- `python3` — runs `bin/omarchy-herdr-focus`, a stdlib-only script (no pip
  packages required).
- No non-stdlib QML imports beyond Quickshell and the Omarchy shell's own
  `qs.Commons` / `qs.Ui` modules.

## Install

The standard way to install an Omarchy plugin, straight from the repo:

```sh
omarchy plugin add https://github.com/mrpbennett/qs-herdr-agents.git --enable
```

This clones the plugin into `~/.config/omarchy/plugins/`, validates the
manifest, rescans the shell, and enables the widget in the right bar section.
The shell hot-reloads; if the icon does not appear, run
`omarchy restart shell`.

## Update

```sh
omarchy plugin update mrpbennett.herdr-agents
```

## Uninstall

```sh
omarchy plugin remove mrpbennett.herdr-agents
```

This disables the plugin and removes it from `~/.config/omarchy/plugins/`,
leaving the rest of your `shell.json` untouched.

### Complete removal

If you want to fully remove every trace of the plugin from your system:

1. **Remove the plugin** (disables it and removes the installed copy):

   ```sh
   omarchy plugin remove mrpbennett.herdr-agents
   ```

2. **Remove the cloned repository** (the source code on disk):

   ```sh
   rm -rf /home/pb/Projects/qs-herdr-agents
   ```

   Or wherever you cloned it.

3. **Restart the shell** (optional, picks up the change immediately):

   ```sh
   omarchy restart shell
   ```

After these steps the plugin is gone: no entry in `~/.config/omarchy/plugins/`,
nothing enabled in `shell.json`, and no source files on disk.

## Development

- `Service.qml` — snapshot polling, the live agent model, state-change toasts.
- `Panel.qml` — bar icon and the agent list panel.
- `bin/omarchy-herdr-focus` — focus agent in Herdr + raise the Herdr window.
- `install.sh` / `uninstall.sh` — idempotent user-level install/removal.

Run the tests and static checks:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n install.sh uninstall.sh
omarchy plugin validate .
```

## Data source

One call per poll — `herdr api snapshot` — returns every agent (state,
current activity title, cwd, pane id) and every workspace (label) from the
running Herdr server. See `docs/design.md` for the details and the verified
Hyprland 0.56 focus mechanics.

## License

MIT — see [LICENSE](./LICENSE).
