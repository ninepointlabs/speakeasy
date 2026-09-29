#!/bin/bash
# Install Speakeasy.
#
#   ./install.sh            Omarchy: copy the plugin, enable it on the bar,
#                           and put `speakeasy` on PATH.
#   ./install.sh --cli      Any Linux: only put `speakeasy` on PATH.
#
# Re-run after pulling changes. Service code is not hot-reloaded reliably;
# run `omarchy restart shell` if the panel looks stale.

set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bindir="$HOME/.local/bin"
mkdir -p "$bindir"

command -v tmux >/dev/null 2>&1 || echo "warning: tmux is not installed; Speakeasy needs it (omarchy pkg add tmux)" >&2

if [[ "${1:-}" == "--cli" ]] || ! command -v omarchy-shell >/dev/null 2>&1; then
  ln -sfn "$src/bin/speakeasy" "$bindir/speakeasy"
  echo "Linked $bindir/speakeasy -> $src/bin/speakeasy"
  echo "Bind a key to \`speakeasy ui new\` (new task) and \`speakeasy ui\` (task list)."
  exit 0
fi

id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$src/manifest.json")"
dest="$HOME/.config/omarchy/plugins/$id"

mkdir -p "$dest/bin"
# Only ship what the shell needs; git history and tests stay behind.
for entry in manifest.json BarWidget.qml Panel.qml README.md LICENSE; do
  [[ -e "$src/$entry" ]] && cp "$src/$entry" "$dest/"
done
cp "$src/bin/speakeasy" "$dest/bin/speakeasy"
chmod +x "$dest/bin/speakeasy"

# Running tasks call hooks by the script's path, so PATH points at the
# installed copy, the same one the panel runs.
ln -sfn "$dest/bin/speakeasy" "$bindir/speakeasy"

if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  if ! omarchy plugin list --json 2>/dev/null | grep -q "\"$id\"[^}]*\"enabled\": *true"; then
    omarchy plugin enable "$id" --section "${1:-right}" || true
  fi
fi

echo "Installed $id to $dest"
echo "Linked $bindir/speakeasy"
