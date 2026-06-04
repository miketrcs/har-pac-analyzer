#!/bin/zsh
set -e
cd "$(dirname "$0")"
./build.sh
APP="dist/HAR & PAC Analyzer.app"
pkill -f pac-inspector-app 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched HAR & PAC Analyzer"
