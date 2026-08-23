"""Unit tests for bin/omarchy-herdr-focus."""

import importlib.machinery
import importlib.util
import os
import io
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).parents[1] / "bin" / "omarchy-herdr-focus"


def load_module():
    loader = importlib.machinery.SourceFileLoader("omarchy_herdr_focus", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


MOD = load_module()


class FindHerdrClientTest(unittest.TestCase):
    def visible(self, address, pid):
        return {"address": address, "pid": pid,
                "mapped": True, "hidden": False,
                "workspace": {"id": 3, "name": "3"}}

    def special(self, address, pid):
        return {"address": address, "pid": pid,
                "mapped": True, "hidden": False,
                "workspace": {"id": -99, "name": "special:scratch"}}

    def hidden(self, address, pid):
        return {"address": address, "pid": pid,
                "mapped": True, "hidden": True,
                "workspace": {"id": 5, "name": "5"}}

    def unmapped(self, address, pid):
        return {"address": address, "pid": pid,
                "mapped": False, "hidden": True,
                "workspace": {"id": 5, "name": "5"}}

    def test_prefers_visible_normal_workspace_window(self):
        checker = lambda pid: True  # noqa: E731
        clients = [self.special("0x1", 10), self.hidden("0x2", 11),
                   self.visible("0x3", 12)]
        self.assertEqual(MOD.find_herdr_client(clients, checker)["address"], "0x3")

    def test_falls_back_to_special_then_hidden_then_unmapped(self):
        checker = lambda pid: True  # noqa: E731
        self.assertEqual(
            MOD.find_herdr_client([self.hidden("0x1", 10), self.special("0x2", 11)],
                                  checker)["address"], "0x2")
        self.assertEqual(
            MOD.find_herdr_client([self.unmapped("0x1", 10), self.hidden("0x2", 11)],
                                  checker)["address"], "0x2")

    def test_keeps_compositor_order_on_ties(self):
        checker = lambda pid: True  # noqa: E731
        clients = [self.visible("0x1", 10), self.visible("0x2", 11)]
        self.assertEqual(MOD.find_herdr_client(clients, checker)["address"], "0x1")

    def test_returns_none_when_no_match(self):
        checker = lambda pid: False  # noqa: E731
        self.assertIsNone(MOD.find_herdr_client([self.visible("0x1", 1)], checker))
        self.assertIsNone(MOD.find_herdr_client([], checker))

    def test_skips_clients_without_pid_or_address(self):
        checker = lambda pid: pid == 2  # noqa: E731
        clients = [{"address": "0x1"}, {"pid": 2}, self.visible("0x2", 2)]
        self.assertEqual(MOD.find_herdr_client(clients, checker)["address"], "0x2")


class FindClientByClassTest(unittest.TestCase):
    def client(self, address, cls, initial=None, **extra):
        data = {"address": address, "class": cls, "mapped": True,
                "hidden": False, "workspace": {"id": 1, "name": "1"}}
        if initial is not None:
            data["initialClass"] = initial
        data.update(extra)
        return data

    def test_matches_class_case_insensitively(self):
        clients = [self.client("0x1", "kitty"), self.client("0x2", "Ghostty")]
        found = MOD.find_client_by_class(clients, "ghostty")
        self.assertEqual(found["address"], "0x2")

    def test_matches_initial_class(self):
        clients = [self.client("0x1", "foot", initial="myherdr")]
        found = MOD.find_client_by_class(clients, "MyHerdr")
        self.assertEqual(found["address"], "0x1")

    def test_prefers_visible_over_hidden_match(self):
        hidden = self.client("0x1", "kitty", hidden=True)
        visible = self.client("0x2", "kitty")
        found = MOD.find_client_by_class([hidden, visible], "kitty")
        self.assertEqual(found["address"], "0x2")

    def test_returns_none_for_no_or_blank_class(self):
        clients = [self.client("0x1", "kitty")]
        self.assertIsNone(MOD.find_client_by_class(clients, ""))
        self.assertIsNone(MOD.find_client_by_class(clients, "  "))
        self.assertIsNone(MOD.find_client_by_class([], "kitty"))
        self.assertIsNone(MOD.find_client_by_class(clients, "wezterm"))


class EnsureSpecialVisibleTest(unittest.TestCase):
    CLIENT_NORMAL = {"workspace": {"id": 4, "name": "4"}}
    CLIENT_SPECIAL = {"workspace": {"id": -99, "name": "special:scratch"}}

    @staticmethod
    def monitors(showing=None):
        return [{"specialWorkspace": {"id": -99 if showing else 0,
                                      "name": showing or ""}}]

    def test_noop_for_normal_workspace(self):
        with mock.patch.object(MOD, "hyprctl_monitors") as monitors, \
             mock.patch.object(MOD, "run") as run:
            self.assertTrue(MOD.ensure_special_visible(self.CLIENT_NORMAL))
            monitors.assert_not_called()
            run.assert_not_called()

    def test_opens_hidden_special_workspace(self):
        with mock.patch.object(MOD, "hyprctl_monitors",
                               return_value=self.monitors()), \
             mock.patch.object(MOD, "run",
                               return_value=SimpleNamespace(returncode=0)) as run:
            self.assertTrue(MOD.ensure_special_visible(self.CLIENT_SPECIAL))
            (cmd,), _ = run.call_args
            self.assertIn('toggle_special("scratch")', cmd[2])

    def test_noop_when_special_already_shown(self):
        with mock.patch.object(MOD, "hyprctl_monitors",
                               return_value=self.monitors("special:scratch")), \
             mock.patch.object(MOD, "run") as run:
            self.assertTrue(MOD.ensure_special_visible(self.CLIENT_SPECIAL))
            run.assert_not_called()

    def test_false_without_monitor_data(self):
        with mock.patch.object(MOD, "hyprctl_monitors", return_value=None), \
             mock.patch.object(MOD, "run") as run:
            self.assertFalse(MOD.ensure_special_visible(self.CLIENT_SPECIAL))
            run.assert_not_called()


class ProcessHasHerdrTest(unittest.TestCase):
    def test_false_for_missing_pid(self):
        self.assertFalse(MOD.process_has_herdr(2**31 - 1))

    def test_detects_nested_herdr_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "herdr"
            script.write_text("#!/bin/sh\nsleep 30\n")
            script.chmod(0o755)
            parent = subprocess.Popen(["sh", "-c", f'"{script}"'], start_new_session=True)
            try:
                # Fork/exec of the child races Popen returning; poll briefly.
                for _ in range(100):
                    if MOD.process_has_herdr(parent.pid):
                        return
                    time.sleep(0.02)
                self.fail("never detected a herdr descendant")
            finally:
                os.killpg(os.getpgid(parent.pid), 9)
                parent.wait()


class MainTest(unittest.TestCase):
    def test_usage_error_without_target(self):
        with mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main([]), 2)
            self.assertEqual(MOD.main([""]), 2)

    def test_focus_failure_exits_1_when_no_hyprland(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=None), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 1)

    def test_focus_failure_ok_when_hyprland_raises(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client",
                               return_value={"address": "0x42"}), \
             mock.patch.object(MOD, "ensure_special_visible", return_value=True), \
             mock.patch.object(MOD, "raise_window", return_value=(True, "")), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_without_hyprland(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=None):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_without_herdr_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client", return_value=None), \
             mock.patch.object(MOD, "find_client_by_class",
                               return_value=None) as by_class, \
             mock.patch.object(MOD, "raise_window") as raise_:
            self.assertEqual(MOD.main(["w1:p1"]), 0)
            by_class.assert_called_once_with([], "")
            raise_.assert_not_called()

    def test_class_fallback_raises_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client", return_value=None), \
             mock.patch.object(MOD, "find_client_by_class",
                               return_value={"address": "0x7"}) as by_class, \
             mock.patch.object(MOD, "ensure_special_visible", return_value=True), \
             mock.patch.object(MOD, "raise_window", return_value=(True, "")) as raise_:
            self.assertEqual(MOD.main(["w1:p1", "ghostty"]), 0)
            by_class.assert_called_once_with([], "ghostty")
            raise_.assert_called_once_with("0x7")

    def test_class_fallback_miss_still_exits_0(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client", return_value=None), \
             mock.patch.object(MOD, "find_client_by_class", return_value=None), \
             mock.patch.object(MOD, "raise_window") as raise_:
            self.assertEqual(MOD.main(["w1:p1", "ghostty"]), 0)
            raise_.assert_not_called()

    def test_opens_special_workspace_before_raising(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client",
                               return_value={"address": "0x42"}), \
             mock.patch.object(MOD, "ensure_special_visible",
                               return_value=False) as ensure, \
             mock.patch.object(MOD, "raise_window", return_value=(True, "")):
            self.assertEqual(MOD.main(["w1:p1"]), 0)
            ensure.assert_called_once()

    def test_ok_with_raised_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client",
                               return_value={"address": "0x42"}), \
             mock.patch.object(MOD, "ensure_special_visible", return_value=True), \
             mock.patch.object(MOD, "raise_window", return_value=(True, "")):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_raise_failure_exits_0_when_focus_ok(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client",
                               return_value={"address": "0x42"}), \
             mock.patch.object(MOD, "ensure_special_visible", return_value=True), \
             mock.patch.object(MOD, "raise_window", return_value=(False, "nope")), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_raise_failure_exits_1_when_focus_also_failed(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_client",
                               return_value={"address": "0x42"}), \
             mock.patch.object(MOD, "ensure_special_visible", return_value=True), \
             mock.patch.object(MOD, "raise_window", return_value=(False, "nope")), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 1)

    def test_usage_error_with_too_many_args(self):
        with mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["a", "b", "c"]), 2)


class EnsureSpecialVisibleEmptyMonitorsTest(unittest.TestCase):
    CLIENT_SPECIAL = {"workspace": {"id": -99, "name": "special:scratch"}}

    def test_empty_monitor_list_opens_special(self):
        """No monitors showing the special workspace → toggle it open."""
        with mock.patch.object(MOD, "hyprctl_monitors", return_value=[]), \
             mock.patch.object(MOD, "run",
                               return_value=SimpleNamespace(returncode=0)) as run:
            self.assertTrue(MOD.ensure_special_visible(self.CLIENT_SPECIAL))
            (cmd,), _ = run.call_args
            self.assertIn('toggle_special("scratch")', cmd[2])


class ClientRankSpecialNameTest(unittest.TestCase):
    """Regression: client_rank must use name, not id, for special detection."""

    def test_special_name_with_positive_id(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": 5, "name": "special:foo"}}
        self.assertEqual(MOD.client_rank(client), 1)

    def test_normal_name_with_negative_id(self):
        client = {"mapped": True, "hidden": False,
                  "workspace": {"id": -1, "name": "3"}}
        self.assertEqual(MOD.client_rank(client), 0)


class FindHerdrClientWithClassTest(unittest.TestCase):
    """When proc-tree and class both match, proc-tree should win."""

    def test_proc_tree_wins_over_class(self):
        checker = lambda pid: True
        clients = [
            {"address": "0x1", "pid": 10, "mapped": True, "hidden": False,
             "workspace": {"id": 3, "name": "3"}, "class": "ghostty"},
            {"address": "0x2", "pid": 11, "mapped": True, "hidden": False,
             "workspace": {"id": 3, "name": "3"}, "class": "alacritty"},
        ]
        # Both match proc tree; first wins (compositor order tiebreak).
        self.assertEqual(MOD.find_herdr_client(clients, checker)["address"], "0x1")

    def test_class_used_when_proc_tree_finds_nothing(self):
        checker = lambda pid: False
        clients = [
            {"address": "0x1", "pid": 10, "mapped": True, "hidden": False,
             "workspace": {"id": 3, "name": "3"}, "class": "ghostty"},
        ]
        result = MOD.find_herdr_client(clients, checker)
        self.assertIsNone(result)
        # Fallback via class.
        result = MOD.find_client_by_class(clients, "ghostty")
        self.assertIsNotNone(result)
        self.assertEqual(result["address"], "0x1")


if __name__ == "__main__":
    unittest.main()
