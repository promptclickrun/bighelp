# bighelp

bighelp is an app for your personal AI agents that run on
[Hermes](https://github.com/NousResearch/hermes-agent). It runs on iPhone, iPad, Mac and Apple Vision Pro, and it
makes work with your agents feel like texting a friend.

## Get it

- **iPhone, iPad and Apple Vision Pro:** [bighelp on the App Store](https://apps.apple.com/app/id6801968179).
- **Mac:** download the DMG from the [latest Mac release](https://github.com/promptclickrun/bighelp/releases/latest).
  The Mac app updates itself.
- **The bighelp plugin** for your Hermes computer: the app offers to install it during setup, and in Settings.
  You can also install it yourself:

  ```sh
  hermes plugins install promptclickrun/bighelp-plugin --enable
  ```

## What it does

- **One home with three places,** the same for everyone:
  - **Bots or Chats:** the first place shows your bots like a messaging app, or every chat from every computer.
    You pick the view at the end of setup, and a switch in the header changes it.
  - **Today:** your Feed, Ideas and Goals, and Spaces. A space is a live panel that an agent makes and keeps
    current, after you add it.
  - **Work:** what your agents do now: coding sessions, running chats, workflows, tasks and scheduled
    tasks.
- **Chat** with one agent, or with a group of agents, also agents on your other computers. A new chat can also
  start a coding session in its own worktree. Then you look at the changes and ship them. Replies stream in
  live. You can react to messages, see the agent's reasoning and tool use, and send files and photos.
- **Agents** that you make from templates, or save as templates. Each agent has an avatar from the catalog or your
  own design, and a profile with its files and media.
- **Approvals and questions,** so an agent asks before it acts.
- **Feed, Ideas and Goals.** Your agent fills them, but only after you ask it to.
- **Projects, Kanban, Workflows and Scheduled tasks** for longer work (Work opens them), and **Usage** for your AI
  plans and limits.
- **Voice:** talk in turns, or live.
- **Apps and skills:** connect apps for your agents through Composio or Hermes' own connectors (Settings › Apps &
  skills).
- **Device tools:** let agents use Calendar, Reminders, Contacts, Photos, Health, Location and more (Settings ›
  Apps & skills › Device access). Each one is off until you turn it on.
- **Several computers:** Show every computer puts the bots and chats of all your computers in one list.
- **Notifications, Live Activities, widgets, Shortcuts, CarPlay and an Apple Watch app.**
- **Apple Vision Pro:** your agent can stand in the room with you, in 3D.
- **Themes** with light and dark modes. One Settings holds everything, and **Advanced options** adds host tools
  such as files, MCP servers and logs.

## How it works

- The app connects directly to the Hermes host that you run, over your home network, Tailscale or HTTPS. Use one
  address that your devices can reach from all places, for example your Tailscale name or an HTTPS domain. The app
  signs in with Hermes' own login.
- There is no bighelp account. Your chats go only between your devices and your host, and to the AI providers that
  your host uses.
- The app does not check the Hermes version. It checks what the host can do, and it shows a message when a
  feature needs something that the host does not have.
- The [bighelp plugin](https://github.com/promptclickrun/bighelp-plugin) adds the extras: notifications, Feed,
  Ideas and Goals, cards, live voice, Teamwork, files and media from your agents, your own templates, device tools,
  and chats that stay open when your phone sleeps. When a feature needs a newer plugin, the app tells you and
  offers the update.
- bighelp's own notification service sends push notifications and Live Activities.
- Sign-in details stay in the Keychain on your device. The app has no ads.
- The app sends usage and diagnostics numbers, so that the maintainers can find what is slow or broken. It never
  sends your messages, files or file names. You can turn it off in Settings › Help & feedback. See
  [docs/SECURITY_AND_PRIVACY.md](docs/SECURITY_AND_PRIVACY.md).
- Hermes behind Cloudflare Access, a password proxy, or a proxy that checks its own headers (for example Pangolin)
  also works. See [docs/HOST_ACCESS.md](docs/HOST_ACCESS.md).

## Build it yourself

You need a Mac with a current Xcode (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app needs
iOS 17 or later, or visionOS 26 or later. The Mac app is the iPad app through Mac Catalyst.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # add your Apple Team ID
xcodegen generate
open Bighelp.xcodeproj
```

Schemes:

| Scheme | Builds |
|---|---|
| `Bighelp` | iPhone and iPad, with the widgets and the notification extension |
| `BighelpCatalyst` | Mac (Mac Catalyst) |
| `BighelpVision` | Apple Vision Pro |
| `BighelpWatch` | Apple Watch |

The app was first called Loopdy, so some stored names (bundle IDs, settings keys, the plugin's `loopdy` ID) still
use that name. `Config/Local.xcconfig` is git-ignored. Simulator builds work with it empty. To run on a real
device, change the bundle IDs and app groups in `project.yml` to ones that your Apple team owns.

**No Hermes host?** Add these launch arguments to the scheme to use sample data:

```text
-use-demo-fixtures
-disable-demo-delays
```

**Run the Mac app on sample data:** `Scripts/mac-dev-run.sh --name <your name>`.

**Tests** (use an iPhone simulator that your Xcode has):

```sh
xcodebuild test -project Bighelp.xcodeproj -scheme Bighelp \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## What's where

| Path | What it is |
|---|---|
| `Bighelp/` | The app for iPhone, iPad, Mac and Apple Vision Pro |
| `BighelpWatch/`, `BighelpWatchShared/` | The Apple Watch app |
| `BighelpLiveActivity/`, `BighelpActivityShared/` | Widgets and Live Activities |
| `BighelpNotificationService/` | The notification service extension |
| `BighelpMacUpdater/` | The Mac app's updates (Sparkle) |
| `BighelpTests/`, `BighelpUITests/`, `BighelpVisionUITests/`, `BighelpWatchUITests/` | Tests |
| `BighelpMac/`, `BighelpMacTests/` | An early desktop prototype on sample data. It is not the Mac app. |
| `services/` | Cloudflare Workers: the notification service, usage and diagnostics, the template and avatar catalogs, and the provider logos (plus the recovered source of an old relay, never deployed). See [docs/CLOUDFLARE_INFRASTRUCTURE.md](docs/CLOUDFLARE_INFRASTRUCTURE.md) |
| `Scripts/` | Tests against real Hermes hosts, the Mac release, and other tools |
| `Design/AvatarKit/` | Avatar artwork and the tools that export it |
| `docs/` | Contracts and deep dives. Start with [ARCHITECTURE.md](docs/ARCHITECTURE.md), [NATIVE_TRANSPORT.md](docs/NATIVE_TRANSPORT.md) and [DEVELOPMENT.md](docs/DEVELOPMENT.md) |

[DESIGN.md](DESIGN.md) describes the look and feel. [AGENTS.md](AGENTS.md) is the guide for people and AI agents
that work on the code.

For an Android or other client port, start with the platform-neutral
[Hermes transport contract](docs/NATIVE_TRANSPORT.md), including API references,
recovery rules and portable conformance vectors.

## Contributing

Issues and pull requests are welcome. The maintainer reviews every change before it merges. See
[CONTRIBUTING.md](CONTRIBUTING.md).

Please report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

[Apache 2.0](LICENSE). Bundled third-party code keeps its own license: Sparkle (MIT), Phonon (MIT or Apache 2.0)
and WebRTC (BSD 3-Clause; the Apple Vision Pro build uses LiveKit's build of WebRTC). Provider logos belong to
their owners and only identify those providers.
