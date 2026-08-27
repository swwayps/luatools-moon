#!/usr/bin/env bash
# Shared test helper: serve a directory over loopback http.
#
# The download workers now require https unless the caller passes ALLOW_HTTP=1,
# and they refuse file:// outright (it is not a download, and accepting it made
# the worker a local-file reader). Tests that used file:// fixtures therefore
# serve them over a real loopback http server and opt in with ALLOW_HTTP=1, which
# also exercises the actual transfer path rather than a special case.
#
# Usage:
#   . "$(dirname "$0")/testlib-httpd.sh"
#   start_static_server "$TMP"        # sets HTTPD_URL, HTTPD_PID
#   ... ALLOW_HTTP=1 worker "$HTTPD_URL/file.zip" ...
#   stop_static_server                # or rely on the caller's trap

HTTPD_PID=""
HTTPD_URL=""
HTTPD_TMP=""

start_static_server() {
	local root="$1"
	HTTPD_TMP="$(mktemp -d)"
	local script="$HTTPD_TMP/serve.py"
	local port_file="$HTTPD_TMP/port"
	cat > "$script" <<'PY'
import functools, http.server, pathlib, sys

root = sys.argv[1]
port_file = pathlib.Path(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


handler = functools.partial(Handler, directory=root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
	python3 "$script" "$root" "$port_file" >/dev/null 2>&1 &
	HTTPD_PID=$!
	local i=0
	while [ ! -s "$port_file" ] && [ "$i" -lt 250 ]; do
		sleep 0.02
		i=$((i + 1))
	done
	local port
	port="$(cat "$port_file" 2>/dev/null)"
	[ -n "$port" ] || return 1
	HTTPD_URL="http://127.0.0.1:$port"
	return 0
}

stop_static_server() {
	[ -z "$HTTPD_PID" ] || kill "$HTTPD_PID" 2>/dev/null
	HTTPD_PID=""
	[ -z "$HTTPD_TMP" ] || rm -rf "$HTTPD_TMP"
	HTTPD_TMP=""
}
