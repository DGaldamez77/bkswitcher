#!/bin/zsh

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

echo "Building BKSwitcher..."
swift build
if [[ $? -ne 0 ]]; then
  echo ""
  echo "Build failed."
  echo "Press Enter to close this window."
  read
  exit 1
fi

echo ""
echo "Running BKSwitcher once..."
swift run bkswitcher
run_status=$?

LATEST=$(ls -t "$HOME/Library/Caches/BKSwitcher"/wallpaper-*-photos.txt 2>/dev/null | sed -n '1p')
if [[ -n "$LATEST" ]]; then
  echo "Opening $LATEST"
  open "$LATEST"
else
  echo "No photo log found in ~/Library/Caches/BKSwitcher"
fi

echo ""
echo "Exit status: $run_status"
echo "Press Enter to close this window."
read
exit $run_status
