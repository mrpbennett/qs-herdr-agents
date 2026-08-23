"""Unit tests for bin/omarchy-herdr-focus — orchestrator only.

Hyprland-specific functions (find_herdr_client, client_rank, etc.) have been
migrated to tests/test_hyprland.py. This file tests main()'s flow control.
"""

import io
import sys
import unittest
from unittest import mock

sys.dont_write_bytecode = True

import importlib.machinery
import importlib.util
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "bin" / "omarchy-herdr-focus"


def load_module():
    loader = importlib.machinery.SourceFileLoader("omarchy_herdr_focus", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


MOD = load_module()


class MainTest(unittest.TestCase):
    def test_usage_error_without_target(self):
        with mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main([]), 2)
            self.assertEqual(MOD.main([""]), 2)

    def test_focus_failure_exits_1_when_no_hyprland(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = None
            with mock.patch.object(sys, "stderr", new=io.StringIO()):
                self.assertEqual(MOD.main(["w1:p1"]), 1)

    def test_focus_failure_ok_when_hyprland_raises(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = {"address": "0x42"}
            instance.ensureVisible.return_value = True
            instance.raiseWindow.return_value = (True, "")
            with mock.patch.object(sys, "stderr", new=io.StringIO()):
                self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_without_hyprland(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = None
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_without_herdr_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = None
            instance.findByClass.return_value = None
            instance.raiseWindow = mock.MagicMock()
            self.assertEqual(MOD.main(["w1:p1"]), 0)
            instance.findByClass.assert_called_once_with([], "")
            instance.raiseWindow.assert_not_called()

    def test_class_fallback_raises_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = None
            instance.findByClass.return_value = {"address": "0x7"}
            instance.ensureVisible.return_value = True
            instance.raiseWindow.return_value = (True, "")
            self.assertEqual(MOD.main(["w1:p1", "ghostty"]), 0)
            instance.findByClass.assert_called_once_with([], "ghostty")
            instance.raiseWindow.assert_called_once_with("0x7")

    def test_class_fallback_miss_still_exits_0(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = None
            instance.findByClass.return_value = None
            instance.raiseWindow = mock.MagicMock()
            self.assertEqual(MOD.main(["w1:p1", "ghostty"]), 0)
            instance.raiseWindow.assert_not_called()

    def test_opens_special_workspace_before_raising(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = {"address": "0x42"}
            instance.ensureVisible.return_value = False
            instance.raiseWindow.return_value = (True, "")
            self.assertEqual(MOD.main(["w1:p1"]), 0)
            instance.ensureVisible.assert_called_once()

    def test_ok_with_raised_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = {"address": "0x42"}
            instance.ensureVisible.return_value = True
            instance.raiseWindow.return_value = (True, "")
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_raise_failure_exits_0_when_focus_ok(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = {"address": "0x42"}
            instance.ensureVisible.return_value = True
            instance.raiseWindow.return_value = (False, "nope")
            with mock.patch.object(sys, "stderr", new=io.StringIO()):
                self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_raise_failure_exits_1_when_focus_also_failed(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(MOD, "HyprlandWindow") as MockHL:
            instance = MockHL.return_value
            instance.hyprctlClients.return_value = []
            instance.findClient.return_value = {"address": "0x42"}
            instance.ensureVisible.return_value = True
            instance.raiseWindow.return_value = (False, "nope")
            with mock.patch.object(sys, "stderr", new=io.StringIO()):
                self.assertEqual(MOD.main(["w1:p1"]), 1)

    def test_usage_error_with_too_many_args(self):
        with mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["a", "b", "c"]), 2)


if __name__ == "__main__":
    unittest.main()
