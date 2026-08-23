"""Unit tests for hyprland.py — the Hyprland Window Adapter."""

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.dont_write_bytecode = True

REPO = Path(__file__).parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from hyprland import HyprlandWindow  # noqa: E402


def _hl(checker=None):
    """Create a HyprlandWindow with a fake hyprctl (never calls real hyprctl)."""
    if checker is None:
        checker = lambda pid: False  # noqa: E731
    return HyprlandWindow(herdr_checker=checker, hyprctl_bin="/bin/true")


# ---------------------------------------------------------------------------
# Client ranking
# ---------------------------------------------------------------------------

class RankTest(unittest.TestCase):
    def test_visible_normal_workspace(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": 3, "name": "3"}}
        self.assertEqual(HyprlandWindow._rank(client), 0)

    def test_special_workspace(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": -99, "name": "special:scratch"}}
        self.assertEqual(HyprlandWindow._rank(client), 1)

    def test_hidden(self):
        client = {"mapped": True, "hidden": True,
                  "workspace": {"id": 3, "name": "3"}}
        self.assertEqual(HyprlandWindow._rank(client), 2)

    def test_unmapped(self):
        client = {"mapped": False, "hidden": True,
                  "workspace": {"id": 5, "name": "5"}}
        self.assertEqual(HyprlandWindow._rank(client), 3)

    def test_special_name_with_positive_id(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": 5, "name": "special:foo"}}
        self.assertEqual(HyprlandWindow._rank(client), 1)

    def test_normal_name_with_negative_id(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": -1, "name": "3"}}
        self.assertEqual(HyprlandWindow._rank(client), 0)


# ---------------------------------------------------------------------------
# findClient
# ---------------------------------------------------------------------------

def _visible(address, pid):
    return {"address": address, "pid": pid,
            "mapped": True, "hidden": False,
            "workspace": {"id": 3, "name": "3"}}


def _special(address, pid):
    return {"address": address, "pid": pid,
            "mapped": True, "hidden": False,
            "workspace": {"id": -99, "name": "special:scratch"}}


def _hidden(address, pid):
    return {"address": address, "pid": pid,
            "mapped": True, "hidden": True,
            "workspace": {"id": 5, "name": "5"}}


def _unmapped(address, pid):
    return {"address": address, "pid": pid,
            "mapped": False, "hidden": True,
            "workspace": {"id": 5, "name": "5"}}


class FindClientTest(unittest.TestCase):
    def test_prefers_visible_normal_workspace_window(self):
        checker = lambda pid: True  # noqa: E731
        hl = _hl(checker)
        clients = [_special("0x1", 10), _hidden("0x2", 11), _visible("0x3", 12)]
        self.assertEqual(hl.findClient(clients)["address"], "0x3")

    def test_falls_back_to_special_then_hidden_then_unmapped(self):
        checker = lambda pid: True  # noqa: E731
        hl = _hl(checker)
        self.assertEqual(
            hl.findClient([_hidden("0x1", 10), _special("0x2", 11)])["address"],
            "0x2")
        self.assertEqual(
            hl.findClient([_unmapped("0x1", 10), _hidden("0x2", 11)])["address"],
            "0x2")

    def test_keeps_compositor_order_on_ties(self):
        checker = lambda pid: True  # noqa: E731
        hl = _hl(checker)
        clients = [_visible("0x1", 10), _visible("0x2", 11)]
        self.assertEqual(hl.findClient(clients)["address"], "0x1")

    def test_returns_none_when_no_match(self):
        checker = lambda pid: False  # noqa: E731
        hl = _hl(checker)
        self.assertIsNone(hl.findClient([_visible("0x1", 1)]))
        self.assertIsNone(hl.findClient([]))

    def test_skips_clients_without_pid_or_address(self):
        checker = lambda pid: pid == 2  # noqa: E731
        hl = _hl(checker)
        clients = [{"address": "0x1"}, {"pid": 2}, _visible("0x2", 2)]
        self.assertEqual(hl.findClient(clients)["address"], "0x2")

    def test_proc_tree_wins_over_class(self):
        """When proc-tree and class both match, proc-tree should win."""
        checker = lambda pid: True  # noqa: E731
        hl = _hl(checker)
        clients = [
            {"address": "0x1", "pid": 10, "mapped": True, "hidden": False,
             "workspace": {"id": 3, "name": "3"}, "class": "ghostty"},
            {"address": "0x2", "pid": 11, "mapped": True, "hidden": False,
             "workspace": {"id": 3, "name": "3"}, "class": "alacritty"},
        ]
        self.assertEqual(hl.findClient(clients)["address"], "0x1")


# ---------------------------------------------------------------------------
# findByClass
# ---------------------------------------------------------------------------

def _client(address, cls, initial=None, **extra):
    data = {"address": address, "class": cls, "mapped": True,
            "hidden": False, "workspace": {"id": 1, "name": "1"}}
    if initial is not None:
        data["initialClass"] = initial
    data.update(extra)
    return data


class FindByClassTest(unittest.TestCase):
    def test_matches_class_case_insensitively(self):
        hl = _hl()
        clients = [_client("0x1", "kitty"), _client("0x2", "Ghostty")]
        found = hl.findByClass(clients, "ghostty")
        self.assertEqual(found["address"], "0x2")

    def test_matches_initial_class(self):
        hl = _hl()
        clients = [_client("0x1", "foot", initial="myherdr")]
        found = hl.findByClass(clients, "MyHerdr")
        self.assertEqual(found["address"], "0x1")

    def test_prefers_visible_over_hidden_match(self):
        hl = _hl()
        hidden = _client("0x1", "kitty", hidden=True)
        visible = _client("0x2", "kitty")
        found = hl.findByClass([hidden, visible], "kitty")
        self.assertEqual(found["address"], "0x2")

    def test_returns_none_for_no_or_blank_class(self):
        hl = _hl()
        clients = [_client("0x1", "kitty")]
        self.assertIsNone(hl.findByClass(clients, ""))
        self.assertIsNone(hl.findByClass(clients, "  "))
        self.assertIsNone(hl.findByClass([], "kitty"))
        self.assertIsNone(hl.findByClass(clients, "wezterm"))


# ---------------------------------------------------------------------------
# ensureVisible
# ---------------------------------------------------------------------------

class EnsureVisibleTest(unittest.TestCase):
    CLIENT_NORMAL = {"workspace": {"id": 4, "name": "4"}}
    CLIENT_SPECIAL = {"workspace": {"id": -99, "name": "special:scratch"}}

    @staticmethod
    def monitors(showing=None):
        return [{"specialWorkspace": {"id": -99 if showing else 0,
                                       "name": showing or ""}}]

    def test_noop_for_normal_workspace(self):
        with mock.patch.object(HyprlandWindow, "_hyprctl_monitors") as monitors, \
             mock.patch("hyprland._run") as run:
            hl = _hl()
            self.assertTrue(hl.ensureVisible(self.CLIENT_NORMAL))
            monitors.assert_not_called()
            run.assert_not_called()

    def test_opens_hidden_special_workspace(self):
        with mock.patch.object(HyprlandWindow, "_hyprctl_monitors",
                               return_value=self.monitors()), \
             mock.patch("hyprland._run",
                        return_value=SimpleNamespace(returncode=0)) as run:
            hl = _hl()
            self.assertTrue(hl.ensureVisible(self.CLIENT_SPECIAL))
            (cmd,), _ = run.call_args
            self.assertIn('toggle_special("scratch")', cmd[2])

    def test_noop_when_special_already_shown(self):
        with mock.patch.object(HyprlandWindow, "_hyprctl_monitors",
                               return_value=self.monitors("special:scratch")), \
             mock.patch("hyprland._run") as run:
            hl = _hl()
            self.assertTrue(hl.ensureVisible(self.CLIENT_SPECIAL))
            run.assert_not_called()

    def test_false_without_monitor_data(self):
        with mock.patch.object(HyprlandWindow, "_hyprctl_monitors",
                               return_value=None), \
             mock.patch("hyprland._run") as run:
            hl = _hl()
            self.assertFalse(hl.ensureVisible(self.CLIENT_SPECIAL))
            run.assert_not_called()

    def test_empty_monitor_list_opens_special(self):
        with mock.patch.object(HyprlandWindow, "_hyprctl_monitors",
                               return_value=[]), \
             mock.patch("hyprland._run",
                        return_value=SimpleNamespace(returncode=0)) as run:
            hl = _hl()
            self.assertTrue(hl.ensureVisible(self.CLIENT_SPECIAL))
            (cmd,), _ = run.call_args
            self.assertIn('toggle_special("scratch")', cmd[2])


if __name__ == "__main__":
    unittest.main()
