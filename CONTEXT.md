# Herdr Agent Status

This context presents the live state of agents in a Herdr session and lets a
user return to the terminal window hosting an agent.

## Language

**Herdr Snapshot**:
A complete point-in-time view of a Herdr session's agents, workspaces, and
tabs.
_Avoid_: poll result, raw data

**Agent Timeline**:
The retained sequence of an agent pane's status and its entered time across
Herdr Snapshots.
_Avoid_: state cache, history

**Notification Intent**:
A user-visible Herdr event derived from an Agent Timeline transition, such as
an agent needing attention or finishing.
_Avoid_: toast decision, alert event

**Herdr Window**:
The local Hyprland client that hosts a Herdr session, identified by its process
tree or configured terminal class.
_Avoid_: terminal window, client match
