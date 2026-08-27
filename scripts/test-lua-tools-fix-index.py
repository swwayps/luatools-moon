#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import subprocess
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "refresh-lua-tools-fix-index.py"
spec = importlib.util.spec_from_file_location("lua_tools_fix_index_refresh", MODULE_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("FAIL generator module could not be loaded")
module = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(module)
except FileNotFoundError as error:
    raise SystemExit(f"FAIL generator module is missing: {error}")


FIX_VOICES = "33333333-3333-4333-8333-333333333333"
FIX_DENUVO = "11111111-1111-4111-8111-111111111111"
FIX_OLD = "44444444-4444-4444-8444-444444444444"


class FixtureHandler(BaseHTTPRequestHandler):
    listing_status = 200
    requests = []

    def log_message(self, *_args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).requests.append(self.path)
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/denuvo/listings":
            if type(self).listing_status != 200:
                self.reply(type(self).listing_status, {"error": "offline"})
                return
            self.reply(200, {"games": [
                {"appid": "10", "name": "Ten", "fixCount": 2, "tags": []},
                {"appid": "20", "name": "Twenty", "fixCount": 1, "tags": []},
                {"appid": "30", "name": "Thirty", "fixCount": 1, "tags": []},
            ], "tags": []})
            return
        if parsed.path == "/api/denuvo/fixes":
            appid = urllib.parse.parse_qs(parsed.query).get("appid", [""])[0]
            if appid == "10":
                self.reply(200, {"appid": "10", "name": "Ten", "fixes": [
                    {"id": FIX_DENUVO, "title": "DenuvOwO", "hasManifest": True,
                     "hasFix": True, "manifestFilename": "10-old.lua",
                     "createdAt": "2026-08-01T00:00:00Z",
                     "tags": [{"slug": "denuvowo", "name": "DenuvOwO"}]},
                    {"id": FIX_VOICES, "title": "Recommended", "hasManifest": True,
                     "hasFix": True, "manifestFilename": "10.lua",
                     "createdAt": "2026-08-02T00:00:00Z",
                     "tags": [{"slug": "voices38-crack", "name": "voices38 (crack)"}]},
                ]})
                return
            if appid == "20":
                self.reply(200, {"appid": "20", "name": "Twenty", "fixes": [
                    {"id": FIX_DENUVO, "title": "Archive", "hasManifest": False,
                     "hasFix": True, "manifestFilename": None,
                     "createdAt": "2026-08-01T00:00:00Z",
                     "tags": [{"slug": "online-fix", "name": "Online Fix"}]},
                ]})
                return
            if appid == "30":
                self.reply(503, {"error": "temporary"})
                return
        self.reply(404, {"error": "missing"})


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print(f"ok   {name}")


lua_categories = subprocess.run(
    [
        "luajit",
        "-e",
        'package.path="plugin/backend/?.lua;"..package.path; '
        'local d=require("lua_tools_domain"); '
        'for _,n in ipairs(d.category_names()) do '
        'print(n.."\\t"..d.category_rank(n)) end',
    ],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
)
lua_category_rank = {
    name: int(rank)
    for name, rank in (
        line.split("\t", 1)
        for line in lua_categories.stdout.splitlines()
        if "\t" in line
    )
}
check("G0 Python and Lua use the same category ranks",
      module.CATEGORY_RANK == lua_category_rank)


server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base_url = f"http://127.0.0.1:{server.server_address[1]}/api/denuvo"

try:
    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory) / "index.json"
        previous = {
            "schema": 1,
            "generatedAt": "2026-08-01T00:00:00Z",
            "source": "fixture",
            "apps": {"30": {
                "fixId": FIX_OLD,
                "title": "Previous",
                "category": "bypass",
                "createdAt": "2026-07-01T00:00:00Z",
                "manifestFilename": "30.lua",
                "hasFix": True,
            }},
        }
        output.write_text(json.dumps(previous), encoding="utf-8")

        result = module.refresh_index(output, base_url=base_url, workers=3,
                                      retries=1, timeout=1.0)
        document = json.loads(output.read_text(encoding="utf-8"))
        check("G1 refresh succeeds with a partial detail failure", result["success"])
        check("G2 only manifest-bearing fresh entries are added", "20" not in document["apps"])
        check("G3 ranking chooses voices38 before DenuvOwO",
              document["apps"]["10"]["fixId"] == FIX_VOICES)
        check("G4 failed details retain the last valid manifest entry",
              document["apps"]["30"]["fixId"] == FIX_OLD)
        check("G5 generated entries never contain URLs or credentials",
              all("url" not in json.dumps(entry).lower()
                  and "token" not in json.dumps(entry).lower()
                  for entry in document["apps"].values()))

        before = output.read_bytes()
        FixtureHandler.listing_status = 503
        failed = module.refresh_index(output, base_url=base_url, workers=1,
                                      retries=0, timeout=1.0)
        check("G6 a failed catalogue refresh reports failure", not failed["success"])
        check("G7 a failed refresh never replaces the prior index",
              output.read_bytes() == before)
finally:
    server.shutdown()
    server.server_close()

print("ALL LUA.TOOLS FIX INDEX GENERATOR CHECKS PASSED")
