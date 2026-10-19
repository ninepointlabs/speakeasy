# Changelog

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
