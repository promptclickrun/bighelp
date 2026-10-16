"""Checks a group chat across two real, isolated Hermes hosts (RoomLink).

Starts two stock Hermes hosts from a separate Hermes checkout, each with a
throwaway HOME and HERMES_HOME: its dashboard (`hermes serve`) for the app's
JSON-RPC, and its gateway (`hermes gateway run`) with the API server on
loopback, which serves RoomLink. Then it makes the calls the app makes to start
a group whose home is the first host, with one agent from each host: the second
host's RoomLink offer, `groups.create` with a peer target, `groups.peer.invite`
on the second host and `groups.peer.register` on the home. Last, it sends one
message to the room, and both agents answer through a scripted model.

  /tmp/hermes/.venv/bin/python Scripts/RoomLinkProbe.py --hermes /tmp/hermes/.venv/bin/hermes

With --plugin <bighelp plugin folder> both hosts run the plugin, and the
probe also opens its "who is writing" feeds during the reply: on the home for
the home's agent, and on the second host for its agent in a room homed
elsewhere (native-room-peer-typing-v1).

With --simulator-id it runs the app's own UI test instead
(AllHostsHostUITests/testGroupChatWithAnAgentFromEachHostAnswers): the app adds
both hosts, starts the group from All agents and gets both answers. Then the
probe reads the home's room to show the link and both replies. Build the app
for testing first (into --derived-data).

Run it with the Hermes checkout's own Python (it needs `websockets`).
HERMES_DISABLE_LAZY_INSTALLS=1 keeps Hermes from "finishing a source update"
into its checkout. Use a separate Hermes checkout: never the one your real
Hermes runs from. Prints protocol outcomes only, never grants or keys.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

import websockets

sys.path.insert(0, str(Path(__file__).resolve().parent))
from DirectHermesProtocolProbe import read_messages, request_status  # noqa: E402

REPLY = "Hello from this agent."
NATIVE = "/api/plugins/loopdy/native"


class ScriptedModel(BaseHTTPRequestHandler):
    """Answers every turn with plain text, so no tool or approval gets in the way."""
    calls = 0

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        ScriptedModel.calls += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
        self.end_headers()
        message = {"role": "assistant", "content": REPLY}
        if not request.get("stream"):
            self.wfile.write(json.dumps({
                "id": "fixture", "object": "chat.completion", "model": "fixture-model", "created": 1,
                "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}).encode())
            return
        # Written over a few seconds, like a real model, so "is writing" can show.
        words = [word + " " for word in REPLY.split()]
        for delta in [{"role": "assistant", "content": words[0]}, *({"content": w} for w in words[1:]), {}]:
            data = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": None if delta else "stop"}]}
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
            self.wfile.flush()
            if delta:
                time.sleep(0.8)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Host:
    """One isolated Hermes: dashboard and gateway sharing a throwaway home."""

    def __init__(self, label: str, root: Path, hermes: str, model_port: int, logs: Path, display: str | None = None,
                 plugin: Path | None = None):
        self.label = label
        self.home = root / label / "home"
        self.project = root / label / "project"
        self.home.mkdir(parents=True)
        self.project.mkdir(parents=True)
        self.dashboard_port, self.api_port = free_port(), free_port()
        self.origin = f"http://127.0.0.1:{self.dashboard_port}"
        self.token = secrets.token_urlsafe(32)
        config = {"dashboard": {"public_url": self.origin},
                  "model": {"default": "fixture-model", "provider": "custom",
                            "base_url": f"http://127.0.0.1:{model_port}/v1", "api_key": "local-synthetic-no-auth"},
                  "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(self.project)},
                  "memory": {"memory_enabled": False, "user_profile_enabled": False},
                  # Each computer has its own voice; Team Call speaks an agent with its computer's.
                  # macOS `say` keeps it local (no online voice service).
                  "tts": {"provider": "say", "providers": {"say": {
                      "type": "command", "output_format": "wav",
                      "command": f"say -v {'Daniel' if label == 'desk' else 'Samantha'} --file-format=WAVE "
                                 "--data-format=LEI16@22050 -o {output_path} -f {input_path}"}}}}
        if plugin:
            shutil.copytree(plugin, self.home / "plugins" / "loopdy",
                            ignore=shutil.ignore_patterns("tests", "__pycache__", ".git"))
            config["plugins"] = {"enabled": ["loopdy"]}
        (self.home / "config.yaml").write_text(json.dumps(config))
        self.env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
        self.env.update(
            HOME=str(self.home), HERMES_HOME=str(self.home), HERMES_DISABLE_LAZY_INSTALLS="1",
            PYTHONNOUSERSITE="1", PYTHONUNBUFFERED="1", NO_PROXY="127.0.0.1,localhost",
            HERMES_DASHBOARD_SESSION_TOKEN=self.token,
            API_SERVER_KEY=secrets.token_urlsafe(48), API_SERVER_HOST="127.0.0.1", API_SERVER_PORT=str(self.api_port),
            # Plain http is allowed only on this machine's loopback, as here.
            HERMES_ROOM_LINK_URL=f"http://127.0.0.1:{self.api_port}")
        if display:
            subprocess.run([hermes, "profile", "rename", "default", display], cwd=self.project, env=self.env,
                           check=True, timeout=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.logs = [(logs / f"{label}-serve.log").open("w"), (logs / f"{label}-gateway.log").open("w")]
        self.processes = [
            subprocess.Popen([hermes, "serve", "--host", "127.0.0.1", "--port", str(self.dashboard_port),
                              "--isolated", "--skip-build"], cwd=self.project, env=self.env,
                             stdout=self.logs[0], stderr=subprocess.STDOUT),
            subprocess.Popen([hermes, "gateway", "run"], cwd=self.project, env=self.env,
                             stdout=self.logs[1], stderr=subprocess.STDOUT),
        ]

    def wait_ready(self, timeout: float = 120) -> None:
        deadline = time.monotonic() + timeout
        while True:
            for process in self.processes:
                if process.poll() is not None:
                    raise RuntimeError(f"Hermes exited ({self.label}); see its logs")
            try:
                if request_status(self.origin, self.token)[0] == 200:
                    return
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise TimeoutError(f"Hermes not ready ({self.label})")
            time.sleep(0.5)

    def stop(self, keep_logs: Path | None = None) -> None:
        for process in self.processes:
            process.terminate()
        for process in self.processes:
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
        for log in self.logs:
            log.close()
        if keep_logs and (self.home / "logs").exists():
            shutil.copytree(self.home / "logs", keep_logs / f"{self.label}-hermes-logs", dirs_exist_ok=True)


class Native:
    """The bighelp plugin's routes, with its context ETag and request IDs."""

    def __init__(self, host: Host):
        self.host = host
        context, headers = self._call("/context")
        self.features = set(context.get("features", []))
        self.etag = headers["ETag"]

    def _call(self, path: str, body: dict | None = None):
        headers = {"X-Hermes-Session-Token": self.host.token, "Content-Type": "application/json"}
        if body is not None:
            headers.update({"If-Match": self.etag, "X-Loopdy-Request-ID": str(uuid.uuid4())})
        request = urllib.request.Request(self.host.origin + NATIVE + path, method="GET" if body is None else "POST",
                                         data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return json.load(response), response.headers
        except urllib.error.HTTPError as error:
            # The plugin's error code and words, never a credential.
            raise AssertionError(f"{self.host.label} {path}: {error.code} {error.read()[:300]!r}") from None

    def post(self, path: str, body: dict) -> dict:
        return self._call(path, body)[0]


class Feed:
    """One "who is writing" feed, polled in a thread so the room's RPC keeps going."""

    def __init__(self, native: Native, body: dict):
        self.native, self.room_id = native, body["roomId"]
        page = native.post("/groups/activity/open", body)
        self.stream, self.cursor, self.writing = page["streamId"], page["cursor"], []

    async def poll(self) -> None:
        page = await asyncio.to_thread(self.native.post, "/groups/activity/poll", {
            "roomId": self.room_id, "streamId": self.stream, "after": self.cursor, "limit": 8})
        self.cursor = page["cursor"]
        self.writing += [event["memberId"] for event in page["events"] if event["kind"] == "member.responding"]


def speak(host: Host, text: str) -> dict:
    """What Team Call asks a computer for its agent's voice (`/api/audio/speak`)."""
    request = urllib.request.Request(host.origin + "/api/audio/speak?profile=default", method="POST",
                                     data=json.dumps({"text": text}).encode(),
                                     headers={"X-Hermes-Session-Token": host.token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        return {"status": error.code, "detail": error.read()[:200].decode(errors="replace")}
    audio = str(body.get("audio") or body.get("data_url") or body.get("url") or "")
    return {"status": 200, "keys": sorted(body), "audio_prefix": audio[:24], "audio_chars": len(audio)}


class RPC:
    def __init__(self, host: Host):
        self.host = host
        self.number = 0

    async def __aenter__(self):
        endpoint = self.host.origin.replace("http://", "ws://") + "/api/ws?token=" + self.host.token
        self.ws = await websockets.connect(endpoint, max_size=8_000_000)
        async for message in read_messages(self.ws, time.monotonic() + 30):
            if message.get("method") == "event" and message.get("params", {}).get("type") == "gateway.ready":
                return self
        raise AssertionError(f"{self.host.label}: no gateway readiness")

    async def __aexit__(self, *_):
        await self.ws.close()

    async def __call__(self, method: str, params: dict, timeout: float = 60):
        self.number += 1
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params}))
        async for message in read_messages(self.ws, time.monotonic() + timeout):
            if message.get("id") == self.number:
                if "error" in message:
                    raise AssertionError(f"{self.host.label} {method}: {message['error'].get('code')} "
                                         f"{message['error'].get('message')}")
                return message["result"]
        raise AssertionError(f"{self.host.label} {method}: no answer")


async def exercise(home_host: Host, peer_host: Host, reply_timeout: float, plugin: bool = False) -> dict:
    evidence: dict = {}
    async with RPC(home_host) as home, RPC(peer_host) as peer:
        home_caps = await home("groups.capabilities", {})
        evidence["home_driver"] = home_caps["driver"]
        offer = await peer("groups.capabilities", {"profile": "default"})
        link = offer["room_link"]
        evidence["peer_room_link_enabled"] = link.get("enabled")
        assert link.get("enabled"), f"peer room link unavailable: {link.get('reason')}"
        catalog = link["catalog"]
        evidence["peer_endpoint"] = catalog["endpoint"]

        room_id = f"room-{uuid.uuid4()}"
        members = [
            {"member_id": "default", "profile": "default", "handle": "desk", "display_name": "Desk agent",
             "target": {"kind": "local", "profile": "default"}},
            {"member_id": "default-lab", "profile": "default", "handle": "lab-agent-lab", "display_name": "Lab agent",
             "target": {"kind": "peer", "peer_id": "lab", "installation_id": catalog["installation_id"],
                        "profile": "default", "capability_digest": catalog["catalog_digest"]}},
        ]
        room = (await home("groups.create", {"room_id": room_id, "name": "Across hosts", "members": members}))["room"]
        evidence["created_members"] = [m["target"]["kind"] for m in room["members"]]

        invite = await peer("groups.peer.invite", {
            "profile": "default", "room_id": room_id, "home_install_id": home_caps["authority_gateway_id"],
            "authority_gateway_id": room["authority_gateway_id"], "authority_epoch": room["authority_epoch"],
            "member_id": "default-lab"})
        evidence["invite_keys"] = sorted(invite)
        assert invite["catalog"]["catalog_digest"] == catalog["catalog_digest"], "catalog changed between offer and invite"
        registered = await home("groups.peer.register", {
            "room_id": room_id, "member_id": "default-lab", "target_url": invite["catalog"]["endpoint"]["url"],
            "catalog": invite["catalog"], "target_profile": "default", "grant": invite["grant"]}, timeout=90)
        evidence["registered"] = {k: registered[k] for k in ("registered", "mode", "transport_security")}

        state = await home("groups.state", {"room_id": room_id})
        evidence["peer_routes"] = state.get("driver_status", {}).get("peer_routes")

        feeds = []
        if plugin:
            home_native, peer_native = Native(home_host), Native(peer_host)
            evidence["peer_typing_feature"] = "native-room-peer-typing-v1" in peer_native.features
            evidence["home_room_features"] = sorted(f for f in home_native.features if "room" in f)
            feeds = [Feed(home_native, {"roomId": room_id, "include": ["member.responding"]}),
                     Feed(peer_native, {"roomId": room_id, "include": ["member.responding"], "peer": {
                         "homeInstallId": home_caps["authority_gateway_id"],
                         "members": [{"memberId": "default-lab", "profile": "default"}]}})]
        thread = f"thread-{uuid.uuid4().hex[:12]}"
        await home("groups.send", {"room_id": room_id, "event_id": f"probe-{uuid.uuid4()}",
                                   "payload": {"text": "@all say hello", "thread_id": thread}})
        replies: dict[str, str] = {}
        kinds: list[str] = []
        cursor, deadline = 0, time.monotonic() + reply_timeout
        while time.monotonic() < deadline and len(replies) < 2:
            page = await home("groups.log", {"room_id": room_id, "since_seq": cursor, "limit": 100})
            for event in page["events"]:
                kinds.append(event["kind"])
                if event["kind"] == "message.member":
                    replies[event["payload"]["member_id"]] = event["payload"]["text"]
            cursor = page["cursor"]
            for feed in feeds:
                await feed.poll()
            await asyncio.sleep(0.5)
        if feeds:
            evidence["home_feed_writing"] = sorted(set(feeds[0].writing))
            evidence["peer_feed_writing"] = sorted(set(feeds[1].writing))
        evidence["log_kinds"] = kinds
        evidence["peer_speech"] = await asyncio.to_thread(speak, peer_host, "Hello from the other computer.")
        evidence["replies_by_member"] = replies
        evidence["both_answered"] = set(replies) == {"default", "default-lab"}
    return evidence


async def read_back(home_host: Host) -> dict:
    """What the home recorded for the group the app made: its link and its replies."""
    async with RPC(home_host) as home:
        rooms = (await home("groups.list", {"limit": 50}))["rooms"]
        mixed = [room for room in rooms if any(m.get("target", {}).get("kind") == "peer" for m in room["members"])]
        assert len(mixed) == 1, f"expected one group with an agent from the other host, found {len(mixed)}"
        room = mixed[0]
        state = await home("groups.state", {"room_id": room["room_id"]})
        page = await home("groups.log", {"room_id": room["room_id"], "since_seq": 0, "limit": 100})
        return {"members": [(m["member_id"], m["target"]["kind"]) for m in room["members"]],
                "peer_routes": [r["status"] for r in state.get("driver_status", {}).get("peer_routes", [])],
                "replies_from": sorted({e["payload"]["member_id"] for e in page["events"]
                                        if e["kind"] == "message.member"})}


def run_ui(args, hosts: list[Host], root: Path) -> int:
    repo = Path(__file__).resolve().parent.parent
    probe = root / "probe.json"
    probe.write_text(json.dumps({"mode": "roomlink", "address_a": hosts[0].origin.removeprefix("http://"),
                                 "address_b": hosts[1].origin.removeprefix("http://"),
                                 "plugin": "yes" if args.plugin else "no"}))
    probe.chmod(0o600)
    args.results.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TEST_RUNNER_BIGHELP_SIGNIN_PROBE=str(probe),
               TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=str(args.results / "roomlink"))
    command = ["xcodebuild", "test-without-building", "-project", str(repo / "Bighelp.xcodeproj"),
               "-scheme", "Bighelp", "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
               "-derivedDataPath", str(args.derived_data), "-parallel-testing-enabled", "NO",
               "-resultBundlePath", str(args.results / "roomlink.xcresult"),
               "-only-testing:BighelpUITests/AllHostsHostUITests/testGroupChatWithAnAgentFromEachHostAnswers"]
    with (args.results / "xcodebuild-roomlink.log").open("w") as output:
        result = subprocess.run(command, env=env, cwd=repo, stdout=output, stderr=subprocess.STDOUT, timeout=1500)
    print(json.dumps({"ui_test_exit_code": result.returncode}), flush=True)
    if result.returncode == 0:
        print(json.dumps(asyncio.run(read_back(hosts[1])), indent=2), flush=True)
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hermes", required=True, help="the separate Hermes checkout's hermes launcher")
    parser.add_argument("--logs", type=Path, help="keep both hosts' logs in this folder")
    parser.add_argument("--reply-timeout", type=float, default=240)
    parser.add_argument("--plugin", type=Path, help="the bighelp plugin folder to run on both hosts")
    parser.add_argument("--simulator-id", help="run the app's UI test on this simulator instead of the RPC calls")
    parser.add_argument("--derived-data", type=Path, help="where the app was built for testing")
    parser.add_argument("--results", type=Path, default=Path("/private/tmp/roomlink-results"))
    args = parser.parse_args()
    if args.simulator_id and not args.derived_data:
        parser.error("--simulator-id needs --derived-data")
    model = ThreadingHTTPServer(("127.0.0.1", 0), ScriptedModel)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="roomlink-", dir="/private/tmp") as temporary:
        root = Path(temporary).resolve()
        logs = args.logs or root / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        hosts = []
        try:
            for label, display in (("desk", "Desk agent"), ("lab", "Lab agent")):
                hosts.append(Host(label, root, args.hermes, model.server_port, logs,
                                  display=display if args.simulator_id else None, plugin=args.plugin))
            for host in hosts:
                host.wait_ready()
            if args.simulator_id:
                return run_ui(args, hosts, root)
            evidence = asyncio.run(exercise(hosts[0], hosts[1], args.reply_timeout, plugin=args.plugin is not None))
            evidence["model_calls"] = ScriptedModel.calls
            print(json.dumps(evidence, indent=2))
            return 0 if evidence["both_answered"] else 1
        finally:
            for host in hosts:
                host.stop(keep_logs=args.logs)
            model.shutdown()


if __name__ == "__main__":
    sys.exit(main())
