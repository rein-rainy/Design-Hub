#!/bin/bash
# Design Hub — install the Illustrator CEP extension for local development.
#
# Enables CEP PlayerDebugMode (so unsigned dev extensions load) and symlinks
# this folder into the user's CEP extensions directory.
#
#   ./install.sh          install (symlink + debug mode)
#   ./install.sh uninstall remove the symlink
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="$HOME/Library/Application Support/Adobe/CEP/extensions"
LINK="$EXT_DIR/com.designhub.illustrator"

if [ "$1" = "uninstall" ]; then
  rm -f "$LINK"
  echo "Removed $LINK"
  exit 0
fi

# Enable unsigned-extension loading for every CEP runtime Illustrator might use.
for v in 9 10 11 12 13; do
  defaults write "com.adobe.CSXS.$v" PlayerDebugMode 1 2>/dev/null || true
done
killall cfprefsd 2>/dev/null || true

mkdir -p "$EXT_DIR"
rm -f "$LINK"
ln -s "$SRC" "$LINK"

echo "Installed:"
echo "  $LINK -> $SRC"
echo
echo "PlayerDebugMode enabled for CEP 9–13."
echo "Restart Illustrator, then open: Window > Extensions > Design Hub"
