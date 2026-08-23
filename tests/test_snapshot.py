"""Unit tests for snapshot.js — the Snapshot Adapter."""

import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).parents[1] / "snapshot.js"

_EVAL_WRAPPER = r"""
const m = require(process.argv[1]);
const fn = m[process.argv[2]];
const args = JSON.parse(process.argv[3]);
console.log(JSON.stringify(fn.apply(null, args)));
"""


def js_eval(func_name, *args):
    """Evaluate a snapshot.js function via Node.js and return the result."""
    args_json = json.dumps(list(args))
    out = subprocess.run(
        ["node", "-e", _EVAL_WRAPPER, str(SCRIPT), func_name, args_json],
        capture_output=True, text=True, check=False, timeout=10,
    )
    if out.returncode != 0:
        raise RuntimeError(f"node failed: {out.stderr}")
    return json.loads(out.stdout)


# ---------------------------------------------------------------------------
# Helpers to build valid snapshot payloads
# ---------------------------------------------------------------------------

def _snapshot(agents=None, workspaces=None):
    return {
        "result": {
            "snapshot": {
                "agents": agents or [],
                "workspaces": workspaces or [],
            }
        }
    }


def _agent(name="opencode", status="working", pane_id="w1:p1",
           workspace_id="1", cwd="/home/user/project", title="coding", focused=False):
    return {
        "agent": name,
        "agent_status": status,
        "pane_id": pane_id,
        "workspace_id": workspace_id,
        "cwd": cwd,
        "terminal_title_stripped": title,
        "focused": focused,
    }


def _workspace(wid="1", label="my-project"):
    return {"workspace_id": wid, "label": label}


# ---------------------------------------------------------------------------
# parse()
# ---------------------------------------------------------------------------

class ParseTest(unittest.TestCase):
    def test_valid_snapshot(self):
        payload = json.dumps(_snapshot(agents=[_agent()], workspaces=[_workspace()]))
        result = js_eval("parse", payload)
        self.assertFalse(result["error"])
        self.assertIn("snapshot", result)
        self.assertEqual(len(result["snapshot"]["agents"]), 1)

    def test_malformed_json(self):
        result = js_eval("parse", "not json at all")
        self.assertEqual(result["error"], "herdr returned invalid JSON")
        self.assertIsNone(result["snapshot"])

    def test_missing_result_key(self):
        result = js_eval("parse", json.dumps({"something": "else"}))
        self.assertEqual(result["error"], "herdr snapshot unavailable")
        self.assertIsNone(result["snapshot"])

    def test_null_result(self):
        result = js_eval("parse", json.dumps({"result": None}))
        self.assertEqual(result["error"], "herdr snapshot unavailable")

    def test_empty_snapshot(self):
        result = js_eval("parse", json.dumps({"result": {"snapshot": {}}}))
        self.assertFalse(result["error"])
        self.assertEqual(result["snapshot"], {})


# ---------------------------------------------------------------------------
# basename()
# ---------------------------------------------------------------------------

class BasenameTest(unittest.TestCase):
    def test_normal_path(self):
        self.assertEqual(js_eval("basename", "/home/user/project"), "project")

    def test_trailing_slash(self):
        self.assertEqual(js_eval("basename", "/home/user/project/"), "")

    def test_no_slash(self):
        self.assertEqual(js_eval("basename", "just-a-name"), "just-a-name")

    def test_empty(self):
        self.assertEqual(js_eval("basename", ""), "")

    def test_none(self):
        self.assertEqual(js_eval("basename", None), "")


# ---------------------------------------------------------------------------
# buildRecords()
# ---------------------------------------------------------------------------

class BuildRecordsTest(unittest.TestCase):
    def _build(self, agents, workspaces=None, state=None):
        snap = _snapshot(agents=agents, workspaces=workspaces)
        snapshot = js_eval("parse", json.dumps(snap))["snapshot"]
        return js_eval("buildRecords", snapshot, state or {})

    def test_single_agent(self):
        result = self._build([_agent(name="claude", pane_id="w1:p1")])
        records = result["byPane"]
        self.assertIn("w1:p1", records)
        self.assertEqual(records["w1:p1"]["name"], "claude")
        self.assertEqual(records["w1:p1"]["status"], "working")
        self.assertEqual(result["counts"]["active"], 1)
        self.assertEqual(result["counts"]["working"], 1)

    def test_multiple_agents(self):
        agents = [
            _agent(name="a", pane_id="w1:p1", status="working"),
            _agent(name="b", pane_id="w1:p2", status="blocked"),
            _agent(name="c", pane_id="w2:p1", status="idle"),
        ]
        result = self._build(agents)
        self.assertEqual(result["counts"]["active"], 2)  # working + blocked
        self.assertEqual(result["counts"]["working"], 1)
        self.assertEqual(result["counts"]["blocked"], 1)
        self.assertEqual(len(result["byPane"]), 3)

    def test_workspace_label_joined(self):
        workspaces = [_workspace(wid="42", label="qs-herdr")]
        agents = [_agent(workspace_id="42")]
        result = self._build(agents, workspaces=workspaces)
        self.assertEqual(result["byPane"]["w1:p1"]["workspaceLabel"], "qs-herdr")

    def test_folder_from_cwd(self):
        agents = [_agent(cwd="/home/user/my-project")]
        result = self._build(agents)
        self.assertEqual(result["byPane"]["w1:p1"]["folder"], "my-project")

    def test_preserves_entered_at_from_state(self):
        state = {"w1:p1": {"status": "working", "enteredAt": 1000}}
        agents = [_agent(status="working")]
        result = self._build(agents, state=state)
        self.assertEqual(result["byPane"]["w1:p1"]["enteredAt"], 1000)

    def test_resets_entered_at_on_status_change(self):
        state = {"w1:p1": {"status": "working", "enteredAt": 1000}}
        agents = [_agent(status="blocked")]
        result = self._build(agents, state=state)
        self.assertNotEqual(result["byPane"]["w1:p1"]["enteredAt"], 1000)

    def test_empty_agents(self):
        result = self._build([])
        self.assertEqual(result["byPane"], {})
        self.assertEqual(result["counts"]["active"], 0)

    def test_defaults_for_missing_fields(self):
        agents = [{"agent_status": "working", "pane_id": "w1:p1"}]
        result = self._build(agents)
        record = result["byPane"]["w1:p1"]
        self.assertEqual(record["name"], "agent")
        self.assertEqual(record["cwd"], "")
        self.assertEqual(record["title"], "")


# ---------------------------------------------------------------------------
# diffRecords()
# ---------------------------------------------------------------------------

class DiffRecordsTest(unittest.TestCase):
    def test_no_change(self):
        prev = {"w1:p1": {"status": "working"}}
        curr = {"w1:p1": {"status": "working"}}
        result = js_eval("diffRecords", prev, curr)
        self.assertEqual(result["added"], [])
        self.assertEqual(result["removed"], [])
        self.assertEqual(len(result["transitions"]), 1)
        self.assertEqual(result["transitions"][0]["from"], "working")
        self.assertEqual(result["transitions"][0]["to"], "working")

    def test_added_pane(self):
        curr = {"w1:p1": {"status": "working"}}
        result = js_eval("diffRecords", {}, curr)
        self.assertEqual(result["added"], ["w1:p1"])
        self.assertEqual(result["removed"], [])

    def test_removed_pane(self):
        prev = {"w1:p1": {"status": "working"}}
        result = js_eval("diffRecords", prev, {})
        self.assertEqual(result["removed"], ["w1:p1"])
        self.assertEqual(result["added"], [])

    def test_transition(self):
        prev = {"w1:p1": {"status": "working", "name": "opencode"}}
        curr = {"w1:p1": {"status": "done", "name": "opencode"}}
        result = js_eval("diffRecords", prev, curr)
        self.assertEqual(len(result["transitions"]), 1)
        t = result["transitions"][0]
        self.assertEqual(t["from"], "working")
        self.assertEqual(t["to"], "done")
        self.assertEqual(t["paneId"], "w1:p1")

    def test_mixed_changes(self):
        prev = {
            "w1:p1": {"status": "working"},
            "w1:p2": {"status": "blocked"},
        }
        curr = {
            "w1:p1": {"status": "working"},   # no change
            "w1:p3": {"status": "idle"},       # added
            # w1:p2 removed
        }
        result = js_eval("diffRecords", prev, curr)
        self.assertEqual(result["added"], ["w1:p3"])
        self.assertEqual(result["removed"], ["w1:p2"])
        self.assertEqual(len(result["transitions"]), 1)
        self.assertEqual(result["transitions"][0]["paneId"], "w1:p1")
        self.assertEqual(result["transitions"][0]["from"], "working")
        self.assertEqual(result["transitions"][0]["to"], "working")

    def test_empty_both(self):
        result = js_eval("diffRecords", {}, {})
        self.assertEqual(result["added"], [])
        self.assertEqual(result["removed"], [])
        self.assertEqual(result["transitions"], [])


if __name__ == "__main__":
    unittest.main()
