"""A real, isolated Hermes host for App Store screenshots.

Starts `hermes serve` from a separate Hermes checkout with a throwaway HOME and
HERMES_HOME, the bighelp plugin, a few agents and some made-up files (a card
statement, trip notes, bills). Its model is scripted, but everything it asks
for really runs: Hermes reads the files, the plugin renders the cards, the
board tool posts to Feed, Ideas and Goals, and the cron tool schedules the job.
Every number in a reply is computed from what the tools returned.

The clock: Apple's screenshots read 9:41. The host and the app share a time
zone where it's a little before 9:41 now, so the times shown in chats and on
the board fit the status bar.

  python3 Scripts/AppStoreScreenshotHost.py --hermes /tmp/hermes/.venv/bin/hermes \\
      --plugin ~/path/to/bighelp-plugin --port 9333

It prints one JSON line with the address and the time zone, then serves until
interrupted. HERMES_DISABLE_LAZY_INSTALLS=1 keeps Hermes from "finishing a
source update" into its checkout; still never point it at the checkout your
real Hermes runs from.
"""

import argparse
import csv
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
from DirectHermesProtocolProbe import request_status  # noqa: E402

AGENTS = {
    # profile: (display name, description)
    "default": ("Juno", "Everyday helper: plans, reminders and the morning brief."),
    "penny": ("Penny", "Keeps an eye on spending, bills and savings."),
    "atlas": ("Atlas", "Plans trips: flights, stays and packing."),
}

STATEMENT = """date,merchant,category,amount
2026-09-01,Green Basket Market,Groceries,84.12
2026-09-02,City Transit,Transport,32.00
2026-09-02,Streamly,Subscriptions,15.99
2026-09-03,Corner Bakery,Dining out,12.40
2026-09-05,Green Basket Market,Groceries,61.75
2026-09-06,Tasca Lua,Dining out,86.30
2026-09-07,Hardware Haus,Home,47.89
2026-09-08,City Transit,Transport,4.50
2026-09-09,Green Basket Market,Groceries,72.08
2026-09-10,Pages & Co.,Shopping,28.00
2026-09-11,Daily Grind,Dining out,6.25
2026-09-12,Farmers Market,Groceries,38.60
2026-09-13,Noodle Bar,Dining out,41.20
2026-09-14,Cloud Photos,Subscriptions,2.99
2026-09-15,Bright Power,Utilities,96.42
2026-09-16,Green Basket Market,Groceries,90.33
2026-09-17,City Transit,Transport,32.00
2026-09-18,Hardware Haus,Home,23.15
2026-09-19,Sunday Brunch Club,Dining out,58.90
2026-09-20,Green Basket Market,Groceries,55.47
2026-09-21,FitBox Gym,Subscriptions,39.00
2026-09-22,Daily Grind,Dining out,5.80
2026-09-23,AquaFlow Water,Utilities,41.16
2026-09-24,Green Basket Market,Groceries,77.91
2026-09-25,Rail Link,Transport,18.40
2026-09-26,Taqueria Sol,Dining out,33.75
2026-09-27,Farmers Market,Groceries,29.40
2026-09-28,Outdoor Supply,Shopping,64.99
2026-09-29,Daily Grind,Dining out,6.25
2026-09-30,Green Basket Market,Groceries,68.20
"""

# The trip, the bills and the plans are dated from the day the host starts, so the
# Feed reads "Lisbon in 8 days" and "bills due this week" whenever the set is taken.
TODAY = date.today()


def day(offset: int) -> date:
    return TODAY + timedelta(days=offset)


def short(moment: date) -> str:
    return f"{moment:%b} {moment.day}"


def nth(moment: date) -> str:
    suffix = "th" if 11 <= moment.day % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(moment.day % 10, "th")
    return f"{moment.day}{suffix}"


def trip_span() -> str:
    start, end = day(8), day(15)
    return f"{short(start)}–{end.day}" if start.month == end.month else f"{short(start)}–{short(end)}"


def trip_notes() -> str:
    return f"""# Lisbon, {trip_span()}

Flights: SFO to LIS on {short(day(8))}, overnight. Home on the {nth(day(15))}.
Stay: a small apartment in Alfama, near the Miradouro de Santa Luzia.

## Plans
- {short(day(9))}: tram 28, then the castle at sunset
- {short(day(11))}: day trip to Sintra (trains sell out on weekends, book ahead)
- {short(day(13))}: Belem, pasteis de nata, the tile museum
- {short(day(14))}: fado dinner in Alfama

Weather: 70s and sunny, one rainy day likely. The hills are steep.

## Packing
- [x] Passports
- [x] Travel adapter (Type F)
- [ ] Comfortable walking shoes
- [ ] Light rain jacket
- [ ] Sunglasses and sunscreen
- [ ] Card for the metro (Viva Viagem)

## Savings
Lisbon fund: $420 of $600
"""


def bills() -> str:
    return "bill,amount,due\n" + "".join(f"{name},{amount},{day(offset).isoformat()}\n" for name, amount, offset in (
        ("Rent", "1850.00", 1), ("Bright Power", "96.42", 3), ("Phone", "45.00", 5),
        ("AquaFlow Water", "41.16", 7), ("Car insurance", "112.00", 20)))


GOALS = """# Goals
- Run three times a week (2 runs so far this week)
- Read 2 books in October (halfway through the first)
"""


def kanban() -> list:
    return [
        ("Book Sintra train tickets", f"Trains sell out on weekends. {short(day(11))}, two seats.", None),
        ("Find a fado dinner spot in Alfama", f"Small place, near the apartment, {short(day(14))}.", None),
        ("Order a Type F travel adapter", "", "Ordered, arrives Friday."),
        ("Renew passport photos", "", "Done at the pharmacy."),
        ("Pick up euros", "About 200 for cafes and trams.", None),
    ]


def read_tool_text(result: str) -> str:
    """The file text from a read_file result, without Hermes's line numbers."""
    text = result
    try:
        value = json.loads(result)
        if isinstance(value, dict):
            text = str(value.get("content") or value.get("text") or value.get("output") or "")
    except (ValueError, TypeError):
        pass
    return "\n".join(re.sub(r"^\s*\d+\s*[|│→\t]", "", line, count=1) for line in text.splitlines())


def tool_json(result: str) -> dict:
    try:
        value = json.loads(result)
        return value if isinstance(value, dict) else {}
    except (ValueError, TypeError):
        return {}


def money(value: float) -> str:
    return f"${value:,.2f}"


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def provenance(source: str) -> dict:
    now = datetime.now(timezone.utc)
    return {"source_name": source, "source_timestamp": iso(now), "retrieved_at": iso(now), "cache_status": "live"}


# MARK: Stories. Each takes the tool results so far and returns the next tool
# call (name, arguments) or the final reply.

def spending(results: list[str]):
    if not results:
        return ("read_file", {"path": "~/Documents/Money/september-card.csv"})
    rows = list(csv.DictReader(io.StringIO(read_tool_text(results[0]).strip())))
    totals: dict[str, float] = defaultdict(float)
    visits: dict[str, int] = defaultdict(int)
    for row in rows:
        totals[row["category"]] += float(row["amount"])
        visits[row["category"]] += 1
    ranked = sorted(totals.items(), key=lambda item: -item[1])
    if len(results) == 1:
        return ("bighelp_render_chart", {
            "schema": "bighelp.generative_ui", "version": 2, "component": "chart",
            "title": "September spending", "subtitle": f"{len(rows)} purchases on your card",
            "data": {"chart_type": "bar", "description": "Spending by category in September.",
                     "x_axis": {"label": "Category", "kind": "category"},
                     "y_axis": {"label": "Spent", "unit": "USD", "min": 0},
                     "series": [{"id": "september", "label": "September", "semantic": "primary",
                                 "status_label": "Total " + money(sum(totals.values())),
                                 "points": [{"x": name, "y": round(value, 2)} for name, value in ranked]}]},
            "provenance": provenance("september-card.csv")})
    card = tool_json(results[1]).get("display_markdown", "")
    top, second = ranked[0], ranked[1]
    dining = [row for row in rows if row["category"] == "Dining out"]
    biggest = max(dining, key=lambda row: float(row["amount"]))
    return (f"September came to **{money(sum(totals.values()))}** across {len(rows)} purchases.\n\n"
            f"- **{top[0]}** was the biggest share: {money(top[1])} over {visits[top[0]]} trips.\n"
            f"- **{second[0]}** came next at {money(second[1])}. The biggest one was "
            f"{biggest['merchant']} ({money(float(biggest['amount']))}).\n"
            f"- Subscriptions were {money(totals['Subscriptions'])} for {visits['Subscriptions']} services.\n\n"
            f"{card}\n\nWant me to set a dining budget for October?")


def packing(results: list[str]):
    if not results:
        return ("read_file", {"path": "~/Documents/Trips/lisbon-trip.md"})
    notes = read_tool_text(results[0])
    section = notes.split("## Packing", 1)[1].split("##", 1)[0]
    items = re.findall(r"- \[( |x)\] (.+)", section)
    if len(results) == 1:
        return ("bighelp_render_checklist", {
            "schema": "bighelp.generative_ui", "version": 2, "component": "checklist",
            "title": "Lisbon packing list", "subtitle": f"From your trip notes · {trip_span()}",
            "data": {"description": "What's packed is checked off.",
                     "items": [{"id": re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")[:40] or f"item-{index}",
                                "label": label.strip(), "completed": mark == "x"}
                               for index, (mark, label) in enumerate(items)]},
            "provenance": provenance("lisbon-trip.md")})
    card = tool_json(results[1]).get("display_markdown", "")
    left = sum(1 for mark, _ in items if mark != "x")
    return (f"Here's your list from your notes: {len(items) - left} packed, {left} to go.\n\n{card}\n\n"
            "Sintra is all hills, so the shoes and rain jacket matter most. Want a reminder the night before?")


def brief(results: list[str]):
    if not results:
        return ("cronjob_manage", {
            "action": "create", "name": "Morning brief", "schedule": "30 7 * * 1-5",
            "prompt": ("Write a short morning brief: today's weather, what's on the calendar, and any bill "
                       "due in the next three days from ~/Documents/Home/bills.csv. Three bullets at most.")})
    job = tool_json(results[0])
    job_id = str(job.get("job_id") or job.get("id") or (job.get("job") or {}).get("id") or "morning-brief")
    next_run = job.get("next_run_at") or (job.get("job") or {}).get("next_run_at")
    if len(results) == 1:
        data = {"description": "Weather, your calendar and bills due soon.", "job_id": job_id[:120],
                "profile": "default", "state": "active", "schedule": "Weekdays at 7:30 AM",
                "delivery": "This chat", "operations": ["run", "pause"],
                "prompt": "Weather, today's calendar and bills due in the next three days."}
        if next_run:
            try:
                data["next_runs"] = [iso(datetime.fromisoformat(str(next_run).replace("Z", "+00:00")))]
            except ValueError:
                pass
        return ("bighelp_render_automation", {
            "schema": "bighelp.generative_ui", "version": 2, "component": "automation",
            "title": "Morning brief", "subtitle": "Every weekday", "data": data,
            "provenance": provenance("Hermes schedule")})
    card = tool_json(results[1]).get("display_markdown", "")
    return f"Done. Your morning brief is scheduled for every weekday at 7:30 AM.\n\n{card}"


def board(results: list[str]):
    reads = [("read_file", {"path": "~/Documents/Home/bills.csv"}),
             ("read_file", {"path": "~/Documents/Trips/lisbon-trip.md"}),
             ("read_file", {"path": "~/Documents/goals.md"}),
             ("read_file", {"path": "~/Documents/Money/september-card.csv"})]
    if len(results) < len(reads):
        return reads[len(results)]
    bills = list(csv.DictReader(io.StringIO(read_tool_text(results[0]).strip())))
    notes, goals_text = read_tool_text(results[1]), read_tool_text(results[2])
    rows = list(csv.DictReader(io.StringIO(read_tool_text(results[3]).strip())))
    soon = [bill for bill in bills if 0 <= (date.fromisoformat(bill["due"]) - TODAY).days <= 7]
    saved = re.search(r"\$(\d+) of \$(\d+)", notes)
    dining = sum(float(row["amount"]) for row in rows if row["category"] == "Dining out")
    goals = re.findall(r"- (.+?) \((.+?)\)", goals_text)
    posts = [
        ("bighelp_board", {"action": "post", "icon": "✈️", "title": "Lisbon in 8 days",
                           "body": f"Overnight flight on the {nth(day(8))}, home on the {nth(day(15))}. "
                                   f"Sintra on the {nth(day(11))}: weekend trains sell out, so book ahead.",
                           "source": "Trip notes"}),
        ("bighelp_board", {"action": "post", "icon": "🧾",
                           "title": f"{len(soon)} bill{'s' * (len(soon) != 1)} due this week",
                           "body": "\n".join(f"- {bill['bill']}: {money(float(bill['amount']))}, due "
                                             f"{date.fromisoformat(bill['due']):%a %b} "
                                             f"{date.fromisoformat(bill['due']).day}" for bill in soon),
                           "source": "Bills"}),
        ("bighelp_board", {"action": "post", "icon": "📊", "title": "September in one line",
                           "body": f"{money(sum(float(row['amount']) for row in rows))} spent. "
                                   f"Dining out was {money(dining)}.", "source": "Card statement"}),
        ("bighelp_board", {"action": "goal", "id": "lisbon-fund", "icon": "🏖️", "title": "Lisbon fund",
                           "section": "goal", "status": "active", "category": "finance",
                           "note": f"${saved.group(1)} of ${saved.group(2)} saved" if saved else "Started",
                           "source": "Trip notes"}),
        *[("bighelp_board", {"action": "goal", "id": f"goal-{index}", "icon": icon, "title": title,
                             "section": "tracking", "note": note[0].upper() + note[1:], "source": "Goals"})
          for index, ((title, note), icon) in enumerate(zip(goals, ("🏃", "📚")))],
        ("bighelp_board", {"action": "idea", "id": "sintra-tickets", "icon": "🚆", "section": "Travel",
                           "title": "Book Sintra trains now",
                           "body": f"Weekend trains sell out. I can find two seats for the {nth(day(11))}.",
                           "source": "Trip notes"}),
        ("bighelp_board", {"action": "idea", "id": "dining-budget", "icon": "🍽️", "section": "Money",
                           "title": "An October dining budget",
                           "body": f"September's dining out was {money(dining)}. Want a weekly limit "
                                   "and a nudge when you're close?", "source": "Card statement"}),
    ]
    done = len(results) - len(reads)
    if done < len(posts):
        return posts[done]
    return ("Done. Three posts are on your Feed, your Lisbon fund and two goals are in Goals, "
            "and there are two ideas waiting in Ideas.")


STORIES = [
    ("where did my money go", spending, "September spending"),
    ("packing list", packing, "Lisbon packing list"),
    ("morning brief", brief, "Morning brief"),
    ("highlights", board, "This week's highlights"),
]


class StoryModel(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        messages = request.get("messages", [])
        offered = {t.get("function", {}).get("name", "") for t in request.get("tools", [])}
        users = [(index, str(m.get("content") or "")) for index, m in enumerate(messages) if m.get("role") == "user"]
        latest_index, latest = users[-1] if users else (-1, "")
        story = next((s for s in STORIES if s[0] in latest.lower()), None)
        system = " ".join(str(m.get("content") or "") for m in messages if m.get("role") == "system").lower()
        call = None
        if story and "terminal" in offered:
            results = [str(m.get("content") or "") for m in messages[latest_index + 1:] if m.get("role") == "tool"]
            step = story[1](results)
            if isinstance(step, tuple):
                name, arguments = step
                if name not in offered and "tool_call" in offered:
                    name, arguments = "tool_call", {"name": name, "arguments": arguments}
                call = {"id": f"call_{len(results)}", "type": "function",
                        "function": {"name": name, "arguments": json.dumps(arguments)}}
                text = None
            else:
                text = step
        elif story and "title" in system:
            text = story[2]
        elif "title" in system:
            text = "Chat"
        else:
            text = "I'm here. What can I help with?"
        message = {"role": "assistant", "content": None, "tool_calls": [call]} if call \
            else {"role": "assistant", "content": text}
        finish = "tool_calls" if call else "stop"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
        self.end_headers()
        if not request.get("stream"):
            self.wfile.write(json.dumps({"id": "story", "object": "chat.completion", "model": "story-model",
                "created": int(time.time()), "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}).encode())
            return
        if call:
            parts = [{"role": "assistant", "tool_calls": [{**call, "index": 0}]}]
        else:
            # Streamed in small pieces, like a model writing.
            pieces = re.findall(r".{1,24}", text, flags=re.S) or [""]
            parts = [{"role": "assistant", "content": pieces[0]}] + [{"content": piece} for piece in pieces[1:]]
        for part in parts + [{}]:
            chunk = {"id": "story", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": "story-model",
                     "choices": [{"index": 0, "delta": part, "finish_reason": None if part else finish}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
            if not call:
                time.sleep(0.03)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def morning_time_zone() -> str:
    """An Etc/GMT zone where the time now is a little before 9:41."""
    now = datetime.now(timezone.utc)
    hour = 9 if now.minute <= 20 else 8
    offset = (hour - now.hour + 12) % 24 - 12  # -12...11
    return "UTC" if offset == 0 else f"Etc/GMT{'-' if offset > 0 else '+'}{abs(offset)}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hermes", required=True, help="hermes executable from a separate, throwaway checkout")
    parser.add_argument("--plugin", type=Path, required=True, help="bighelp (loopdy) plugin folder")
    parser.add_argument("--port", type=int, default=9333)
    parser.add_argument("--time-zone", help="Etc/GMT zone to use instead of the computed morning one")
    args = parser.parse_args()

    temp = Path(tempfile.mkdtemp(prefix="bighelp-store-host-", dir="/tmp")).resolve()
    try:
        serve(args, temp)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def serve(args, temp: Path) -> None:
    home = temp / "home"
    project = home / "Documents"
    zone = args.time_zone or morning_time_zone()
    global TODAY
    TODAY = datetime.now(ZoneInfo(zone)).date()
    for folder, name, text in (("Money", "september-card.csv", STATEMENT), ("Trips", "lisbon-trip.md", trip_notes()),
                               ("Home", "bills.csv", bills()), ("", "goals.md", GOALS)):
        (project / folder).mkdir(parents=True, exist_ok=True)
        (project / folder / name).write_text(text)

    model = ThreadingHTTPServer(("127.0.0.1", 0), StoryModel)
    threading.Thread(target=model.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{args.port}"
    config = {"dashboard": {"public_url": origin},
              "model": {"default": "story-model", "provider": "custom",
                        "base_url": f"http://127.0.0.1:{model.server_port}/v1", "api_key": "local-story-no-auth"},
              "agent": {"max_turns": 16}, "terminal": {"backend": "local", "cwd": str(home)},
              "memory": {"memory_enabled": False, "user_profile_enabled": False},
              "plugins": {"enabled": ["loopdy"]}}
    (home / "config.yaml").write_text(json.dumps(config))
    shutil.copytree(args.plugin, home / "plugins" / "loopdy",
                    ignore=shutil.ignore_patterns("tests", "__pycache__", ".git"))
    env = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
    env.update(HOME=str(home), HERMES_HOME=str(home), HERMES_DISABLE_LAZY_INSTALLS="1", PYTHONUNBUFFERED="1",
               NO_PROXY="127.0.0.1,localhost", TZ=zone)

    def hermes(*command: str) -> None:
        subprocess.run([args.hermes, *command], cwd=home, env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)

    for profile, (display, description) in AGENTS.items():
        if profile == "default":
            hermes("profile", "rename", "default", display)
        else:
            hermes("profile", "create", profile, "--clone", "--no-alias", "--description", description)
            # Each agent loads plugins from its own folder (newer Hermes clones them too).
            shutil.copytree(home / "plugins" / "loopdy", home / "profiles" / profile / "plugins" / "loopdy",
                            dirs_exist_ok=True)
            # Hermes reads the name people see from profile.yaml (JSON is valid YAML).
            (home / "profiles" / profile / "profile.yaml").write_text(
                json.dumps({"description": description, "description_auto": False, "display_name": display}))
    hermes("kanban", "init")
    for title, body, state in kanban():
        created = subprocess.run([args.hermes, "kanban", "create", title, "--json", *(["--body", body] if body else [])],
                                 cwd=home, env=env, check=True, capture_output=True, text=True, timeout=120)
        task_id = str(json.loads(created.stdout).get("id", ""))
        if state and task_id:
            hermes("kanban", "complete", task_id, "--result", state)

    log = (temp / "hermes.log").open("w")
    process = subprocess.Popen([args.hermes, "serve", "--host", "127.0.0.1", "--port", str(args.port),
                                "--isolated", "--skip-build"], cwd=home, env=env, stdout=log, stderr=subprocess.STDOUT)

    def stop(*_):
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
        model.shutdown()
        log.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    deadline = time.monotonic() + 120
    while True:
        if process.poll() is not None:
            print((temp / "hermes.log").read_text()[-2000:], file=sys.stderr)
            raise SystemExit("Hermes exited")
        try:
            if request_status(origin, None)[0] == 200:
                break
        except OSError:
            pass
        if time.monotonic() > deadline:
            raise SystemExit("Hermes not ready")
        time.sleep(0.5)
    print(json.dumps({"address": origin.removeprefix("http://"), "time_zone": zone, "home": str(home)}), flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
