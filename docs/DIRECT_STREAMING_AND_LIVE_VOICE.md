# Direct streaming and live voice

> Transport: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). This page covers streaming presentation and live voice only.

bighelp keeps Hermes as the execution and canonical-history owner. The native app uses bounded session pages and a separate disposable live overlay. Full tool content is retrieved only when you open its complete-content reader.

## Transport

The app talks straight to the person's Hermes host: REST sign-in, WebSocket JSON-RPC on the dashboard's `/api/ws`,
dashboard REST, and the plugin's HTTP routes under `/api/plugins/loopdy/native/…` (`loopdy` is the plugin's legacy
ID). There is no bighelp account, no relay and no second route to fall back to. A command whose delivery is unknown
is never sent again by itself. The full contract is in [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md).

The old bighelp Link transport (account pairing, a plugin-owned listener set up with a `hermes loopdy direct`
command, `state-backed-presentation-v1` relay negotiation) is retired, and chat no longer uses it.

## Voice

Live voice is called **Live** in the app (Settings › Voice › Mode; the other mode is **Take turns**). On plugins that list `native-voice-context-v1`, the offer
also carries who is talking and where (`LiveVoiceCallContext`): the agent's name as the app shows it, the
person's saved name, the phone's time zone and, only while Device access › Location is usable, a coarse place
(`LiveVoicePlace`; city, region, country, never coordinates). It comes from the last known fix when that is
under an hour old, else a fresh city-level fix (kilometer accuracy). The offer waits about 1 s at most, and a
slower search fills a 30-minute cache for the next call.
The plugin's brief uses them, keeps the phone's language until the person asks in words for another, and
treats each field as untrusted text. Each agent has one voice type (Take turns or Live), provider and
voice, kept on the device for its computer (`AgentVoiceChoices`). Settings › Voice, the bot's Default Voice in Bots
mode and the chat's voice button all read and change the same choice; with no computer connected, Settings › Voice
edits the defaults. The voice button starts the call at once, in both voice types, and End goes back to the chat.
The voice model is the agent itself: the plugin builds its brief from the agent's name and `SOUL.md`, so it speaks
in the first person and never says "your agent" or "Hermes".

### GPT-Live

GPT-Live defaults to **Codex subscription** (`gpt-live-1-codex`). The plugin uses Hermes-managed subscription credentials; the phone receives no bearer token. The phone's WebRTC peer (`BighelpRealtimeAudioPeer`) carries audio directly to the provider. Setup, captions and job controls go through the plugin's `voice/status`, `voice/offer`, `voice/poll`, `voice/result` and `voice/close` routes (feature `native-voice-v1`) on the signed-in host connection. The provider sideband is connected before the answer SDP is returned.

Requests the voice model hands over never wait for each other, so you can keep talking while work runs (`NativeLiveVoiceSession`). A request runs as a turn in the open chat when the chat is free. One made while the chat is working runs at once as a Hermes background task for that chat (`prompt.background`), beside the running turn; its answer goes back to the call when it arrives (`background.complete`) and shows in the chat. A background task uses the agent's Hermes tools, but not the phone's (Device access reaches only the chat itself). The same request said twice shares one run. Muting, barge-in and ending the call do not cancel accepted work. Unknown admission outcomes are reported, never resubmitted.

An explicitly selected API-key mode uses the distinct public `gpt-live-1` protocol and the host's configured `OPENAI_API_KEY`. It may incur separate usage charges. Subscription errors never select it automatically. Turn-based voice remains an explicit alternative.

### Gemini Live

On plugins that list `native-voice-gemini-v1`, the plugin answers a Gemini offer with a single-use token made
from the agent's own `GEMINI_API_KEY` or `GOOGLE_API_KEY` (the key stays on the host). The token locks the model, voice, brief and
tools. `GeminiLiveAudioPeer` opens the phone's own WebSocket to Gemini with it and sends only the model name, then
16 kHz microphone audio from one voice-processing `AVAudioEngine`, which cancels the agent's voice from the
microphone without muting it, so the person can talk over the agent.

Nothing goes through the host's feed. `GeminiLiveTranslator` turns Gemini's messages into the same call events
GPT-Live gets from `poll`, so `NativeLiveVoiceSession` routes work the same way:

- `start_work` is answered at once with "started", and the request runs like any delegation (a turn in the open
  chat, or a background task while the chat works). When the agent already said its line ("On it") in that turn,
  the answer is `SILENT`, so it doesn't acknowledge twice.
- Results go back as text that starts with `UPDATE`. Text sent to Gemini is answered at once and cuts off
  whatever it is saying, so `GeminiLiveAudioPeer` holds each update until nobody speaks: Gemini's own speech
  detection says the person stopped, its reply ended and its audio finished playing (`isQuiet`). Updates go one
  at a time, so the agent never cuts off one result to read the next.
- `check_work` is answered from the requests in flight and the last ones that finished.
- After a cut-in, Gemini ends the abandoned turn with an empty `turnComplete` before the reply to the cut-in;
  the translator ignores it.

A Gemini session lasts up to 30 minutes from its token; the call ends when Gemini closes the socket.
Gemini refuses a call the same way: it closes the socket with a code and its reason, for example
`1011 "Token has been used too many times"`, `1011 "new_session_expire_time deadline exceeded"` (the token's
60 seconds to start had passed) or `1008 "models/… is not found"`. The peer keeps them (`GeminiLiveClose`):
Gemini's code and reason, the HTTP status if it refused the socket's opening request, or the network error
if nothing came from Gemini. A call Gemini closed before it set the session up fails, and the call screen
shows Gemini's words; a working call that Gemini ends says why, when Gemini gave a reason. Each step (connecting,
setup sent, Gemini ready, goAway, the close) goes in the call's report, and the close goes in the
`LiveVoiceAudio` log at once. The call screen keeps the last call's report, so Copy report works after a
call that ended at once.

Voice processing makes a configuration change right after the engine starts, on iPhone and in the simulator. The
engine stops, and the peer starts it again (`GeminiLiveAudioPeer.restart`). The player stops first: started
again while it still said it was playing, it took every piece of Gemini's voice and played none, until Gemini
cut itself off and the player stopped. Each call keeps a call audio report: what Gemini sent, what was
scheduled and finished, the main mixer's output level, the engine, the session and the route, and each change
with its time (`GeminiLiveAudioDiagnostics`, also in the `LiveVoiceAudio` log every 10 s). Settings › Voice ›
Advanced, with Advanced options (`settings.nerdModeEnabled`) on, has a switch for each part the call screen shows (`LiveVoiceDebug`, both off at
first): Call sound report shows it once a second, and Copy report button puts Copy report there.
Restart sound, on the same page, stops and starts the player of the Gemini Live call in progress
only (`LiveVoiceCurrentCall`, a weak reference the call clears as it ends).

When Gemini interrupts a reply, the report keeps the last ten microphone-gate decisions at that moment:
RMS level, threshold, and whether the chunk was blocked, sent during playback, or sent while the agent
was quiet (`idle`). It keeps no audio or transcript. A new reply clears the gate's held speech and hangover
from the person's preceding turn; talking over the reply still opens it after two loud chunks.

## Team call

A group chat with two or more members can start a team call from its header (`Bighelp/TeamCall/`). It is turn-based
voice only: no realtime model. The button shows only when the host can speak for every member (`voiceOutput`).

- What the person says posts to the room through `BotModeRoomStore.send`, the composer's idempotent path. One
  message is in flight until the room log shows it, so messages land in the order they were said.
- Members' replies arrive as completed messages in the room log. Each is spoken in log order with that member's own
  `/api/audio/speak` voice (`DirectHermesVoiceSpeechOutput(profileID:)`), so every agent keeps its own `tts.*`.
- `TeamCallSpeechPipeline` makes the next pieces' audio while one plays. A reply is cut like Hermes'
  `SentenceChunker`: the first sentence of at least `tts.streaming.min_len` characters (default 20) goes alone.
- The microphone stays on between replies. While a reply plays, the device recognizer listens for barge-in
  (`voice.barge_in`, `barge_in_grace_seconds`, `barge_in_threshold_multiplier`, echo filtering); cutting in stops
  playback and drops the queue. `voice.silence_duration` caps the end-of-turn pause, and saying exactly a
  `voice.stop_phrases` entry hangs up. The first member whose config is readable supplies `voice.*`.
- Hanging up never sends `groups.stop`; the room keeps working.

## Security and compatibility

The plugin does not modify Hermes core or start a second model-execution service. Voice work runs on the chat's own socket, as an ordinary turn (`prompt.submit`) or a Hermes background task (`prompt.background`), with Hermes' own approval and clarification requests. iPhone device tools remain opt-in and require the existing verified host-context capability; unsupported hosts do not gain authority from a voice transcript or device identifier.

Per-session protected content files replace repeated whole-catalog transcript writes. Migration retains the old snapshot until the new manifest commits. Failed writes preserve the prior committed content. Account erasure removes all scoped revisions.

## Validation boundaries

Automated verification covers state paging, content reconstruction, cache saturation, owner changes, independent jobs, subscription wire formatting, native audio offer/answer handling and simulator UI. The subscription endpoint was exercised using actual Hermes-managed authentication with native SDP. Physical-device testing is not required for this release. Network conditions, Bluetooth/audio hardware and subjective conversational quality still warrant normal beta testing.
