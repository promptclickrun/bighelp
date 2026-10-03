"""Runs the app's host sign-in tests against real, isolated stock Hermes hosts.

Each mode starts `hermes serve` from the given Hermes checkout with a throwaway
HOME and HERMES_HOME, then runs the matching HostSignInMatrixUITests:

  open      no sign-in: the address alone connects (the dashboard's own session)
  password  Hermes's username/password provider: password, access token, and
            browser sign-in through Hermes's login page
  sso       password plus a self-hosted OpenID Connect provider, using a mock
            identity provider on loopback for single sign-on in the browser
  tools     no sign-in, with the bighelp plugin (--plugin) and a scripted model
            whose tool keeps running: the secure input pop-up, and steering
            while a tool runs (not part of the default modes)
  widgets   no sign-in, the app without demo fixtures: home screen widget links
            open the host's chats (WidgetLinkHostUITests; not a default mode)
  features  no sign-in, with the bighelp plugin (--plugin) and a seeded board:
            Feed/Ideas/Goals feedback and Projects (ProjectsAndBoardHostUITests),
            and the Apps tab's files with no terminal.cwd set
  update    no sign-in, with an older plugin release installed by Hermes' own
            installer from GitHub: the app finds the latest GitHub Release and
            updates to it (PluginReleaseUpdateHostUITests; needs the internet)
  fleet     two hosts with the bighelp plugin (--plugin) and different agents:
            the all-hosts view lists both and opens an agent on the host that
            isn't selected (AllHostsHostUITests)
  media     no sign-in, with the bighelp plugin (--plugin) and the test-only
            Scripts/HostProbePlugin: a generated image stays in the chat after
            the turn ends, and Hermes' vault code and save-login prompts open
            bighelp's secure pop-up. Needs a Hermes with the vault (canary)

HERMES_DISABLE_LAZY_INSTALLS=1 keeps Hermes from "finishing a source update"
into its checkout on first launch. Use a separate Hermes checkout anyway: never
the one your real Hermes runs from.

  python3 Scripts/HostSignInMatrixProbe.py --hermes /tmp/hermes/.venv/bin/hermes \\
      --simulator-id <udid> --derived-data /tmp/dd --results /tmp/signin
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from DirectHermesProtocolProbe import request_status  # noqa: E402
from DirectHermesStreamingProbe import SyntheticModel  # noqa: E402
from DirectHermesAuthenticationProbe import exercise_http  # noqa: E402

TESTS = {
    "open": ["testOpenHostConnectsFromTheAddressAlone"],
    "password": ["testPasswordOnlyHostPrefersUsernameAndPasswordAndChats", "testWrongPasswordIsExplained",
                 "testAccessToken", "testBrowserSignInThroughHermesLoginPage"],
    "sso": ["testSingleSignOnThroughIdentityProvider"],
    "tools": ["testSecureInputPopUpSavesTheValue", "testSteerSendsWhileAToolRuns",
              "testWaitingQuestionOpensFocusedWhenReturningToTheApp"],
    "widgets": ["WidgetLinkHostUITests/testRecentChatAndNewChatWidgetLinksOpenChats"],
    "features": ["ProjectsAndBoardHostUITests/testBoardFeedbackAndProjectsOnARealHost",
                 "ProjectsAndBoardHostUITests/testAppsShowsTheAgentsFilesWithNoWorkingFolderSet",
                 "ProviderUsageHostUITests/testUsageLoadsFromTheChatTheAppOpensWith"],
    "update": ["PluginReleaseUpdateHostUITests/testUpdatesToTheLatestReleaseOnARealHost"],
    "fleet": ["AllHostsHostUITests/testAllHostsListsBothHostsAndOpensTheOther",
              "AllHostsHostUITests/testProviderUsageLoadsInAChatOnTheOtherHost",
              "AllHostsHostUITests/testUsageOpensFromTheMenuWithAllHosts",
              "AllHostsHostUITests/testSecureInputAndQuestionsWorkInAChatOnTheOtherHost"],
    "media": ["testGeneratedImageStaysAfterTheTurnEnds", "testVaultCodePopUpEntersTheCode",
              "testSaveLoginPopUpSavesTheLogin", "testVaultSavesAndImportsLoginsOnTheHost",
              "testACardStreamsBehindALoader"],
}
# 2.18.2, older than any release the app should offer.
OLD_PLUGIN_REVISION = "34f2a16938ba69185a7f5ed9fa4a963f9a9fe1b4"
STEER_OPEN = "[OUT-OF-BAND USER MESSAGE"
# Streamed a few characters at a time, so the app shows a card still on its way.
STREAMED_CARD = ("Here's your card.\n\n```loopdy-card\n"
                 '{"schema":"loopdy.generative_ui","version":1,"component":"summary",'
                 '"title":"Streamed fixture","body":"The whole card arrived."}\n```\n\n' "That's all.")


class ToolTurnModel(BaseHTTPRequestHandler):
    """A scripted model whose tool keeps running. "secure input test" asks for a secret with
    bighelp's tool, which waits for the pop-up; "long tool test" runs a 20-second command so a
    steer lands mid-tool. The final reply says what the tool returned and any steer it got."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        messages = request.get("messages", [])
        offered = {t.get("function", {}).get("name", "") for t in request.get("tools", [])}
        texts = [(i, str(m.get("content") or "")) for i, m in enumerate(messages) if m.get("role") == "user"]
        triggers = ("secure input test", "long tool test", "question test", "image test", "vault code test",
                    "save login test", "card test")
        start = max((i for i, text in texts if any(t in text for t in triggers)), default=-1)
        asked = str(messages[start].get("content", "")) if start >= 0 else ""
        secure = "secure input test" in asked
        question = "question test" in asked
        probe_tool = ("image_generate", {"prompt": "A probe picture", "aspect_ratio": "square"}) \
            if "image test" in asked else ("probe_vault_code", {"site": "example.com"}) \
            if "vault code test" in asked else ("probe_vault_save_login", {"origin": "https://example.com"}) \
            if "save login test" in asked else None
        results = [str(m.get("content") or "") for m in messages[start + 1:] if m.get("role") == "tool"]
        steers = [re.sub(r"^\[OUT-OF-BAND[^\]]*\]\s*|\s*\[/OUT-OF-BAND USER MESSAGE\]$", "", text.strip())
                  for i, text in texts if i > start and STEER_OPEN in text]
        if "card test" in asked and request.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            pieces = [STREAMED_CARD[i:i + 12] for i in range(0, len(STREAMED_CARD), 12)]
            for index, piece in enumerate(pieces):
                delta = {"role": "assistant", "content": piece} if index == 0 else {"content": piece}
                chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                         "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.flush()
                time.sleep(0.35)
            done = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(("data: " + json.dumps(done) + "\n\ndata: [DONE]\n\n").encode())
            self.wfile.flush()
            return
        call = None
        if start >= 0 and not results:
            # "secure input test 2" asks for SECURE_INPUT_FIXTURE_2: a value already saved isn't asked again.
            round_suffix = re.search(r"secure input test (\d+)", asked)
            name, arguments = (("bighelp_request_secure_input",
                                {"name": "SECURE_INPUT_FIXTURE" + (f"_{round_suffix.group(1)}" if round_suffix else ""),
                                 "label": "Fixture value",
                                 "prompt": "A test of the secure pop-up. Type anything."})
                               if secure else
                               ("clarify", {"question": "Which fixture option?", "choices": ["Alpha", "Beta"],
                                            # Newer Hermes asks in batches and requires this form.
                                            "questions": [{"question": "Which fixture option?",
                                                           "choices": ["Alpha", "Beta"]}]})
                               if question else probe_tool or ("terminal", {"command": "sleep 20"}))
            if name not in offered and "tool_call" in offered:
                name, arguments = "tool_call", {"name": name, "arguments": arguments}
            call = {"id": "call_tool_turn_fixture", "type": "function",
                    "function": {"name": name, "arguments": json.dumps(arguments)}}
        if call:
            message = {"role": "assistant", "content": None, "tool_calls": [call]}
        else:
            if secure:
                outcome = json.loads(results[-1]) if results and results[-1].startswith("{") else {}
                text = "Secure input fixture: " + ("saved." if outcome.get("success") else
                                                   f"not saved ({outcome.get('error') or 'skipped' if outcome.get('skipped') else results[-1][:120]}).")
            elif question:
                text = "Question fixture answered: " + results[-1][:80]
            elif probe_tool and probe_tool[0] == "image_generate":
                outcome = json.loads(results[-1]) if results and results[-1].startswith("{") else {}
                text = ("MEDIA:" + outcome["image"]) if outcome.get("image") else "Image fixture failed: " + results[-1][:160]
            elif probe_tool:
                outcome = json.loads(results[-1]) if results and results[-1].startswith("{") else {}
                text = ("Vault fixture: " + ("received." if outcome.get("success") else "nothing entered.")
                        + (f" {outcome['digits']} digits." if "digits" in outcome else "")
                        + (f" Saved for {outcome['identifier']}." if outcome.get("identifier") else ""))
            else:
                text = "Long tool fixture complete."
            if steers:
                text += " Steer received: " + " | ".join(steers)
            message = {"role": "assistant", "content": text}
        finish = "tool_calls" if call else "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
        self.end_headers()
        if not request.get("stream"):
            self.wfile.write(json.dumps({"id": "fixture", "object": "chat.completion", "model": "fixture-model",
                "created": 1, "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}).encode())
            return
        delta = ({"role": "assistant", "tool_calls": [{**call, "index": 0}]} if call
                 else {"role": "assistant", "content": message["content"]})
        for part in (delta, {}):
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture-model",
                     "choices": [{"index": 0, "delta": part, "finish_reason": None if part else finish}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


class MockIdentityProvider:
    """The smallest honest OpenID Connect provider: discovery, a login page
    with one button, PKCE-checked code exchange, RS256 ID tokens and JWKS."""

    def __init__(self, client_id: str):
        from cryptography.hazmat.primitives.asymmetric import rsa
        self.client_id = client_id
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.kid = secrets.token_hex(8)
        self.codes: dict[str, dict] = {}
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.issuer = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def id_token(self) -> str:
        import jwt
        now = int(time.time())
        claims = {"iss": self.issuer, "aud": self.client_id, "sub": "sso-user-1", "email": "sso@example.com",
                  "name": "SSO Tester", "iat": now, "exp": now + 3600}
        return jwt.encode(claims, self.key, algorithm="RS256", headers={"kid": self.kid})

    def jwks(self) -> dict:
        numbers = self.key.public_key().public_numbers()
        def encode(value: int) -> str:
            return b64url(value.to_bytes((value.bit_length() + 7) // 8, "big"))
        return {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": self.kid,
                          "n": encode(numbers.n), "e": encode(numbers.e)}]}

    def _handler(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send_json(self, status: int, value: dict):
                body = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                if url.path == "/.well-known/openid-configuration":
                    self.send_json(200, {
                        "issuer": provider.issuer,
                        "authorization_endpoint": provider.issuer + "/authorize",
                        "token_endpoint": provider.issuer + "/token",
                        "jwks_uri": provider.issuer + "/jwks",
                        "id_token_signing_alg_values_supported": ["RS256"],
                        "code_challenge_methods_supported": ["S256"],
                    })
                elif url.path == "/jwks":
                    self.send_json(200, provider.jwks())
                elif url.path == "/authorize":
                    query = urllib.parse.parse_qs(url.query)
                    fields = "".join(
                        f'<input type="hidden" name="{name}" value="{urllib.parse.quote(values[0])}">'
                        for name, values in query.items())
                    page = ('<!doctype html><meta name="viewport" content="width=device-width">'
                            '<title>Mock SSO</title><h1>Mock SSO</h1><form method="post" action="/approve">'
                            f'{fields}<button type="submit" style="font-size:24px">Approve sign-in</button></form>')
                    body = page.encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_json(404, {"error": "not_found"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                form = {k: urllib.parse.unquote(v[0]) for k, v in
                        urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
                if self.path == "/approve":
                    assert form.get("client_id") == provider.client_id
                    code = secrets.token_urlsafe(24)
                    provider.codes[code] = {"challenge": form["code_challenge"], "redirect_uri": form["redirect_uri"]}
                    target = form["redirect_uri"] + "?" + urllib.parse.urlencode({"code": code, "state": form["state"]})
                    self.send_response(302)
                    self.send_header("Location", target)
                    self.end_headers()
                elif self.path == "/token":
                    if form.get("grant_type") == "authorization_code":
                        grant = provider.codes.pop(form.get("code", ""), None)
                        verifier = form.get("code_verifier", "")
                        if (grant is None or grant["redirect_uri"] != form.get("redirect_uri")
                                or b64url(hashlib.sha256(verifier.encode()).digest()) != grant["challenge"]):
                            self.send_json(400, {"error": "invalid_grant"})
                            return
                    elif form.get("grant_type") != "refresh_token":
                        self.send_json(400, {"error": "unsupported_grant_type"})
                        return
                    self.send_json(200, {"access_token": secrets.token_urlsafe(32), "id_token": provider.id_token(),
                                         "token_type": "Bearer", "expires_in": 3600,
                                         "refresh_token": secrets.token_urlsafe(32)})
                else:
                    self.send_json(404, {"error": "not_found"})

        return Handler

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def seed_board(home: Path, plugin: Path) -> None:
    """Feed posts and an idea the features test acts on, written with the plugin's own store."""
    import sqlite3
    sys.path.insert(0, str(plugin))
    from loopdy_plugin.agent_board import BoardStore
    store = BoardStore(home / "plugin-data" / "loopdy")
    store.publish("feed", title="Evening AI news", body="Three stories worth your time.", icon="📰",
                  source="Evening AI news", item_id="probe-ai-news")
    store.publish("feed", title="Stock tips", body="Five picks for the week.", icon="📈", item_id="probe-stock-tips")
    store.publish("idea", title="Plan a weekend trip", body="I can find a quiet cabin two hours away.",
                  icon="🏕️", item_id="probe-trip")
    with sqlite3.connect(store.path) as db:  # published items start unread
        assert db.execute("SELECT COUNT(*) FROM items WHERE read=0").fetchone()[0] == 3


def board_feedback(home: Path) -> dict:
    import sqlite3
    with sqlite3.connect(home / "plugin-data" / "loopdy" / "board.sqlite3") as db:
        rows = {row[0]: row[1:] for row in db.execute("SELECT id, rating, reason, dismissed, read, kind FROM items")}
    return {"stock_tips": {"rating": rows["probe-stock-tips"][0], "reason": rows["probe-stock-tips"][1]},
            "news_restored": rows["probe-ai-news"][2] == 0,
            "idea_hidden": rows["probe-trip"][2] == 1,
            "goal_created": any(kind == "goal" for *_, kind in rows.values()),
            "all_read": all(row[3] == 1 for key, row in rows.items() if key.startswith("probe-") and key != "probe-trip")}


def workspace_agreement(origin: str, token: str) -> dict:
    """The folder the plugin shares as the agent's files, next to the one Hermes starts new chats in."""
    import urllib.request
    import uuid

    def call(path: str, body: dict | None = None, headers: dict | None = None):
        request = urllib.request.Request(origin + path, data=None if body is None else json.dumps(body).encode(),
                                         method="GET" if body is None else "POST",
                                         headers={"X-Hermes-Session-Token": token, "Content-Type": "application/json",
                                                  **(headers or {})})
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response), response.headers

    _, context_headers = call("/api/plugins/loopdy/native/context")
    scope, _ = call("/api/plugins/loopdy/native/workspace-files/scope", {"path": None},
                    {"If-Match": context_headers["ETag"], "X-Loopdy-Request-ID": str(uuid.uuid4())})
    default, _ = call("/api/fs/default-cwd")
    shared, hermes = scope["workspace"]["root"], default["cwd"]
    return {"origin": scope["workspace"].get("origin"),
            "same_folder_as_hermes": os.path.realpath(shared) == os.path.realpath(hermes)}


class DelayProxy:
    """Forwards a loopback port to another, holding each chunk for `delay` seconds each way, like a slower
    network (a Tailscale link to another computer). Order is kept; `rate` (bytes a second) limits
    throughput when set, so a large download takes as long as it would on a phone."""

    def __init__(self, target_port: int, delay: float, rate: float = 0):
        import asyncio
        self.port = free_port()
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

        async def pipe(reader, writer):
            queue = asyncio.Queue()

            async def send():
                while (item := await queue.get()) is not None:
                    due, data = item
                    await asyncio.sleep(max(0.0, due - self.loop.time()))
                    writer.write(data)
                    await writer.drain()
                    if rate:
                        await asyncio.sleep(len(data) / rate)
                writer.close()
            sender = asyncio.ensure_future(send())
            try:
                while data := await reader.read(65536):
                    queue.put_nowait((self.loop.time() + delay, data))
            except (ConnectionError, OSError):
                pass
            queue.put_nowait(None)
            await sender

        async def handle(client_reader, client_writer):
            try:
                upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", target_port)
            except OSError:
                client_writer.close()
                return
            await asyncio.gather(pipe(client_reader, upstream_writer), pipe(upstream_reader, client_writer),
                                 return_exceptions=True)

        async def start():
            return await asyncio.start_server(handle, "127.0.0.1", self.port)
        self.server = asyncio.run_coroutine_threadsafe(start(), self.loop).result(10)

    def close(self):
        self.loop.call_soon_threadsafe(self.server.close)
        self.loop.call_soon_threadsafe(self.loop.stop)


def free_port() -> int:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def installed_plugin(home: Path) -> dict:
    manifest = (home / "plugins" / "loopdy" / "plugin.yaml").read_text()
    version = re.search(r'(?m)^version:\s*"?([0-9.]+)"?', manifest)
    metadata = json.loads((home / "plugins" / ".install-metadata.json").read_text()).get("loopdy", {})
    return {"version": version.group(1) if version else None, "revision": metadata.get("revision")}


def vault_labels(hermes: str, env: dict, project: Path) -> str:
    """What the host's vault lists after the run, through Hermes' own CLI (labels, never values)."""
    listed = subprocess.run([hermes, "vault", "list"], cwd=project, env=dict(env, COLUMNS="240"),
                            capture_output=True, text=True, timeout=60)
    return " ".join(word for word in (listed.stdout + listed.stderr).split()
                    if word.endswith((".com", ".org", ".net")))


def session_sources(home: Path) -> list[str]:
    database = home / "state.db"
    if not database.exists():
        return []
    import sqlite3
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
        return sorted({row[0] or "" for row in connection.execute("SELECT source FROM sessions")})


def run_fleet(args, repo: Path) -> int:
    """Two open hosts with the plugin: "Desk agent" on one; "Lab agent" and "researcher" on the other.
    The scripted tool model answers plain messages like the synthetic one, and its secure input and
    question turns check prompts in a chat on the host the all-hosts view switched to."""
    if not args.plugin:
        raise SystemExit("fleet mode needs --plugin <bighelp plugin folder>")
    with tempfile.TemporaryDirectory(prefix="signin-fleet-", dir="/tmp") as temporary:
        temp = Path(temporary).resolve()
        model = ThreadingHTTPServer(("127.0.0.1", 0), ToolTurnModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        hosts, logs, proxies = [], [], []
        try:
            for label, display, extra in (("desk", "Desk agent", []), ("lab", "Lab agent", ["researcher"])):
                home, project = temp / label / "home", temp / label / "project"
                home.mkdir(parents=True)
                project.mkdir(parents=True)
                port = free_port()
                origin = f"http://127.0.0.1:{port}"
                # The app reaches each host through a proxy that adds the given network delay.
                proxy = DelayProxy(port, args.latency_ms / 1000) if args.latency_ms else None
                if proxy:
                    proxies.append(proxy)
                public = f"http://127.0.0.1:{proxy.port}" if proxy else origin
                config = {"dashboard": {"public_url": public},
                          "model": {"default": "fixture-model", "provider": "custom",
                                    "base_url": f"http://127.0.0.1:{model.server_port}/v1",
                                    "api_key": "local-synthetic-no-auth"},
                          "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(project)},
                          "memory": {"memory_enabled": False, "user_profile_enabled": False},
                          "plugins": {"enabled": ["loopdy"]}}
                shutil.copytree(args.plugin, home / "plugins" / "loopdy",
                                ignore=shutil.ignore_patterns("tests", "__pycache__", ".git"))
                (home / "config.yaml").write_text(json.dumps(config))
                env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
                env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS="1",
                           HERMES_DASHBOARD_SESSION_TOKEN=secrets.token_urlsafe(32), PYTHONUNBUFFERED="1",
                           NO_PROXY="127.0.0.1,localhost")
                quiet = {"cwd": project, "env": env, "check": True, "timeout": 120,
                         "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
                subprocess.run([args.hermes, "profile", "rename", "default", display], **quiet)
                for name in extra:
                    subprocess.run([args.hermes, "profile", "create", name, "--no-alias", "--no-skills"], **quiet)
                log = (args.results / f"hermes-fleet-{label}.log").open("w")
                logs.append(log)
                process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port),
                                            "--isolated", "--skip-build"], cwd=project, env=env, stdout=log,
                                           stderr=subprocess.STDOUT)
                hosts.append((label, origin, env["HERMES_DASHBOARD_SESSION_TOKEN"], process, home, public))
            for label, origin, token, process, _, _ in hosts:
                deadline = time.monotonic() + 90
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"Hermes exited (fleet {label}); see hermes-fleet-{label}.log")
                    try:
                        if request_status(origin, token)[0] == 200:
                            break
                    except OSError:
                        pass
                    if time.monotonic() > deadline:
                        raise TimeoutError(f"Hermes not ready (fleet {label})")
                    time.sleep(0.3)
            secret = temp / "probe.json"
            secret.write_text(json.dumps({"mode": "fleet", "address_a": hosts[0][5].removeprefix("http://"),
                                          "address_b": hosts[1][5].removeprefix("http://")}))
            secret.chmod(0o600)
            client_env = dict(os.environ, TEST_RUNNER_BIGHELP_SIGNIN_PROBE=str(secret),
                              TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=str(args.results / "fleet"))
            (args.results / "fleet").mkdir(parents=True, exist_ok=True)
            command = ["xcodebuild", "test-without-building", "-project", str(repo / "Bighelp.xcodeproj"),
                       "-scheme", "Bighelp", "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
                       "-derivedDataPath", str(args.derived_data), "-parallel-testing-enabled", "NO",
                       "-resultBundlePath", str(args.results / "fleet.xcresult")]
            command += [f"-only-testing:BighelpUITests/{name}" for name in TESTS["fleet"]
                        if not args.only or any(part in name for part in args.only.split(","))]
            with (args.results / "xcodebuild-fleet.log").open("w") as output:
                result = subprocess.run(command, env=client_env, cwd=repo, stdout=output, stderr=subprocess.STDOUT,
                                        timeout=1500)
            for label, _, _, _, home, _ in hosts:
                print(json.dumps({"host": label, "session_sources_on_host": session_sources(home)}), flush=True)
            timings = args.results / "fleet" / "fleet-timings.json"
            if timings.exists():
                print(json.dumps({"switch_seconds": json.loads(timings.read_text()),
                                  "latency_ms": args.latency_ms}), flush=True)
            print(json.dumps({"mode": "fleet", "exit_code": result.returncode}), flush=True)
            return result.returncode
        finally:
            for proxy in proxies:
                proxy.close()
            for label, _, _, process, home, _ in hosts:
                if (home / "logs").exists():
                    shutil.copytree(home / "logs", args.results / f"hermes-fleet-{label}-logs", dirs_exist_ok=True)
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            for log in logs:
                log.close()
            model.shutdown()
            model.server_close()


def run_mode(mode: str, args, repo: Path) -> int:
    if mode == "fleet":
        return run_fleet(args, repo)
    with tempfile.TemporaryDirectory(prefix=f"signin-{mode}-", dir="/tmp") as temporary:
        temp = Path(temporary).resolve()
        home, project = temp / "home", temp / "project"
        home.mkdir()
        project.mkdir()
        model = ThreadingHTTPServer(("127.0.0.1", 0), ToolTurnModel if mode in ("tools", "media") else SyntheticModel)
        threading.Thread(target=model.serve_forever, daemon=True).start()
        port = free_port()
        origin = f"http://127.0.0.1:{port}"
        # The media mode reaches its host over a slower link, like a phone on Tailscale.
        proxy = DelayProxy(port, args.latency_ms / 1000, args.rate_kbps * 1024) \
            if mode == "media" and (args.latency_ms or args.rate_kbps) else None
        # Hermes only gates a dashboard whose public address isn't loopback. *.localhost
        # still resolves to this Mac, so gated hosts use it; single sign-on needs the
        # app on that same name, since the sign-in cookie belongs to it.
        public = f"http://127.0.0.1:{proxy.port}" if proxy \
            else origin if mode in ("open", "tools", "widgets", "features", "update", "media") \
            else f"http://hermes.localhost:{port}"
        config = {"dashboard": {"public_url": public},
                  "model": {"default": "fixture-model", "provider": "custom",
                            "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": "local-synthetic-no-auth"},
                  "agent": {"max_turns": 3}, "terminal": {"backend": "local", "cwd": str(project)},
                  "memory": {"memory_enabled": False, "user_profile_enabled": False}}
        if mode in ("tools", "features", "media"):
            if not args.plugin:
                raise SystemExit(f"{mode} mode needs --plugin <bighelp plugin folder>")
            shutil.copytree(args.plugin, home / "plugins" / "loopdy",
                            ignore=shutil.ignore_patterns("tests", "__pycache__", ".git"))
            config["agent"]["max_turns"] = 4
            config["plugins"] = {"enabled": ["loopdy"]}
        if mode == "media":
            shutil.copytree(repo / "Scripts" / "HostProbePlugin", home / "plugins" / "bighelp-probe",
                            ignore=shutil.ignore_patterns("__pycache__"))
            config["plugins"]["enabled"].append("bighelp-probe")
            config["image_gen"] = {"provider": "bighelp-probe"}
        if mode == "features":
            seed_board(home, args.plugin)
            (project / "garden").mkdir()
            # No terminal.cwd: the agent works where Hermes was started (the project folder),
            # and the Apps tab must still show its files.
            del config["terminal"]["cwd"]
            (project / "garden-notes.md").write_text("Water the tomatoes on Tuesday.\n")
        (home / "config.yaml").write_text(json.dumps(config))
        session_token, password = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
        env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS="1",
                   HERMES_DASHBOARD_SESSION_TOKEN=session_token, PYTHONUNBUFFERED="1",
                   NO_PROXY="127.0.0.1,localhost")
        if mode == "update":
            # A real Git install with Hermes' metadata, as on a person's computer.
            subprocess.run([args.hermes, "plugins", "install", "promptclickrun/bighelp-plugin",
                            "--ref", OLD_PLUGIN_REVISION, "--enable"], cwd=project, env=env, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
        idp = None
        if mode in ("password", "sso"):
            env.update(HERMES_DASHBOARD_BASIC_AUTH_USERNAME="signin-fixture",
                       HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=password,
                       HERMES_DASHBOARD_BASIC_AUTH_SECRET=secrets.token_urlsafe(48))
        if mode == "sso":
            idp = MockIdentityProvider(client_id="bighelp-signin-test")
            env.update(HERMES_DASHBOARD_OIDC_ISSUER=idp.issuer, HERMES_DASHBOARD_OIDC_CLIENT_ID=idp.client_id)
        log = (args.results / f"hermes-{mode}.log").open("w")
        process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(port), "--isolated",
                                    "--skip-build"], cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT)
        secret = temp / "probe.json"
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"Hermes exited ({mode}); see hermes-{mode}.log")
                try:
                    if request_status(origin, session_token)[0] == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise TimeoutError(f"Hermes not ready ({mode})")
                time.sleep(0.3)
            probe = {"mode": mode, "address": public.removeprefix("http://"), "session_token": session_token}
            if mode == "features":
                probe["project_dir"] = str(project / "garden")
                probe["workspace_file"] = "garden-notes.md"
            if mode in ("password", "sso"):
                _, _, tokens = exercise_http(origin, "signin-fixture", password)
                probe.update(username="signin-fixture", password=password, token=tokens["access_token"])
            secret.write_text(json.dumps(probe))
            secret.chmod(0o600)
            client_env = dict(os.environ, TEST_RUNNER_BIGHELP_SIGNIN_PROBE=str(secret),
                              TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=str(args.results / mode))
            (args.results / mode).mkdir(parents=True, exist_ok=True)
            command = ["xcodebuild", "test-without-building", "-project", str(repo / "Bighelp.xcodeproj"),
                       "-scheme", "Bighelp", "-destination", f"platform=iOS Simulator,id={args.simulator_id}",
                       "-derivedDataPath", str(args.derived_data), "-parallel-testing-enabled", "NO",
                       "-resultBundlePath", str(args.results / f"{mode}.xcresult")]
            command += [f"-only-testing:BighelpUITests/{name if '/' in name else 'HostSignInMatrixUITests/' + name}"
                        for name in TESTS[mode]]
            with (args.results / f"xcodebuild-{mode}.log").open("w") as output:
                result = subprocess.run(command, env=client_env, cwd=repo, stdout=output, stderr=subprocess.STDOUT,
                                        timeout=1500)
            if mode == "tools":
                saved = (home / ".env").read_text() if (home / ".env").exists() else ""
                print(json.dumps({"secure_input_saved_on_host": "SECURE_INPUT_FIXTURE=" in saved}), flush=True)
            if mode == "features":
                print(json.dumps({"board_on_host": board_feedback(home)}), flush=True)
                print(json.dumps({"workspace_on_host": workspace_agreement(origin, session_token)}), flush=True)
            if mode == "update":
                print(json.dumps({"plugin_on_host": installed_plugin(home)}), flush=True)
            if mode == "media":
                print(json.dumps({"vault_on_host": vault_labels(args.hermes, env, project)}), flush=True)
            # The app's chats must reach Hermes as "bighelp", not its terminal UI.
            print(json.dumps({"session_sources_on_host": session_sources(home)}), flush=True)
            print(json.dumps({"mode": mode, "exit_code": result.returncode}), flush=True)
            return result.returncode
        finally:
            if (home / "logs").exists():
                shutil.copytree(home / "logs", args.results / f"hermes-{mode}-logs", dirs_exist_ok=True)
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
            model.shutdown()
            model.server_close()
            if proxy:
                proxy.close()
            if idp:
                idp.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True, help="hermes executable from a separate, throwaway checkout")
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--modes", default="open,password,sso")
    parser.add_argument("--plugin", type=Path, help="bighelp (loopdy) plugin folder, for the tools mode")
    parser.add_argument("--latency-ms", type=int, default=0,
                        help="fleet and media modes: network delay each way between the app and each host")
    parser.add_argument("--rate-kbps", type=int, default=0,
                        help="media mode: throughput limit between the app and the host, in KiB a second")
    parser.add_argument("--only", help="fleet mode: run only the tests whose names contain one of these, comma separated")
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[1]
    failures = [mode for mode in args.modes.split(",") if run_mode(mode, args, repo) != 0]
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
