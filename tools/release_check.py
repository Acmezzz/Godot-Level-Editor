"""Run the release checks against a fresh project copy. Python 3, no external packages."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.parse import unquote


PROJECT = Path(__file__).resolve().parents[1]
CREATE_HIDDEN = getattr(subprocess, "CREATE_NO_WINDOW", 0)
RUNTIME_ISSUE = re.compile(r"^(?:SCRIPT |USER )?ERROR:|^WARNING:", re.MULTILINE)
CHECKS = (
    ("compile", "tools/warn_scan.gd", True, r"^SCAN-DONE files=[1-9]\d* fails=0$"),
    ("unit", "tests/run_tests.gd", True, r"^TESTS-DONE passed=[1-9]\d* failed=0$"),
    ("pilot", "tools/f2_pilot.gd", True, r"^F2_PILOT_OK checks=[1-9]\d*$"),
    ("workflow", "tests/run_author_workflow.gd", False, r"^WORKFLOW-DONE failures=0$"),
    ("card", "tests/run_card_authoring.gd", False, r"^CARD-DONE failures=0$"),
    ("network", "tests/run_network_authoring.gd", False, r"^NETWORK-DONE failures=0$"),
    ("screen", "tests/run_screen_navigation_authoring.gd", False, r"^SCREEN-NAV-DONE failures=0$"),
)


def run_godot(godot, project, output, env, name, flags, marker=None):
    logfile = output / f"{name}.log"
    console = output / f"{name}.console.log"
    if logfile.exists():
        logfile.unlink()
    code = "timeout"
    with console.open("wb") as pipe:
        try:
            code = subprocess.run(
                [godot, "--path", str(project), "--log-file", str(logfile), *flags],
                stdout=pipe, stderr=subprocess.STDOUT, env=env, timeout=220,
                creationflags=CREATE_HIDDEN,
            ).returncode
        except subprocess.TimeoutExpired:
            pass
    report = logfile.read_text(encoding="utf-8", errors="replace") if logfile.exists() else ""
    console_report = console.read_text(encoding="utf-8", errors="replace")
    summary = re.search(marker, report, re.MULTILINE) if marker else None
    issues = list(dict.fromkeys(
        line for line in (report + "\n" + console_report).splitlines() if RUNTIME_ISSUE.match(line)
    ))
    reasons = []
    if code != 0:
        reasons.append(f"exit={code}")
    if not report:
        reasons.append("no Godot log")
    if marker and not summary:
        reasons.append("missing passing summary")
    reasons.extend(issues)
    if reasons and not issues and not summary:
        reasons.extend(line for line in report.splitlines() if "FAIL" in line)
    print(f"{name}: {'FAIL ' + '; '.join(reasons) if reasons else summary[0] if summary else 'PASS'}", flush=True)
    return not reasons


def godot_diagnostics(godot, project, output, env):
    """Use the editor's language server; loading a script from the game runner misses analyzer warnings."""
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    files = sorted((project / "src").rglob("*.gd")) + sorted((project / "tests").glob("*.gd"))
    files += sorted((project / "tools").rglob("*.gd"))
    result = {}
    with (output / "language-server.console.log").open("wb") as console, subprocess.Popen(
        [godot, "--path", str(project), "--headless", "--editor", "--lsp-port", str(port),
         "--log-file", str(output / "language-server.log")],
        stdout=console, stderr=subprocess.STDOUT, env=env, creationflags=CREATE_HIDDEN,
    ) as process:
        try:
            conn = connect(process, port)
            with conn, conn.makefile("rb") as stream:
                conn.settimeout(30)

                def send(method, params, message_id=None):
                    message = {"jsonrpc": "2.0", "method": method, "params": params}
                    if message_id is not None:
                        message["id"] = message_id
                    data = json.dumps(message).encode()
                    conn.sendall(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)

                def receive():
                    headers = {}
                    while (line := stream.readline()) != b"\r\n":
                        if not line:
                            raise EOFError("Godot language server disconnected")
                        key, value = line.split(b":", 1)
                        headers[key.lower()] = value.strip()
                    return json.loads(stream.read(int(headers[b"content-length"])))

                def read_through(message_id):
                    while True:
                        message = receive()
                        if message.get("method") == "textDocument/publishDiagnostics":
                            params = message["params"]
                            result[unquote(params["uri"]).casefold()] = params["diagnostics"]
                        if message.get("id") == message_id:
                            if "error" in message:
                                raise RuntimeError(str(message["error"]))
                            return

                send("initialize", {"processId": os.getpid(), "rootUri": project.as_uri(), "capabilities": {}}, 1)
                read_through(1)
                send("initialized", {})
                for i, path in enumerate(files, 2):
                    doc = {"uri": path.as_uri()}
                    send("textDocument/didOpen", {"textDocument": {
                        **doc, "languageId": "gdscript", "version": 1, "text": path.read_text(encoding="utf-8-sig"),
                    }})
                    send("textDocument/documentSymbol", {"textDocument": doc}, i)
                    read_through(i)
        finally:
            process.terminate()

    rows = []
    missing = []
    for path in files:
        name = path.relative_to(project).as_posix()
        key = unquote(path.as_uri()).casefold()
        if key not in result:
            missing.append(name)
            continue
        for issue in result[key]:
            line = issue["range"]["start"]["line"] + 1
            rows.append(f"{name}:{line}: {issue['message']}")
    missing_rows = [f"No diagnostics response: {name}" for name in missing]
    summary = f"diagnostics: files={len(files) - len(missing)}/{len(files)} issues={len(rows)}"
    (output / "diagnostics.log").write_text("\n".join([summary, *rows, *missing_rows]) + "\n", encoding="utf-8")
    print(summary, flush=True)
    return bool(files) and not rows and not missing


def connect(process, port):
    until = time.monotonic() + 20
    while time.monotonic() < until and process.poll() is None:
        try:
            return socket.create_connection(("127.0.0.1", port), 0.3)
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("Godot language server did not start")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Path to the Godot editor executable")
    parser.add_argument("--logs", type=Path, required=True, help="Output directory for this run's logs")
    args = parser.parse_args()
    godot, output = str(Path(args.godot).resolve(strict=True)), args.logs.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bird-release-") as temporary:
        workspace = Path(temporary)
        project = workspace / "editor"
        project.mkdir()
        for folder in ("src", "tests", "tools", "addons"):
            shutil.copytree(PROJECT / folder, project / folder,
                            ignore=shutil.ignore_patterns(".godot", "__pycache__", "shots"))
        for name in ("project.godot", "icon.svg"):
            shutil.copy2(PROJECT / name, project / name)
        # Keep editor settings, test data and game receipts away from real projects.
        env = dict(os.environ, APPDATA=str(workspace / "appdata"), XDG_DATA_HOME=str(workspace / "data"))
        if not run_godot(godot, project, output, env, "import", ["--headless", "--editor", "--import"]):
            return 1
        try:
            passed = godot_diagnostics(godot, project, output, env)
        except (OSError, EOFError, RuntimeError, ValueError) as error:
            print(f"diagnostics: FAIL {error}", flush=True)
            passed = False
        for name, script, headless, marker in CHECKS:
            mode = ["--headless"] if headless else ["--rendering-method", "gl_compatibility", "--audio-driver", "Dummy"]
            if not run_godot(godot, project, output, env, name, [*mode, "--script", f"res://{script}"], marker):
                passed = False
    print(f"Release checks {'PASSED' if passed else 'FAILED'}. Logs: {output}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
