# Direct streaming and live voice

> Current transport contract: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). Its Link fallback and account-backed admission discussion describes an older transport. Where transport details differ, use the versioned native contract and its source links.

bighelp keeps Hermes as the execution and canonical-history owner. The native app uses bounded session pages and a separate disposable live overlay. Full tool content is retrieved only when you open its complete-content reader.

## Routes

A paired host can expose the plugin-owned listener through a private Tailscale HTTPS origin. Configure the plugin with `hermes loopdy direct configure --origin https://HOST:PORT --port LOOPBACK_PORT --enabled`, then restart Hermes when ready. In the app, select that host and use its optional Direct Connection section to verify and enroll the route. The account-paired identity is required; Tailscale membership alone is not authorization.

Direct requests reuse existing chat, workspace, attachments, approvals, voice and device-tool interfaces. A connection failure before a request can use Link. An ambiguously delivered command is not automatically repeated through another route. Direct admission uses a fresh device lifecycle lease from the account service, so this is not indefinite cloud-independent authorization.

State-backed relay clients explicitly negotiate `state-backed-presentation-v1`. Recoverable drafts and activity do not accumulate as an offline animation backlog for those recipients. Reliable commands, results, attachments and legacy clients retain their existing delivery contract. A slow subscriber receives a reset and reconnects without blocking another phone. Transient sequence tracking never advances the reliable replay watermark.

## Voice

Live voice is called **Full Duplex** in the app. Each agent has one voice type (TTS or Full Duplex), provider and
voice, kept on the device for its computer (`AgentVoiceChoices`). Settings › Voice, the bot's Default Voice in Bots
mode and the chat's voice button all read and change the same choice; with no computer connected, Settings › Voice
edits the defaults. The voice button starts the call at once, in both voice types, and End goes back to the chat.
The voice model is the agent itself: the plugin builds its brief from the agent's name and `SOUL.md`, so it speaks
in the first person and never says "your agent" or "Hermes".

### GPT-Live

GPT-Live defaults to **Codex subscription** (`gpt-live-1-codex`). The plugin uses Hermes-managed subscription credentials; the phone receives no bearer token. Native WebRTC carries audio directly to the provider while authenticated bighelp messages carry setup, captions and job controls. The provider sideband is connected before the answer SDP is returned.

Requests the voice model hands over never wait for each other, so you can keep talking while work runs (`NativeLiveVoiceSession`). A request runs as a turn in the open chat when the chat is free. One made while the chat is working runs at once as a Hermes background task for that chat (`prompt.background`), beside the running turn; its answer goes back to the call when it arrives (`background.complete`) and shows in the chat. A background task uses the agent's Hermes tools, but not the phone's (Device access reaches only the chat itself). The same request said twice shares one run. Muting, barge-in and ending the call do not cancel accepted work. Unknown admission outcomes are reported, never resubmitted.

An explicitly selected API-key mode uses the distinct public `gpt-live-1` protocol and the host's configured `OPENAI_API_KEY`. It may incur separate usage charges. Subscription errors never select it automatically. Turn-based voice remains an explicit alternative.

### Gemini Live

On plugins that list `native-voice-gemini-v1`, the plugin answers a Gemini offer with a single-use token made
from the agent's own `GEMINI_API_KEY` (the key stays on the host). The token locks the model, voice, brief and
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

The plugin does not modify Hermes core or start a second model-execution service. All jobs use supported platform-adapter ingress and lifecycle/approval/clarification callbacks. iPhone device tools remain opt-in and require the existing verified host-context capability; unsupported hosts do not gain authority from a voice transcript or device identifier.

Per-session protected content files replace repeated whole-catalog transcript writes. Migration retains the old snapshot until the new manifest commits. Failed writes preserve the prior committed content. Account erasure removes all scoped revisions.

## Validation boundaries

Automated verification covers state paging, content reconstruction, cache saturation, owner changes, independent jobs, subscription wire formatting, relay recipient isolation, native audio offer/answer handling and simulator UI. The subscription endpoint was exercised using actual Hermes-managed authentication with native SDP. Physical-device testing is not required for this release. Network conditions, Bluetooth/audio hardware and subjective conversational quality still warrant normal beta testing.
