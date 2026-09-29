"""Tests for the speakeasy CLI. Run: python3 -m unittest discover -s test

State and config go to a temporary XDG directory with notifications off, so
nothing touches your real tasks. The end-to-end test needs tmux.
"""

import atexit
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "bin", "speakeasy")
TMP = tempfile.mkdtemp(prefix="speakeasy-test-")
atexit.register(shutil.rmtree, TMP, True)
os.environ["XDG_STATE_HOME"] = os.path.join(TMP, "state")
os.environ["XDG_CONFIG_HOME"] = os.path.join(TMP, "config")
os.makedirs(os.path.join(TMP, "config", "speakeasy"))
FAKE = os.path.join(TMP, "fake-agent")
with open(FAKE, "w") as f:
    f.write('#!/bin/sh\necho "args: $*"\nsleep 1\necho finished\nexit 3\n')
os.chmod(FAKE, 0o755)
with open(os.path.join(TMP, "config", "speakeasy", "config.json"), "w") as f:
    json.dump({"notify": False, "quietSeconds": 2,
               "agents": {"fake": {"name": "Fake", "bin": FAKE, "prompt": "arg",
                                   "models": ["", "big"], "modelFlag": "--model"}}}, f)

loader = importlib.machinery.SourceFileLoader("speakeasy", CLI)
spec = importlib.util.spec_from_loader("speakeasy", loader)
se = importlib.util.module_from_spec(spec)
loader.exec_module(se)
# Tests run tmux on their own socket so they never see real tasks.
se.SOCKET = "speakeasy-test-%d" % os.getpid()


def make_task(tid="abc123", agent="claude", **kw):
    task = {"id": tid, "title": "Fix login", "prompt": "fix it", "agent": agent, "agentName": agent,
            "model": "", "cwd": TMP, "args": [], "status": "running", "detail": "", "unseen": False,
            "createdAt": se.now(), "updatedAt": se.now(), "exitCode": None, "sessionId": ""}
    task.update(kw)
    se.write_json(se.task_path(tid), task)
    return task


def hook(tid, event, payload=None, argv_payload=None):
    args = ["hook", tid, event] + ([json.dumps(argv_payload)] if argv_payload is not None else [])
    old = sys.stdin
    sys.stdin = io.StringIO(json.dumps(payload or {}))
    try:
        se.main(args)
    finally:
        sys.stdin = old
    return se.load_task(tid)


class Pure(unittest.TestCase):
    def test_first_line_skips_markdown_and_blank_lines(self):
        self.assertEqual(se.first_line("\n\n## Done\nmore"), "Done")
        self.assertEqual(se.first_line("x" * 200, 10), "x" * 9 + "…")

    def test_blocking_questions(self):
        self.assertIn("hooks", se.blocking_question("  Hooks need review\n 1 hook is new"))
        self.assertEqual(se.blocking_question("Do you trust the contents of this project?"), "Asks whether to trust this folder.")
        self.assertEqual(se.blocking_question("● OK"), "")
        self.assertIn("sign in", se.blocking_question("Sign in at this page:\n https://auth.meta.com/oauth/device/?code=AB-CD"))
        self.assertIn("trust", se.blocking_question("Do you trust this workspace?"))

    def test_codex_title_turn(self):
        self.assertTrue(se.is_codex_title_turn('{"title":"Tell a joke"}'))
        self.assertFalse(se.is_codex_title_turn("A normal reply"))
        self.assertFalse(se.is_codex_title_turn('{"title":"x","other":1}'))

    def test_describe_tool(self):
        self.assertEqual(se.describe_tool("Bash", {"command": "npm test\nmore"}), "run: npm test")
        self.assertEqual(se.describe_tool("Edit", {"file_path": "/a/b/app.py"}), "edit app.py")
        self.assertEqual(se.describe_tool("Write", {"file_path": "/a/new.txt"}), "write new.txt")
        self.assertEqual(se.describe_tool("Task", {}), "use Task")

    def test_claude_command_has_model_name_hooks_and_prompt_last(self):
        task = make_task(model="opus")
        argv, typed = se.build_command(task, se.agent_by_id("claude"))
        self.assertEqual(argv[1], "--model=opus")
        self.assertIn("--name=Fix login", argv)
        hooks = json.loads(argv[argv.index("--settings") + 1])["hooks"]
        self.assertIn("Stop", hooks)
        self.assertIn("PermissionRequest", hooks)
        self.assertIn(" hook abc123 Stop", hooks["Stop"][0]["hooks"][0]["command"])
        self.assertEqual(argv[-2:], ["--", "fix it"])
        self.assertEqual(typed, "")

    def test_codex_command_sets_notify(self):
        argv, _ = se.build_command(make_task(agent="codex"), se.agent_by_id("codex"))
        notify = [a for a in argv if a.startswith("notify=")][0]
        self.assertEqual(json.loads(notify[len("notify="):])[-2:], ["abc123", "codex"])

    def test_prompt_delivery_modes(self):
        argv, _ = se.build_command(make_task(agent="antigravity", model="gemini-3.8-flash-low"), se.agent_by_id("antigravity"))
        self.assertIn("--model=gemini-3.8-flash-low", argv)
        self.assertEqual(argv[-1], "-i=fix it")
        argv, typed = se.build_command(make_task(agent="crush"), se.agent_by_id("crush"))
        self.assertNotIn("fix it", argv)
        self.assertEqual(typed, "fix it")

    def test_effort_flags(self):
        argv, _ = se.build_command(make_task(effort="high"), se.agent_by_id("claude"))
        self.assertIn("--effort=high", argv)
        argv, _ = se.build_command(make_task(agent="codex", effort="xhigh"), se.agent_by_id("codex"))
        self.assertIn('model_reasoning_effort="xhigh"', argv)
        argv, _ = se.build_command(make_task(agent="antigravity", effort="high"), se.agent_by_id("antigravity"))
        self.assertFalse(any("effort" in a for a in argv))

    def test_codex_models_come_from_its_cache(self):
        path = os.path.join(TMP, "codex-models.json")
        se.write_json(path, {"models": [
            {"slug": "gpt-a", "display_name": "GPT-A", "visibility": "list",
             "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}, {"effort": "max"}]},
            {"slug": "gpt-b", "display_name": "GPT-B", "visibility": "list",
             "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]},
            {"slug": "hidden", "visibility": "hide"}]})
        a = {"modelsFile": path, "modelLabels": {}, "modelEfforts": {}, "efforts": [], "effortArgs": ["x"]}
        se.read_models_file(a)
        self.assertEqual(a["models"], ["", "gpt-a", "gpt-b"])
        self.assertEqual(a["modelLabels"]["gpt-a"], "GPT-A")
        self.assertEqual(se.efforts_for(a, "gpt-a"), ["low", "high", "max"])
        self.assertEqual(se.efforts_for(a, ""), ["low", "high"])

    def test_claude_list_has_aliases_and_pinned_versions(self):
        claude = se.agent_by_id("claude")
        for m in ("opus", "opusplan", "opus[1m]", "claude-opus-4-6", "claude-fable-5-1"):
            self.assertIn(m, claude["models"])
        self.assertEqual(claude["modelLabels"]["opus"], "Opus · latest")

    def test_dash_leading_text_cannot_become_an_option(self):
        task = make_task(title="--dangerously-skip-permissions", prompt="-p rm everything")
        argv, _ = se.build_command(task, se.agent_by_id("claude"))
        self.assertNotIn("--dangerously-skip-permissions", argv)
        self.assertIn("--name=--dangerously-skip-permissions", argv)
        self.assertEqual(argv[-2:], ["--", "-p rm everything"])

    def test_model_ids_from_other_programs_are_checked(self):
        for bad in ("--yolo", "-x", "a b", "", "x;rm"):
            self.assertIsNone(se.MODEL_ID.match(bad), bad)
        for good in ("gemini-3.8-flash-low", "opus[1m]", "gpt-5.5", "provider/model:tag"):
            self.assertIsNotNone(se.MODEL_ID.match(good), good)

    def test_task_ids_are_validated_before_touching_paths(self):
        with self.assertRaises(SystemExit):
            se.task_path("../../etc/passwd")

    def test_default_model_adds_no_flag(self):
        argv, _ = se.build_command(make_task(model=""), se.agent_by_id("claude"))
        self.assertFalse(any(a.startswith("--model") for a in argv))


class Hooks(unittest.TestCase):
    def test_claude_lifecycle(self):
        make_task(status="starting")
        t = hook("abc123", "SessionStart", {"session_id": "s-1"})
        self.assertEqual((t["status"], t["sessionId"]), ("running", "s-1"))
        hook("abc123", "PermissionRequest", {"tool_name": "Bash", "tool_input": {"command": "rm -rf build"}})
        t = hook("abc123", "Notification", {"notification_type": "permission_prompt", "message": "Claude needs your permission"})
        self.assertEqual((t["status"], t["detail"], t["unseen"]), ("needs-you", "Wants to run: rm -rf build", True))
        t = hook("abc123", "PostToolUse", {})
        self.assertEqual((t["status"], t["pendingAsk"]), ("running", ""))
        t = hook("abc123", "Stop", {"last_assistant_message": "## All tests pass\n\nDetails…"})
        self.assertEqual((t["status"], t["detail"]), ("ready", "All tests pass"))
        # The idle reminder after a finished turn is not news.
        t = hook("abc123", "Notification", {"notification_type": "idle_prompt", "message": "waiting"})
        self.assertEqual(t["status"], "ready")

    def test_finished_task_ignores_late_hooks(self):
        make_task(status="stopped")
        self.assertEqual(hook("abc123", "Stop", {"last_assistant_message": "hi"})["status"], "stopped")

    def test_codex_notify(self):
        make_task(agent="codex")
        t = hook("abc123", "codex", argv_payload={"type": "agent-turn-complete", "last-assistant-message": '{"title":"x"}'})
        self.assertEqual(t["status"], "running")
        t = hook("abc123", "codex", argv_payload={"type": "agent-turn-complete", "last-assistant-message": "Fixed it."})
        self.assertEqual((t["status"], t["detail"]), ("ready", "Fixed it."))


class Models(unittest.TestCase):
    def test_live_models_parse_and_cache(self):
        lister = os.path.join(TMP, "fake-lister")
        with open(lister, "w") as f:
            f.write('#!/bin/sh\necho "Fetching available models..."\n'
                    'printf "gem-fast\\tGem Fast (Low)\\ngem-pro\\tGem Pro\\n"\n')
        os.chmod(lister, 0o755)
        agent = {"id": "lister", "name": "Lister", "path": lister, "modelsCommand": []}
        models = se.fetch_models(agent)
        self.assertEqual([m["id"] for m in models], ["gem-fast", "gem-pro"])
        self.assertEqual(models[0]["label"], "Gem Fast (Low)")
        cached = se.load_json(se.models_cache_path("lister"), {})
        self.assertEqual(len(cached["models"]), 2)

    def test_failed_listing_keeps_the_old_cache(self):
        agent = {"id": "broken", "name": "Broken", "path": "/bin/false", "modelsCommand": []}
        self.assertIsNone(se.fetch_models(agent))
        self.assertFalse(os.path.exists(se.models_cache_path("broken")))

    def test_cursor_has_a_fixed_list(self):
        self.assertIn("composer-2.5", se.agent_by_id("cursor-agent")["models"])


class Settings(unittest.TestCase):
    def setUp(self):
        self.saved = se.load_json(se.CONFIG_PATH, {})

    def tearDown(self):
        se.write_json(se.CONFIG_PATH, self.saved)

    def test_hide_and_show_keep_other_config(self):
        se.main(["agents", "--hide=crush", "--hide=hermes"])
        self.assertTrue(se.agent_by_id("crush")["hidden"])
        se.main(["agents", "--show=crush"])
        cfg = se.load_json(se.CONFIG_PATH, {})
        self.assertEqual(cfg["hiddenAgents"], ["hermes"])
        self.assertIn("fake", cfg["agents"])  # untouched

    def test_set_values(self):
        se.main(["set", "notify", "off"])
        se.main(["set", "quiet-seconds", "1"])
        se.main(["set", "default-cwd", "--", TMP])
        cfg = se.load_json(se.CONFIG_PATH, {})
        self.assertEqual((cfg["notify"], cfg["quietSeconds"], cfg["defaultCwd"]), (False, 5, TMP))
        with self.assertRaises(SystemExit):
            se.main(["set", "default-cwd", "/does/not/exist"])


class NewAgents(unittest.TestCase):
    def test_muse_catalog(self):
        path = os.path.join(TMP, "muse-catalog.json")
        se.write_json(path, {"rows": [
            {"model_id": "muse-spark-1.3", "display_label": "Muse Spark 1.3", "visibility": "visible",
             "reasoning_effort_variants": [{"tier": "high"}, {"tier": "low"}, {"tier": "max"}]},
            {"model_id": "hidden-one", "visibility": "hidden"}]})
        a = {"modelsFile": path, "modelsFormat": "muse", "modelLabels": {}, "modelEfforts": {}, "efforts": [], "effortArgs": ["x"]}
        se.read_models_file(a)
        self.assertEqual(a["models"], ["", "muse-spark-1.3"])
        self.assertEqual(se.efforts_for(a, "muse-spark-1.3"), ["low", "high", "max"])

    def test_grok_bullet_list(self):
        lister = os.path.join(TMP, "fake-grok")
        with open(lister, "w") as f:
            f.write('#!/bin/sh\nprintf "Default model: g-2\\n\\nAvailable models:\\n  * g-2 (default)\\n  - g-1\\n"\n')
        os.chmod(lister, 0o755)
        models = se.fetch_models({"id": "grok-test", "path": lister, "modelsCommand": [], "modelsParse": "bullets"})
        self.assertEqual([m["id"] for m in models], ["g-2", "g-1"])

    def test_hermes_runs_chat_with_query(self):
        argv, _ = se.build_command(make_task(agent="hermes", model="x"), se.agent_by_id("hermes"))
        self.assertEqual(argv[1], "chat")
        self.assertEqual(argv[-1], "--query=fix it")


class Dirs(unittest.TestCase):
    def dirs(self, text):
        out = io.StringIO()
        old, sys.stdout = sys.stdout, out
        try:
            se.main(["dirs", "--", text])
        finally:
            sys.stdout = old
        return json.loads(out.getvalue())

    def test_completion(self):
        root = os.path.join(TMP, "proj")
        for d in ("alpha", "alpine", "beta", ".hidden", "zalp"):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        os.makedirs(os.path.join(root, "alpha", ".git"), exist_ok=True)
        open(os.path.join(root, "alpaca.txt"), "w").close()
        names = [e["name"] for e in self.dirs(root + "/")["entries"]]
        self.assertEqual(names, ["alpha", "alpine", "beta", "zalp"])  # folders only, no dot-folders
        got = self.dirs(root + "/alp")["entries"]
        self.assertEqual([e["name"] for e in got], ["alpha", "alpine", "zalp"])  # prefix first, then contains
        self.assertTrue(got[0]["git"])
        self.assertEqual([e["name"] for e in self.dirs(root + "/.h")["entries"]], [".hidden"])
        self.assertFalse(self.dirs("/does/not/exist/x")["exists"])

    def test_dash_path_is_a_path(self):
        self.assertEqual(self.dirs("-rf")["entries"], [])


class State(unittest.TestCase):
    def test_deleted_remembered_folder_falls_back_to_default(self):
        se.write_json(se.PREFS_PATH, {"agent": "claude", "model": "", "cwd": "/does/not/exist"})
        out = io.StringIO()
        old, sys.stdout = sys.stdout, out
        try:
            se.main(["state"])
        finally:
            sys.stdout = old
        self.assertEqual(json.loads(out.getvalue())["prefs"]["cwd"], os.path.expanduser("~"))


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class EndToEnd(unittest.TestCase):
    def run_cli(self, *args):
        env = dict(os.environ, PATH=os.environ["PATH"])
        # The subprocess must use the same private socket as this test.
        code = "import importlib.machinery,sys;" \
               f"m=importlib.machinery.SourceFileLoader('se',{CLI!r}).load_module();" \
               f"m.SOCKET={se.SOCKET!r};sys.argv=['speakeasy']+{list(args)!r};m.main()"
        return subprocess.run([sys.executable, "-c", code], text=True, capture_output=True, env=env)

    def tearDown(self):
        subprocess.run(["tmux", "-L", se.SOCKET, "kill-server"], capture_output=True)

    def test_fake_agent_runs_hidden_and_exit_is_recorded(self):
        r = self.run_cli("new", "--json", "-a", "fake", "-m", "big", "-t", "Hidden", "-p", "do the thing", "-C", TMP)
        self.assertEqual(r.returncode, 0, r.stderr)
        tid = json.loads(r.stdout)["id"]
        # The wrapper runs the agent under the tmux session created with the
        # real socket name baked into the command, so check via task state.
        for _ in range(40):
            t = se.load_task(tid)
            if t["status"] == "exited":
                break
            time.sleep(0.25)
        self.assertEqual(t["status"], "exited")
        self.assertEqual(t["exitCode"], 3)
        self.assertTrue(t["unseen"])

    def test_unknown_agent_and_missing_folder_fail_cleanly(self):
        r = self.run_cli("new", "-a", "nope", "-t", "x")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown agent", r.stderr)
        r = self.run_cli("new", "-a", "fake", "-t", "x", "-C", "/does/not/exist")
        self.assertIn("folder does not exist", r.stderr)
        r = self.run_cli("new", "-a", "fake", "-t", "x", "-e", "high", "-C", TMP)
        self.assertIn("does not take effort", r.stderr)


if __name__ == "__main__":
    unittest.main()
