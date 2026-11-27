"""Exercise the public HTTP API against the exported editor, including image attachments."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def fixture(base, godot):
    write_json(base / "editor/editor_manifest.json", {
        "projectName": "MCP 集成验收",
        "startup": {"maps": True, "screens": True},
        "mapOutputs": {"next": {"name": "出口", "maps": True}},
        "assets": [
            {"id": "floor", "kind": "scene", "shape": "tile", "atlas": "tile.png", "cell": 16},
            {"id": "terminal", "kind": "entity", "code": "TERM", "thumb": "tile.png", "visual": {}},
        ],
        "functions": {"scene": {"name": "Scene", "code": "SCNE", "timebase": "seconds", "steps": True, "fields": []}},
        "steps": {"cue": {"name": "演出标记", "code": "CUE0", "fields": []}},
        "audio": [{"id": "theme", "name": "Theme", "code": "AUD0", "path": "theme.wav"}],
        "preview": {"version": 1, "executable": godot, "capabilities": [
            "generateMap", "mapFrame", "worldFrame", "screenLayout", "timelineFrame", "playtestFrame"],
            "args": ["--headless", "--path", str(base), "--"]},
        "mapGenerators": {"room": {"fields": [
            {"id": "width", "kind": "input", "type": "int", "min": 8, "max": 30, "default": 12}]}},
        "playtest": {"executable": godot, "args": ["--path", str(base), "--rendering-method", "gl_compatibility",
                                                   "--audio-driver", "Dummy", "--resolution", "300x200", "--"],
                     "projectEntry": True, "mapEntry": True, "viewEntry": True, "viewDraft": True,
                     "entryFunctions": ["scene"], "report": True, "captureFrames": True},
    })
    (base / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="MCP Fixture"\nrun/main_scene="res://main.tscn"\n', encoding="utf-8")
    (base / "main.tscn").write_text(
        '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="res://game.gd" id="1"]\n'
        '[node name="Fixture" type="Node2D"]\nscript = ExtResource("1")\n', encoding="utf-8")
    script = base / "game.gd"
    script.write_bytes((ROOT / "tests/mcp_fixture_game.gd.txt").read_bytes())
    # Build a 16x16 PNG without an optional imaging dependency.
    import zlib
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    (base / "tile.png").write_bytes(b"\x89PNG\r\n\x1a\n" +
        chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
        chunk(b"IDAT", zlib.compress((b"\0" + b"\x56\xaa\x33" * 16) * 16)) + chunk(b"IEND", b""))
    with wave.open(str(base / "theme.wav"), "wb") as stream:
        stream.setparams((1, 2, 8000, 0, "NONE", ""))
        stream.writeframes(struct.pack("<8000h", *([1000, -1000, 5000, -5000] * 2000)))
    return script


def run(editor, godot, logs):
    with tempfile.TemporaryDirectory(prefix="bird-mcp-") as directory:
        root = Path(directory)
        game = root / "Fixture"
        script = fixture(game, godot)
        script_digest = hashlib.sha256(script.read_bytes()).hexdigest()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = os.environ | {"APPDATA": str(root / "profile"), "BIRD_MCP_TOKEN": "local-test-secret"}
        flags = ["--path", str(ROOT)] if Path(editor) == Path(godot) else []
        log_file = logs / "editor-mcp.log"
        with (logs / "editor-mcp.console.log").open("wb") as console, subprocess.Popen(
            [editor, *flags, "--rendering-method", "gl_compatibility", "--audio-driver", "Dummy",
             "--resolution", "1200x800", "--log-file", str(log_file), "--",
             f"--bird-mcp={port}", f"--bird-project={game.as_posix()}"],
            env=env, stdout=console, stderr=subprocess.STDOUT,
        ) as process:
            managed = False
            try:
                def rpc(method, params=None, response=True, token=True):
                    message = {"jsonrpc": "2.0", "method": method}
                    if response:
                        message["id"] = 1
                    if params is not None:
                        message["params"] = params
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp",
                        json.dumps(message, ensure_ascii=False).encode(),
                        {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                         **({"Authorization": "Bearer local-test-secret"} if token else {})})
                    with urllib.request.urlopen(req, timeout=65) as res:
                        if not response:
                            assert res.status == 202
                            return None
                        obj = json.load(res)
                        assert "error" not in obj, obj
                        return obj["result"]
                def call(tool_name, expect_error=False, **args):
                    result = rpc("tools/call", {"name": tool_name, "arguments": args})
                    data = result["structuredContent"]
                    assert result["isError"] == expect_error, (tool_name, args, data)
                    return data, [row for row in result["content"] if row["type"] in ["image", "audio"]]
                def png(media, name, size=None):
                    assert media["type"] == "image" and media["mimeType"] == "image/png", media.keys()
                    png_bytes = base64.b64decode(media["data"])
                    assert png_bytes[:8] == b"\x89PNG\r\n\x1a\n"
                    if size:
                        assert struct.unpack(">II", png_bytes[16:24]) == size
                    (logs / f"{name}.png").write_bytes(png_bytes)
                    return png_bytes
                for _ in range(150):
                    assert process.poll() is None, log_file.read_text(encoding="utf8")
                    try:
                        initialized = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                                           "clientInfo": {"name": "acceptance", "version": "1"}})
                        break
                    except urllib.error.HTTPError as ex:
                        raise AssertionError((ex.code, ex.read())) from ex
                    except urllib.error.URLError as ex:
                        last_error = ex
                        time.sleep(0.1)
                else:
                    raise AssertionError(("MCP did not start", last_error))
                assert initialized["serverInfo"]["name"] == "bird-editor"
                assert initialized["serverInfo"]["title"] == "2D游戏编辑器"
                rpc("notifications/initialized", response=False)
                try:
                    rpc("ping", token=False)
                    raise AssertionError("missing bearer token accepted")
                except urllib.error.HTTPError as ex:
                    assert ex.code == 401, ex
                tools = {row["name"] for row in rpc("tools/list")["tools"]}
                assert tools == {"describe_project", "query_content", "manage_draft", "apply_changes",
                    "generate_map", "capture_editor", "render_preview", "preview_asset", "validate", "playtest", "publish"}
                info, _ = call("describe_project")
                assert info["manifest"].get("projectName") == "MCP 集成验收", info
                home = call("capture_editor")[1]
                png(home[0], "window")
                draft = call("manage_draft", action="create", name="内容验收")[0]["id"]
                assert call("generate_map")[0]["available"]
                gen, _ = call("generate_map", draft=draft, revision=0, generator="room", name="生成地图",
                              parameters={"width": 18})
                board = gen["map"]
                cut, _ = call("apply_changes", draft=draft, revision=1, operations=[
                    {"op": "map.create", "name": "图组", "width": 12, "height": 10, "projection": "isometric", "as": "draw"},
                    {"op": "layer.put", "map": board, "as": "layer", "data": {"name": "装饰"}},
                    {"op": "tiles.set", "map": board, "layer": "$layer",
                     "cells": [{"x": 3, "y": 3, "asset": "floor", "atlas": [0, 0]}]},
                    {"op": "collision.set", "map": board, "cells": [{"x": 5, "y": 4, "type": "solid"}]},
                    {"op": "instance.put", "map": board, "as": "terminal",
                     "data": {"asset": "terminal", "layer": "$layer", "x": 4, "y": 4}},
                    {"op": "content.put", "function": "scene", "as": "content", "data": {
                        "name": "两帧演出", "steps": [{"step": "CUE0", "at": 0.25, "duration": 0.5, "fields": {}}]}},
                    {"op": "binding.put", "map": board, "instance": "$terminal", "function": "scene",
                     "as": "binding", "data": {"content": "$content"}},
                    {"op": "group.put", "data": {"name": "共享前景", "drawingMap": "$draw", "maps": [board], "drawOrder": 3}},
                    {"op": "view.put", "view": "main", "data": {"name": "主屏幕", "layout": {"elements": [
                        {"id": "title", "kind": "text", "anchors": [0.1, 0.2, 0.9, 0.4], "text": "画面"}]}}},
                    {"op": "startup.set", "data": {"target": {"map": board}}},
                ])
                assert cut["revision"] == 2
                ids = cut["aliases"]
                assert call("manage_draft", action="diff", draft=draft)[0]["changed"]["contents"]
                rev = call("manage_draft", action="undo", draft=draft, revision=2)[0]["revision"]
                assert call("query_content", kind="objects", draft=draft, map=board)[0]["total"] == 0
                rev = call("manage_draft", action="redo", draft=draft, revision=rev)[0]["revision"]
                assert call("query_content", kind="objects", draft=draft, map=board)[0]["total"] == 1
                assert call("query_content", kind="groups", draft=draft, map=board)[0]["drawings"][0]["drawOrder"] == 3
                candidates, _ = call("query_content", kind="candidates", draft=draft, domains={"maps": True, "contentTypes": ["scene"]})
                assert any(row["target"].get("content") == ids["$content"] for row in candidates["items"])
                fields, _ = call("query_content", kind="candidates", draft=draft, map=board, field={"source": "layer:"})
                assert any(row["v"] == ids["$layer"] for row in fields["items"])
                assert call("query_content", kind="inbound", draft=draft, function="scene", content=ids["$content"])[0]["data"]["edges"]["instances"]
                data, _ = call("validate", draft=draft)
                assert data["valid"], data
                _, snap = call("capture_editor", target="draft_map", draft=draft, map=board, width=480, height=300)
                png(snap[0], "draft-canvas", (480, 300))
                samples, media = call("render_preview", capability="timelineFrame", draft=draft, map=board,
                    instance=ids["$terminal"], binding=ids["$binding"], function="scene", content=ids["$content"],
                    width=180, height=120, times=[0.25, 0.75])
                assert samples["frames"][0]["picks"]
                assert png(media[0], "timeline-0", (180, 120)) != png(media[1], "timeline-1", (180, 120))
                for capability in ["mapFrame", "worldFrame", "playtestFrame"]:
                    _, media = call("render_preview", capability=capability, draft=draft, map=board,
                                    width=180, height=120)
                    png(media[0], capability, (180, 120))
                _, media = call("render_preview", capability="screenLayout", draft=draft, view="main",
                                width=180, height=120)
                png(media[0], "screenLayout", (180, 120))
                _, media = call("preview_asset", asset="floor", cell=[0, 0])
                png(media[0], "asset", (16, 16))
                audio, media = call("preview_asset", audio="AUD0", start=0.2, duration=0.4)
                assert audio["waveform"] and media[0]["mimeType"] == "audio/wav"
                assert base64.b64decode(media[0]["data"])[:4] == b"RIFF"
                planned, _ = call("publish", previewOnly=True, draft=draft, revision=rev)
                assert len(planned["entries"]) == 4 and not (game / "maps").exists()
                done, _ = call("publish", draft=draft, revision=rev)
                assert len(done["files"]) == 4
                assert (game / "maps/生成地图.json").is_file()
                assert hashlib.sha256(script.read_bytes()).hexdigest() == script_digest
                original = call("query_content", kind="map", map=board)[0]["data"]
                size_draft = call("manage_draft", action="create", name="尺寸检查")[0]["id"]
                for width, height in [(0, -1), (1.5, "4")]:
                    invalid, _ = call("apply_changes", draft=size_draft, revision=0, expect_error=True, operations=[
                        {"op": "map.patch", "map": board, "data": {"meta": {"w": width, "h": height}}}])
                    assert {issue["path"] for issue in invalid["issues"]} >= {"meta.w", "meta.h"}, invalid
                assert call("manage_draft", action="open", draft=size_draft)[0]["revision"] == 0
                call("apply_changes", draft=size_draft, revision=0, operations=[
                    {"op": "map.patch", "map": board, "data": {"meta": {"w": 2, "h": 2}}}])
                resized = call("query_content", kind="map", draft=size_draft, map=board)[0]["data"]
                assert (resized["meta"]["w"], resized["meta"]["h"]) == (2, 2), resized["meta"]
                assert resized["tiles"] == original["tiles"] and resized["collision"] == original["collision"]
                _, media = call("capture_editor", target="canvas", map=board, instance=ids["$terminal"])
                png(media[0], "published-canvas")
                live = call("query_content", kind="live_map")[0]["data"]
                assert live["meta"]["code"] == board and any(row["code"] == ids["$terminal"] for row in live["objects"])
                popups = {"groups": "groups", "screens": "screens", "world": "world", "viewports": "viewports",
                          "startup": "startup", "flow": "flow", "library": "library", "playtest": "playtest-settings"}
                for panel, name in popups.items():
                    paths, _ = call("capture_editor", panel=panel, target="tree")
                    if panel == "flow":
                        assert any(row["text"] == "地图内容与出口" for row in paths["controls"])
                    _, media = call("capture_editor", target="popup")
                    png(media[0], f"popup-{name}")
                tree, _ = call("capture_editor", target="tree")
                assert len(tree["controls"]) > 10
                control = next(row["path"] for row in tree["controls"] if row["class"] == "Label"
                               and row["text"] and min(row["rect"][2:]) > 5)
                png(call("capture_editor", target="control", control=control)[1][0], "control")
                _, media = call("capture_editor", panel="timeline", function="scene", content=ids["$content"], time=0.5)
                png(media[0], "timeline-editor")
                call("playtest", action="start", entry="map", target={"map": board})
                managed = True
                for _ in range(60):
                    state, _ = call("playtest", action="status")
                    if state["report"].get("status") == "ready":
                        break
                    time.sleep(0.05)
                else:
                    raise AssertionError(state)
                _, media = call("playtest", action="capture", width=180, height=120)
                png(media[0], "live-game", (180, 120))
                assert call("playtest", action="stop")[0]["stopped"]
                managed = False
                conflict = call("manage_draft", action="create", name="冲突检查")[0]["id"]
                call("apply_changes", draft=conflict, revision=0, operations=[
                    {"op": "map.patch", "map": board, "data": {"spawn": [3, 3]}}])
                path = game / "maps/生成地图.json"
                path.write_bytes(path.read_bytes() + b"\n")
                call("publish", previewOnly=True, draft=conflict, revision=1, expect_error=True)
                call("publish", draft=conflict, revision=1, expect_error=True)
                blocked = call("manage_draft", action="create")[0]["id"]
                call("apply_changes", draft=blocked, revision=0, operations=[
                    {"op": "content.delete", "function": "scene", "content": ids["$content"]}])
                assert not call("validate", draft=blocked)[0]["valid"]
                call("publish", draft=blocked, revision=1, expect_error=True)
                # Legacy maps must be rejected at load time with their original validation reason.
                legacy = json.loads(path.read_text(encoding="utf-8"))
                legacy.update(version=5, collision=[[5, 4]])
                legacy["meta"].update(code="OLD5", name="旧碰撞地图")
                (game / "maps/旧碰撞地图.json").write_text(json.dumps(legacy), encoding="utf-8")
                null_tiles = json.loads(path.read_text(encoding="utf-8"))
                null_tiles["meta"].update(code="NULL", name="空瓦片表")
                null_tiles["tiles"] = None
                (game / "maps/空瓦片表.json").write_text(json.dumps(null_tiles), encoding="utf-8")
                check = call("manage_draft", action="create")[0]["id"]
                call("apply_changes", draft=check, revision=0, expect_error=True, operations=[
                    {"op": "collision.set", "map": "OLD5", "cells": [{"x": 5, "y": 4, "remove": True}]}])
                assert call("manage_draft", action="open", draft=check)[0]["revision"] == 0
                invalid, _ = call("validate")
                assert any(issue["path"] == "maps.旧碰撞地图.collision[0]" and
                           "migrate_project.gd" in issue["message"] for issue in invalid["issues"]), invalid
                assert any(issue["path"] == "maps.空瓦片表.tiles" for issue in invalid["issues"]), invalid
                print("MCP-DONE tools=11 publish=ok capture=ok playtest=ok conflict=ok map_patch=ok live_map=ok", flush=True)
            finally:
                if managed:
                    try:
                        call("playtest", action="stop")
                    except Exception:
                        pass
                process.terminate()
                process.wait(timeout=10)
        log = log_file.read_text(encoding="utf-8", errors="replace")
        assert "SCRIPT ERROR:" not in log and "\nERROR:" not in log and "\nWARNING:" not in log, log


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", required=True, help="Exported 2D游戏编辑器.exe (or Godot for a source run)")
    parser.add_argument("--godot", required=True, help="Godot executable for the isolated game fixture")
    parser.add_argument("--logs", required=True, type=Path)
    config = parser.parse_args()
    config.logs = config.logs.resolve()
    config.logs.mkdir(parents=True, exist_ok=True)
    run(str(Path(config.editor).resolve()), str(Path(config.godot).resolve()), config.logs)
