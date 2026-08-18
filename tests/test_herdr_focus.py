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


def client(address, pid):
    return {"address": address, "pid": pid}


class FindHerdrWindowTest(unittest.TestCase):
    def test_returns_matching_address(self):
        checker = lambda pid: pid == 42  # noqa: E731
        clients = [client("0x1", 10), client("0x2", 42), client("0x3", 7)]
        self.assertEqual(MOD.find_herdr_window(clients, checker), "0x2")

    def test_returns_none_when_no_match(self):
        checker = lambda pid: False  # noqa: E731
        self.assertIsNone(MOD.find_herdr_window([client("0x1", 1)], checker))
        self.assertIsNone(MOD.find_herdr_window([], checker))

    def test_skips_clients_without_pid_or_address(self):
        checker = lambda pid: pid == 2  # noqa: E731
        clients = [{"address": "0x1"}, {"pid": 2}, client("0x2", 2)]
        self.assertEqual(MOD.find_herdr_window(clients, checker), "0x2")


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

    def test_focus_failure_exits_1(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(False, "boom")), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 1)

    def test_ok_without_hyprland(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=None):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_without_herdr_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_window", return_value=None):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_ok_with_raised_window(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_window", return_value="0x42"), \
             mock.patch.object(MOD, "raise_window", return_value=(True, "")):
            self.assertEqual(MOD.main(["w1:p1"]), 0)

    def test_raise_failure_exits_1(self):
        with mock.patch.object(MOD, "focus_in_herdr", return_value=(True, "")), \
             mock.patch.object(MOD, "hyprctl_clients", return_value=[]), \
             mock.patch.object(MOD, "find_herdr_window", return_value="0x42"), \
             mock.patch.object(MOD, "raise_window", return_value=(False, "nope")), \
             mock.patch.object(sys, "stderr", new=io.StringIO()):
            self.assertEqual(MOD.main(["w1:p1"]), 1)


if __name__ == "__main__":
    unittest.main()
