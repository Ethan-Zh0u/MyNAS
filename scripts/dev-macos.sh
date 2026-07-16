#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
state_dir="$root/.dev-state"
data_dir="$root/dev-data"
web_dir="$root/frontend/dist"
binary="$state_dir/mynas-macos"
pid_file="$state_dir/mynas.pid"
log_file="$state_dir/mynas.log"

mkdir -p "$state_dir" "$data_dir"

if [ -f "$pid_file" ]; then
	old_pid=$(cat "$pid_file")
	if kill -0 "$old_pid" 2>/dev/null; then
		echo "Local MyNAS is already running, PID=$old_pid" >&2
		exit 1
	fi
fi

if [ ! -f "$web_dir/index.html" ]; then
	echo "Missing frontend production build. Run pnpm build in frontend first." >&2
	exit 1
fi

(cd "$root/backend" && go build -o "$binary" .)

MYNAS_ENV=development \
MYNAS_DEV_IDENTITY=1 \
MYNAS_ROOT="$data_dir" \
MYNAS_DATA_DIR="$state_dir" \
MYNAS_LISTEN=127.0.0.1:8080 \
MYNAS_WEB_DIR="$web_dir" \
nohup "$binary" >"$log_file" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$pid_file"

i=0
while [ "$i" -lt 30 ]; do
	if curl --fail --silent http://127.0.0.1:8080/api/v1/health >/dev/null; then
		echo "Local MyNAS started: http://127.0.0.1:8080/ (PID=$pid)"
		exit 0
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		break
	fi
	i=$((i + 1))
	sleep 0.2
done

kill "$pid" 2>/dev/null || true
echo "Local MyNAS health check failed. See $log_file" >&2
exit 1
