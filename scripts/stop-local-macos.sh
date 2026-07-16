#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pid_file="$root/.dev-state/mynas.pid"

if [ ! -f "$pid_file" ]; then
	echo "Local MyNAS is not running."
	exit 0
fi

pid=$(cat "$pid_file")
if kill -0 "$pid" 2>/dev/null; then
	kill "$pid"
	echo "Stopped local MyNAS (PID=$pid)."
else
	echo "Removed stale MyNAS PID file (PID=$pid)."
fi
rm -f "$pid_file"
