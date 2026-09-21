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

def _snapshot(agents=None, workspaces=None, tabs=None):
    return {
        "result": {
            "snapshot": {
                "agents": agents or [],
                "workspaces": workspaces or [],
                "tabs": tabs or [],
            }
        }
    }


def _agent(name="opencode", status="working", pane_id="w1:p1",
           workspace_id="1", tab_id="", cwd="/home/user/project", title="coding",
           focused=False):
    return {
        "agent": name,
        "agent_status": status,
        "pane_id": pane_id,
        "workspace_id": workspace_id,
        "tab_id": tab_id,
        "cwd": cwd,
        "terminal_title_stripped": title,
        "focused": focused,
    }


def _workspace(wid="1", label="my-project"):
    return {"workspace_id": wid, "label": label}


def _tab(tab_id="t1", label="implementation"):
    return {"tab_id": tab_id, "label": label}


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
# Agent Timeline
# ---------------------------------------------------------------------------

class AgentTimelineTest(unittest.TestCase):
    def _evolve(self, timeline, agents, workspaces=None, tabs=None, now=1000):
        snap = _snapshot(agents=agents, workspaces=workspaces, tabs=tabs)
        snapshot = js_eval("parse", json.dumps(snap))["snapshot"]
        return js_eval("evolveTimeline", timeline, snapshot, now)

    def test_first_snapshot_establishes_baseline_without_intents(self):
        result = self._evolve(js_eval("initialTimeline"), [
            _agent(name="claude", pane_id="w1:p1", status="blocked")
        ])
        records = result["byPane"]
        self.assertIn("w1:p1", records)
        self.assertEqual(records["w1:p1"]["name"], "claude")
        self.assertEqual(records["w1:p1"]["status"], "blocked")
        self.assertEqual(result["intents"], [])
        self.assertEqual(result["counts"]["active"], 1)
        self.assertEqual(result["counts"]["blocked"], 1)

    def test_counts_and_records(self):
        agents = [
            _agent(name="a", pane_id="w1:p1", status="working"),
            _agent(name="b", pane_id="w1:p2", status="blocked"),
            _agent(name="c", pane_id="w2:p1", status="idle"),
        ]
        result = self._evolve(js_eval("initialTimeline"), agents)
        self.assertEqual(result["counts"]["active"], 2)  # working + blocked
        self.assertEqual(result["counts"]["working"], 1)
        self.assertEqual(result["counts"]["blocked"], 1)
        self.assertEqual(len(result["byPane"]), 3)

    def test_workspace_label_joined(self):
        workspaces = [_workspace(wid="42", label="qs-herdr")]
        agents = [_agent(workspace_id="42")]
        result = self._evolve(js_eval("initialTimeline"), agents, workspaces=workspaces)
        self.assertEqual(result["byPane"]["w1:p1"]["workspaceLabel"], "qs-herdr")

    def test_tab_label_joined(self):
        tabs = [_tab(tab_id="t42", label="review")]
        agents = [_agent(tab_id="t42")]
        result = self._evolve(js_eval("initialTimeline"), agents, tabs=tabs)
        self.assertEqual(result["byPane"]["w1:p1"]["tabLabel"], "review")

    def test_tab_label_empty_without_matching_tab(self):
        result = self._evolve(js_eval("initialTimeline"), [_agent(tab_id="missing")], tabs=[_tab()])
        self.assertEqual(result["byPane"]["w1:p1"]["tabLabel"], "")

    def test_folder_from_cwd(self):
        agents = [_agent(cwd="/home/user/my-project")]
        result = self._evolve(js_eval("initialTimeline"), agents)
        self.assertEqual(result["byPane"]["w1:p1"]["folder"], "my-project")

    def test_preserves_entered_at_for_same_status(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="working")], now=1000)
        result = self._evolve(first["timeline"], [_agent(status="working")], now=2000)
        self.assertEqual(result["byPane"]["w1:p1"]["enteredAt"], 1000)

    def test_resets_entered_at_on_status_change(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="working")], now=1000)
        result = self._evolve(first["timeline"], [_agent(status="blocked")], now=2000)
        self.assertEqual(result["byPane"]["w1:p1"]["enteredAt"], 2000)

    def test_empty_agents(self):
        result = self._evolve(js_eval("initialTimeline"), [])
        self.assertEqual(result["byPane"], {})
        self.assertEqual(result["counts"]["active"], 0)

    def test_defaults_for_missing_fields(self):
        agents = [{"agent_status": "working", "pane_id": "w1:p1"}]
        result = self._evolve(js_eval("initialTimeline"), agents)
        record = result["byPane"]["w1:p1"]
        self.assertEqual(record["name"], "agent")
        self.assertEqual(record["cwd"], "")
        self.assertEqual(record["title"], "")

    def test_blocked_transition_returns_structured_intent(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="working")])
        result = self._evolve(first["timeline"], [_agent(status="blocked")])
        self.assertEqual(result["intents"], [{
            "type": "blocked", "paneId": "w1:p1", "name": "opencode",
            "workspaceLabel": "1", "urgency": "critical",
        }])

    def test_working_to_done_returns_finished_intent(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="working")])
        result = self._evolve(first["timeline"], [_agent(status="done")])
        self.assertEqual(result["intents"][0]["type"], "finished")
        self.assertEqual(result["intents"][0]["urgency"], "normal")

    def test_removed_blocked_pane_returns_agent_gone_intent_and_prunes_state(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="blocked")], now=1000)
        result = self._evolve(first["timeline"], [], now=2000)
        self.assertEqual(result["intents"][0]["type"], "agentGone")
        self.assertEqual(result["timeline"]["enteredAtByPane"], {})

    def test_removed_working_pane_does_not_return_intent(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent(status="working")])
        result = self._evolve(first["timeline"], [])
        self.assertEqual(result["intents"], [])

    def test_reappearing_pane_starts_a_new_elapsed_time(self):
        first = self._evolve(js_eval("initialTimeline"), [_agent()], now=1000)
        missing = self._evolve(first["timeline"], [], now=2000)
        result = self._evolve(missing["timeline"], [_agent()], now=3000)
        self.assertEqual(result["byPane"]["w1:p1"]["enteredAt"], 3000)


if __name__ == "__main__":
    unittest.main()
