# Changelog

## Unreleased

- A config.json that isn't valid JSON (or isn't an object) now prints a
  warning naming the file and the error, then runs with the defaults.
  `set` and `agents --hide/--show` refuse to write over it instead of
  replacing it with an empty config.
- `new -i` without a terminal says it needs one instead of a traceback.
- `--help` no longer lists the internal `hook`, `_run` and `_notify` commands.
- `send` right after `new` waits until the first prompt has been typed and
  submitted, so the two no longer run together. A question on screen (a
  trust dialog) is still answered at once.

## 0.3.2

- Task titles no longer appear in any process's arguments. The title shown
  in a task's tmux status line was set with `tmux set-option @se_title <title>`
  on start and on rename; it now goes to `tmux source-file -` on stdin,
  quoted for tmux so `#`, `;`, quotes, `$`, a leading `-` and newlines stay
  text.
- Notifications are sent over D-Bus from inside Python (PyGObject), so the
  task's title and the agent's message are in no process's arguments. When
  PyGObject is missing, the `gdbus` and `notify-send` fallbacks show only a
  generic title ("A Speakeasy task needs you").
- `speakeasy rename <task> -` reads the new title from stdin.
- README: the privacy section lists the remaining, documented exceptions
  (custom agents set to take the prompt as an argument, Codex's own `notify`
  hook, and text typed on Speakeasy's own command line).

Earlier versions: see the git history.
