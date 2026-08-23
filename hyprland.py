"""Hyprland Window Adapter — finds and manipulates Herdr windows via hyprctl.

This module owns all Hyprland-specific interaction: client discovery, process
tree inspection, ranking, special workspace management, and window raising.
The orchestrator (bin/omarchy-herdr-focus) owns Herdr TUI focus and overall
flow control.
"""

from __future__ import annotations

import json
import os
import subprocess
from typing import Any, Optional

_HYPRCTL_TIMEOUT: int = 3  # seconds — hyprctl queries are fast


def _run(cmd: list[str], *, timeout: int = 10) -> subprocess.CompletedProcess[str]:
    """Run a command and return the result without raising on non-zero exit."""
    return subprocess.run(cmd, capture_output=True, text=True, check=False,
                          timeout=timeout)


class HyprlandWindow:
    """Adapter for Hyprland window discovery and manipulation.

    Args:
        herdr_checker: A callable ``(pid: int) -> bool`` that returns True
            when a process tree rooted at *pid* contains a ``herdr`` process.
            Injected for testability.
        hyprctl_bin: Path to the ``hyprctl`` binary.
    """

    def __init__(
        self,
        herdr_checker: Any,
        hyprctl_bin: str = os.environ.get("HYPRCTL_BIN", "hyprctl"),
    ) -> None:
        self._is_herdr = herdr_checker
        self._hyprctl = hyprctl_bin

    # ------------------------------------------------------------------
    # Public interface
    # ------------------------------------------------------------------

    def findClient(
        self, clients: list[dict[str, Any]] | None
    ) -> Optional[dict[str, Any]]:
        """Return the best client whose process tree runs herdr, or None."""
        matches: list[dict[str, Any]] = []
        for client in clients or []:
            pid = client.get("pid")
            address = client.get("address")
            if pid and address and self._is_herdr(pid):
                matches.append(client)
        if not matches:
            return None
        return min(matches, key=self._rank)

    def findByClass(
        self,
        clients: list[dict[str, Any]] | None,
        window_class: str,
    ) -> Optional[dict[str, Any]]:
        """Return the best-ranked client matching *window_class*, or None.

        Fallback for setups where the process tree cannot be inspected (Herdr
        over SSH in a local terminal). Matches class and initialClass
        case-insensitively.
        """
        wanted: str = str(window_class or "").strip().lower()
        if not wanted:
            return None
        matches = [
            client for client in clients or []
            if client.get("address") and any(
                str(client.get(key) or "").strip().lower() == wanted
                for key in ("class", "initialClass")
            )
        ]
        if not matches:
            return None
        return min(matches, key=self._rank)

    def ensureVisible(self, client: dict[str, Any]) -> bool:
        """Open the special workspace hosting *client* unless a monitor shows it.

        Returns True when nothing needs doing or the toggle succeeded, and False
        when the state could not be verified (no monitor data) or the dispatch
        failed. Callers may continue with the plain focus either way.
        """
        workspace: dict[str, Any] = client.get("workspace") or {}
        name: str = str(workspace.get("name") or "")
        if not name.startswith("special:"):
            return True
        monitors = self._hyprctl_monitors()
        if monitors is None:
            return False
        for monitor in monitors or []:
            if ((monitor.get("specialWorkspace") or {}).get("name") or "") == name:
                return True
        special: str = name[len("special:"):]
        if not special:
            return True
        out = _run(
            [self._hyprctl, "dispatch",
             f'hl.dsp.workspace.toggle_special("{special}")'],
            timeout=_HYPRCTL_TIMEOUT,
        )
        return out.returncode == 0

    def raiseWindow(self, address: str) -> tuple[bool, str]:
        """Focus a window by address. If the window lives on another workspace
        the active workspace switches to it (Hyprland 0.56+ dispatch API).

        Returns (ok, detail) where *detail* is stderr on failure.
        """
        out = _run(
            [self._hyprctl, "dispatch",
             f'hl.dsp.focus({{ window = "address:{address}" }})'],
            timeout=_HYPRCTL_TIMEOUT,
        )
        if out.returncode != 0:
            detail = "\n".join(
                part.strip() for part in (out.stdout, out.stderr) if part.strip()
            )
            return False, detail or f"hyprctl dispatch failed for {address}"
        return True, ""

    def hyprctlClients(self) -> Optional[list[dict[str, Any]]]:
        """Query the compositor for all clients, or None on failure."""
        out = _run([self._hyprctl, "-j", "clients"], timeout=_HYPRCTL_TIMEOUT)
        if out.returncode != 0:
            return None
        try:
            return json.loads(out.stdout)
        except json.JSONDecodeError:
            return None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _rank(client: dict[str, Any]) -> int:
        """Lower ranks are better jump targets.

        0: mapped, not hidden, on a normal workspace
        1: mapped, not hidden, inside a special workspace
        2: mapped but hidden
        3: unmapped
        """
        mapped: bool = bool(client.get("mapped", True))
        if not mapped:
            return 3
        if client.get("hidden", False):
            return 2
        workspace: dict[str, Any] = client.get("workspace") or {}
        name: str = str(workspace.get("name") or "")
        if not name.startswith("special:"):
            return 0
        return 1

    def _hyprctl_monitors(self) -> Optional[list[dict[str, Any]]]:
        """Query the compositor for all monitors, or None on failure."""
        out = _run([self._hyprctl, "-j", "monitors"], timeout=_HYPRCTL_TIMEOUT)
        if out.returncode != 0:
            return None
        try:
            return json.loads(out.stdout)
        except json.JSONDecodeError:
            return None
