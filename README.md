# Herdr Agents

A live agent-status widget for the [Omarchy](https://omarchy.org/) bar that
watches your [Herdr](https://herdr.dev) session.

One bar icon, one panel: every running Herdr agent with its current state,
what it is doing right now, and the Herdr workspace it is working in. Click an
agent and you land on it inside Herdr — no matter which desktop or window you
are looking at.

## What it shows

- **Bar icon** — a static sheep glyph tinted by fleet state:
  - **accent** while any agent is working,
  - **urgent** when any agent needs attention,
  - a **count badge** of busy agents (working / blocked / done).
- **Panel** — one row per agent:
  - status dot + label (`WORKING`, `BLOCKED`, `DONE`, `IDLE`, `UNKNOWN`),
  - agent name,
  - the agent's **current activity** (its live terminal title),
  - the **Herdr workspace** it is in, and the project folder,
  - a `FOCUSED` mark on the agent currently under the Herdr cursor.

## Click to jump

Click (or keyboard-Enter) an agent row and the plugin:

1. runs `herdr agent focus <pane>` to focus the agent inside the Herdr TUI,
2. locates the Herdr terminal window and raises it with a Hyprland dispatch.

The active Hyprland workspace follows the Herdr window, so the jump works from
anywhere on the desktop.

## Notifications

Desktop toasts when agents change state (both toggleable in plugin settings):

- **Needs attention** — an agent entered `blocked` and is waiting for input.
- **Finished** — a working agent transitioned to `done` (background work done).

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `refreshIntervalSec` | `2` | How often the Herdr session snapshot is polled. |
| `notifyOnBlocked` | `on` | Toast when an agent needs attention. |
| `notifyOnFinished` | `on` | Toast when an agent finishes background work. |

## Requirements

- [Herdr](https://herdr.dev) — the plugin polls `herdr api snapshot`.
- Omarchy with the Quickshell bar.

## Install

```sh
./install.sh
```

This symlinks the plugin into `~/.config/omarchy/plugins/`, makes the focus
helper executable, rescans the shell, and places the widget in the right bar
section. The shell hot-reloads; if the icon does not appear, run
`omarchy restart shell`.

## Uninstall

```sh
./uninstall.sh
```

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
# qs-herdr-agents
