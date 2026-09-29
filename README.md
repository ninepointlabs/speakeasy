# Speakeasy

The back room for your AI agents. Hand Claude Code, Codex, Gemini or another coding
agent a task, give it a name, and it works in a terminal you never have to
look at. The bar tells you which tasks are working, which are done and which
need you; a notification taps you on the shoulder when one wants an approval
or has finished, and clicking it opens that task's terminal. Close the window
and the task goes back out of sight, still running.

Sibling to [Barkeep](https://github.com/ninepointlabs/barkeep) and
[Barback](https://github.com/ninepointlabs/barback). Every task is a tab.

- **Named tasks.** "Fix the login redirect", not "terminal 4".
- **Hidden terminals.** Each task is a tmux session on a private socket. No
  windows appear until you ask for one.
- **Knows when it needs you.** Claude Code reports through hooks: an approval
  prompt says what it wants to do ("Wants to run: npm test"), and a finished
  turn shows the first line of the answer. Codex reports finished turns
  through its `notify` program. Other agents are watched for their output going
  quiet. First-run questions such as "trust this folder?" are caught too.
- **Subagents stay invisible.** An agent's own subagents run inside its session,
  and you only see the results.
- **Keyboard first.** `SUPER + A` for the list, `SUPER + ALT + A` for a new task.
  Arrow keys, Enter and single letters do the rest.

## Omarchy

```bash
git clone https://github.com/ninepointlabs/speakeasy ~/Projects/speakeasy
cd ~/Projects/speakeasy
./install.sh            # copies the plugin, enables it on the bar, links ~/.local/bin/speakeasy
```

Then add keybindings to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + A", "Speakeasy tasks", "speakeasy ui")
o.bind("SUPER + ALT + A", "Speakeasy new task", "speakeasy ui new")
```

The bar chip is a cocktail glass. `!2` in the urgent colour means two tasks
need you, `✓1` means one finished that you haven't looked at yet, and a plain
number counts the tasks still working.

**Task list:** `↑↓` pick · `Enter` open the terminal · `n` new task ·
`p` peek at the screen without opening it · `x` stop (or remove, if finished),
press again to confirm · `c` clear finished tasks · `Esc` close.

**New task:** `←→` choose agent, `Tab` to the model row, `←→` choose model,
then title, description (Enter adds a line) and folder. `Ctrl+Enter` starts it
from anywhere in the form, and `Esc` goes back. Speakeasy remembers the last
agent, model and folder you used.

## Any other Linux

Everything runs through the `speakeasy` command, so all you need is Python 3
and tmux. `notify-send` adds notifications; any terminal emulator works.

```bash
./install.sh --cli
speakeasy new -i                     # asks for agent, model, title, description, folder
speakeasy new -a claude -m opus -t "Fix login" -p "The redirect after login loops…" -C ~/code/app
speakeasy list                       # attention first; * marks unseen results
speakeasy open login                 # by id, id prefix or part of the title
speakeasy open next                  # the task that most needs you
speakeasy peek login -n 20
speakeasy send login "yes, go ahead" # type a line into the task
speakeasy stop login | rm login | clear
speakeasy agents                     # which agents are installed, which models
```

Bind `speakeasy ui new` and `speakeasy ui` to keys in your desktop. Without the
Omarchy shell they open a terminal with the interactive prompts or the list.

## Agents

| Agent        | Models offered                     | How Speakeasy knows its state |
|--------------|------------------------------------|-------------------------------|
| Claude Code  | default, fable, opus, sonnet, haiku | hooks (approval, done, working) |
| Codex        | default                            | `notify` (turn finished) + quiet screen |
| Gemini (Antigravity CLI, `agy`) | whatever `agy models` lists for your account, refreshed every 6 hours | quiet screen |
| opencode     | default                            | quiet screen |
| Cursor Agent | default, composer-2.5, composer-2.5-fast, gpt-5.5, sonnet-4, opus | quiet screen |
| Crush        | default                            | quiet screen; the prompt is typed in |

`speakeasy models` prints every agent's list; `speakeasy models antigravity
--refresh` asks Antigravity again right away. Google's older Gemini CLI is no
longer listed by default; add it in the config if you want it back.

Add models or agents in `~/.config/speakeasy/config.json`:

```json
{
  "defaultCwd": "~/Projects",
  "terminal": "ghostty -e",
  "quietSeconds": 20,
  "notify": true,
  "agents": {
    "codex": { "models": ["", "gpt-5.5", "gpt-5.5-codex"] },
    "aider": { "name": "Aider", "bin": "aider", "modelFlag": "--model", "prompt": "flag:--message", "models": [""] }
  }
}
```

`prompt` is `arg` (the prompt is the last argument), `flag:<name>`, or `keys`
(typed into the agent once its screen settles). `terminal` is a command prefix;
the tmux attach command is appended. Left empty, Speakeasy uses
`xdg-terminal-exec`, then the first common terminal it finds.

## How it works

- Tasks live in `~/.local/state/speakeasy/tasks/<id>.json`. The CLI touches
  `~/.local/state/speakeasy/rev` on every change, and the panel watches that
  file, so the bar updates the moment a hook fires.
- Each task runs in `tmux -L speakeasy`, in a session called `se-<id>`, with a
  small generated config (mouse on, a status line with the task name, and dead
  panes kept so you can read the final output).
- Claude Code gets its hooks through `--settings` for that session only. Your
  own settings files are left alone.
- `open` attaches a terminal to the session. On Hyprland it focuses a window
  that is already showing the task instead of opening a second one.

## Tests

```bash
python3 -m unittest discover -s test -v
```

## Licence

MIT
