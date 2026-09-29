#!/bin/bash
# Install Speakeasy from this checkout.
#
#   ./install.sh            Omarchy: copy the plugin into
#                           ~/.config/omarchy/plugins/ninepointlabs.speakeasy,
#                           enable it on the bar, and link ~/.local/bin/speakeasy.
#   ./install.sh --cli      Any Linux: only link ~/.local/bin/speakeasy.
#
# It never overwrites anything it did not put there itself: an existing
# plugin folder must be an earlier copy made by this script (owned by you,
# not a symlink, not a git checkout from `omarchy plugin add`), and an
# existing ~/.local/bin/speakeasy must be the link this script made.
# The new copy is staged, validated, and swapped in with a rename that
# rolls back on failure. Re-run after pulling changes.

set -euo pipefail

PLUGIN_ID="ninepointlabs.speakeasy"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/speakeasy"
CLI_ONLY=0

die() { echo "install: $*" >&2; exit 1; }

case "${1:-}" in
  --cli) CLI_ONLY=1 ;;
  "") ;;
  -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option '$1'" ;;
esac

command -v tmux >/dev/null 2>&1 || echo "install: warning: tmux is not installed; Speakeasy needs it" >&2

# ~/.local/bin/speakeasy may be replaced only if it is a link this script made.
# Checked before anything is written, so a refusal changes nothing.
if [[ -e $LINK || -L $LINK ]]; then
  current=""
  [[ -L $LINK ]] && current="$(readlink "$LINK")"
  if [[ $current != "$DEST/bin/speakeasy" && $current != "$SRC/bin/speakeasy" ]]; then
    die "$LINK already exists and is not Speakeasy's link; move it aside and run again"
  fi
fi

link_cli() {
  mkdir -p "$BIN_DIR"
  ln -sfn "$1" "$LINK"
  echo "linked $LINK -> $1"
}

if [[ $CLI_ONLY -eq 1 ]] || ! command -v omarchy-shell >/dev/null 2>&1; then
  link_cli "$SRC/bin/speakeasy"
  echo "Bind keys to \`speakeasy ui new\` (new task) and \`speakeasy ui\` (task list)."
  exit 0
fi

# Refuse to write through symlinks, or over a folder that is not ours.
for part in "$HOME/.config" "$HOME/.config/omarchy" "$PLUGINS_DIR" "$DEST"; do
  [[ -L $part ]] && die "$part is a symlink; refusing to install through it"
done
if [[ -e $DEST ]]; then
  [[ -d $DEST && -O $DEST ]] || die "$DEST exists but is not a folder you own; refusing to replace it"
  [[ -e $DEST/.git ]] && die "$DEST is a git checkout (installed with \`omarchy plugin add\`); update it with \`omarchy plugin update $PLUGIN_ID\` instead"
  grep -q "\"id\": *\"$PLUGIN_ID\"" "$DEST/manifest.json" 2>/dev/null \
    || die "$DEST does not hold a Speakeasy install; refusing to replace it"
fi
mkdir -p "$PLUGINS_DIR"

# Stage beside the live folder so the swap is a rename on one filesystem.
STAGE="$(mktemp -d "$PLUGINS_DIR/.$PLUGIN_ID.stage.XXXXXXXX")"
BACKUP=""
cleanup() {
  [[ -n $STAGE ]] && rm -rf "$STAGE"
  if [[ -n $BACKUP && -d $BACKUP ]]; then
    rm -rf "$DEST"
    mv "$BACKUP" "$DEST"
    echo "install: rolled back to the previous install" >&2
  fi
}
trap cleanup EXIT

# Only what the shell needs; git history, tests and screenshots stay behind.
for asset in manifest.json BarWidget.qml Panel.qml README.md LICENSE; do
  [[ -f $SRC/$asset ]] || die "missing file: $asset"
  cp "$SRC/$asset" "$STAGE/$asset"
done
mkdir -p "$STAGE/bin"
cp "$SRC/bin/speakeasy" "$STAGE/bin/speakeasy"
chmod 755 "$STAGE" "$STAGE/bin" "$STAGE/bin/speakeasy"

if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate "$STAGE" >/dev/null || die "the staged copy failed validation; nothing was installed"
fi

if [[ -d $DEST ]]; then
  BACKUP="$(mktemp -d "$PLUGINS_DIR/.$PLUGIN_ID.prev.XXXXXXXX")"
  rmdir "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
mv "$STAGE" "$DEST"
STAGE=""
# Landed; do not roll back past this point.
[[ -n $BACKUP ]] && rm -rf "$BACKUP"
BACKUP=""
echo "installed $PLUGIN_ID to $DEST"

# Running tasks call their hooks by this path, so PATH points at the same copy.
link_cli "$DEST/bin/speakeasy"

if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  if ! omarchy plugin list --json 2>/dev/null | grep -q "\"$PLUGIN_ID\"[^}]*\"enabled\": *true"; then
    omarchy plugin enable "$PLUGIN_ID" --section right || true
  fi
fi
