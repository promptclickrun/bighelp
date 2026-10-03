import CryptoKit
import Foundation
import Testing
@testable import Bighelp

struct BighelpLinkWireTests {

    @Test func legacyInboxAndDashboardDeepLinksResolveToHome() throws {
        for value in [
            "loopdy://inbox",
            "app.loopdy.mobile://inbox",
            "loopdy:///dashboard?eventId=channel.message%3Afixture",
        ] {
            let url = try #require(URL(string: value))
            #expect(BighelpIncomingURLRoute.parse(url) == .home)
        }
    }

    /// The retired pairing links open nothing; chat links still work.
    @Test func retiredPairingLinksOpenNothing() {
        let commitment = BighelpLinkBase64URL.encode(Data(repeating: 0x2A, count: 32))
        for value in [
            "loopdy://link/pair?flow=flow_fixture_0123456789012345&code=ABC234&kc=\(commitment)",
            "app.loopdy.mobile://link/pair?flow=flow_fixture_0123456789012345&code=ABC234&kc=\(commitment)",
            "loopdy://link/pair?code=ABC234",
        ] {
            #expect(BighelpIncomingURLRoute.parse(URL(string: value)!) == nil)
        }
        #expect(
            BighelpIncomingURLRoute.parse(URL(string: "loopdy://chat/session_fixture_0001")!)
                == .chat(sessionID: "session_fixture_0001")
        )
    }

    @Test func assistantMessagesRequireAStableSessionAndDeliveryCoordinate() throws {
        let final = try BighelpLinkAssistantMessage.decode([
            "version": 1,
            "type": "assistant.message",
            "messageId": "message_fixture_0002",
            "sessionId": "session_fixture_0001",
            "agentId": "finance",
            "agentName": "Avery Park",
            "text": "Done.",
            "sentAt": 1_788_000_001,
            "delivery": "final",
        ])
        let draft = try BighelpLinkAssistantMessage.decode([
            "version": 1,
            "type": "assistant.message",
            "messageId": "message_fixture_0003",
            "sessionId": "session_fixture_0001",
            "agentId": "finance",
            "agentName": "Avery Park",
            "text": "Work in progress",
            "sentAt": 1_788_000_001,
            "delivery": "draft",
            "draftId": 4,
        ])

        #expect(final.delivery == .final)
        #expect(final.agentID == "finance")
        #expect(final.draftID == nil)
        #expect(draft.delivery == .draft)
        #expect(draft.draftID == 4)
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkAssistantMessage.decode([
                "version": 1,
                "type": "assistant.message",
                "messageId": "short",
                "sessionId": "session_fixture_0001",
                "agentId": "finance",
                "agentName": "Avery Park",
                "text": "No",
                "sentAt": 1,
                "delivery": "final",
            ])
        }
    }

    @Test func assistantMessagesCarryOptionalRequestAndTurnOwnership() throws {
        let message = try BighelpLinkAssistantMessage.decode([
            "version": 1,
            "type": "assistant.message",
            "messageId": "message_host_fixture_0001",
            "requestId": "message_fixture_request_0001",
            "sessionId": "session_fixture_0001",
            "turnId": "turn_fixture_0000001",
            "agentId": "finance",
            "agentName": "Avery Park",
            "text": "Done.",
            "sentAt": 1_788_000_001,
            "delivery": "final",
        ])

        #expect(message.requestID == "message_fixture_request_0001")
        #expect(message.turnID == "turn_fixture_0000001")
    }

    @Test func proactiveNotificationEventsAreStrictBoundedAndSessionAware() throws {
        let data = Data(
            """
            {
              "version": 1,
              "type": "notification.event",
              "eventId": "channel.message:0123456789abcdef0123456789abcdef",
              "eventType": "channel.message",
              "agentId": "default",
              "agentName": "Juno",
              "sessionId": "session_fixture_0001",
              "title": "Juno just messaged you!",
              "body": "Message: The forecast is ready.",
              "sentAt": 1788000001
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(BighelpLinkNotificationEvent.self, from: data)
        #expect(event.eventID == "channel.message:0123456789abcdef0123456789abcdef")
        #expect(event.eventType == "channel.message")
        #expect(event.agentID == "default")
        #expect(event.agentName == "Juno")
        #expect(event.sessionID == "session_fixture_0001")
        #expect(event.title == "Juno just messaged you!")
        #expect(event.body == "Message: The forecast is ready.")
        #expect(event.sentAt == 1_788_000_001)

        let unsafe = Data(
            """
            {
              "version": 1,
              "type": "notification.event",
              "eventId": "channel.message:0123456789abcdef0123456789abcdef",
              "eventType": "channel.message",
              "agentId": "default",
              "agentName": "Juno",
              "title": "Update",
              "body": "Ready",
              "sentAt": 1788000001,
              "privateArguments": "must not cross"
            }
            """.utf8
        )
        #expect(throws: BighelpLinkWireError.self) {
            try JSONDecoder().decode(BighelpLinkNotificationEvent.self, from: unsafe)
        }
    }

    @Test func proactiveNotificationEventsCanCarryOneValidatedNativeCard() throws {
        let data = Data(
            """
            {
              "version": 1,
              "type": "notification.event",
              "eventId": "channel.message:0123456789abcdef0123456789abcdef",
              "eventType": "channel.message",
              "agentId": "default",
              "agentName": "Juno",
              "title": "Morning briefing",
              "body": "Open bighelp to view the briefing.",
              "sentAt": 1788000001,
              "card": {
                "schema": "loopdy.generative_ui",
                "version": 1,
                "component": "summary",
                "title": "Morning briefing",
                "body": "Three priorities are ready."
              }
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(BighelpLinkNotificationEvent.self, from: data)
        #expect(event.card?.title == "Morning briefing")
        #expect(event.card?.component == .summary)
    }

    @Test func proactiveNotificationFallsBackToTextWhenItsOptionalCardIsInvalid() throws {
        let data = Data(
            """
            {
              "version": 1,
              "type": "notification.event",
              "eventId": "channel.message:0123456789abcdef0123456789abcdef",
              "eventType": "channel.message",
              "agentId": "default",
              "agentName": "Juno",
              "title": "Morning briefing",
              "body": "Three priorities are ready in text.",
              "sentAt": 1788000001,
              "card": {
                "schema": "loopdy.generative_ui",
                "version": 1,
                "component": "html",
                "title": "Unsafe",
                "url": "https://unsafe.example"
              }
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(BighelpLinkNotificationEvent.self, from: data)
        #expect(event.title == "Morning briefing")
        #expect(event.body == "Three priorities are ready in text.")
        #expect(event.card == nil)
    }

    @Test func voiceSpeechContractsBindAudioToTheExactRequestAndVerifyItsDigest() throws {
        let request = BighelpLinkVoiceSpeakRequest(
            requestID: "voice_request_fixture_0001",
            sessionID: "session_fixture_0001",
            agentID: "finance",
            text: "Read this answer aloud.",
            speed: 1.15,
            sentAt: 1_788_000_002
        )
        let encoded = try JSONEncoder().encode(request)
        let value = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(value["type"] as? String == "voice.speak.request")
        #expect(value["requestId"] as? String == "voice_request_fixture_0001")
        #expect(value["speed"] as? Double == 1.15)

        let audio = Data("fixture audio".utf8)
        let digest = BighelpLinkBase64URL.encode(Data(SHA256.hash(data: audio)))
        let chunk = try BighelpLinkVoiceAudioChunk.decode([
            "version": 1,
            "type": "voice.speak.chunk",
            "requestId": "voice_request_fixture_0001",
            "sessionId": "session_fixture_0001",
            "agentId": "finance",
            "index": 0,
            "count": 1,
            "mimeType": "audio/mpeg",
            "provider": "ElevenLabs",
            "totalBytes": audio.count,
            "sha256": digest,
            "audio": BighelpLinkBase64URL.encode(audio),
            "sentAt": 1_788_000_003,
        ])

        #expect(chunk.audio == audio)
        #expect(chunk.sha256 == digest)
        #expect(chunk.provider == "ElevenLabs")
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkVoiceAudioChunk.decode([
                "version": 1,
                "type": "voice.speak.chunk",
                "requestId": "voice_request_fixture_0001",
                "sessionId": "session_fixture_0001",
                "agentId": "finance",
                "index": 1,
                "count": 1,
                "mimeType": "audio/mpeg",
                "provider": "ElevenLabs",
                "totalBytes": audio.count,
                "sha256": digest,
                "audio": BighelpLinkBase64URL.encode(audio),
                "sentAt": 1_788_000_003,
            ])
        }
    }

    @Test func activityEventsRequireExactHermesCoordinatesAndBoundedPresentationFields() throws {
        let event = try BighelpLinkActivityEvent.decode([
            "version": 1,
            "type": "activity.event",
            "eventId": "tool_event_fixture_0001",
            "sessionId": "session_fixture_0001",
            "turnId": "turn_fixture_0000001",
            "kind": "tool",
            "lifecycle": "running",
            "title": "Checking weather",
            "summary": "weather for Chicago",
            "arguments": #"{"city":"Chicago"}"#,
            "result": "Forecast returned.\n```json\n{\"temperature\":72}\n```",
            "toolCallId": "call_weather_fixture_01",
            "toolName": "weather",
            "occurredAt": 1_788_000_004,
        ])

        #expect(event.chatEvent.kind == .tool)
        #expect(event.chatEvent.toolCallID == "call_weather_fixture_01")
        #expect(event.chatEvent.toolName == "weather")
        #expect(event.chatEvent.turnID == "turn_fixture_0000001")
        #expect(event.chatEvent.arguments == #"{"city":"Chicago"}"#)
        #expect(event.chatEvent.result == "Forecast returned.\n```json\n{\"temperature\":72}\n```")

        let inboundData = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "type": "activity.event",
            "eventId": "tool_event_fixture_0001",
            "sessionId": "session_fixture_0001",
            "turnId": "turn_fixture_0000001",
            "kind": "tool",
            "lifecycle": "running",
            "title": "Checking weather",
            "toolCallId": "call_weather_fixture_01",
            "toolName": "weather",
            "occurredAt": 1_788_000_004,
        ])
        let decodedInboundEvent = try JSONDecoder().decode(BighelpLinkActivityEvent.self, from: inboundData)
        #expect(decodedInboundEvent.chatEvent.toolName == "weather")

        let agentBoundEvent = try BighelpLinkActivityEvent.decode([
            "version": 1,
            "type": "activity.event",
            "eventId": "tool_event_fixture_0003",
            "sessionId": "session_fixture_0001",
            "turnId": "turn_fixture_0000001",
            "kind": "tool",
            "lifecycle": "running",
            "title": "Checking weather",
            "toolCallId": "call_weather_fixture_02",
            "agentId": "finance",
            "occurredAt": 1_788_000_004,
        ])
        #expect(agentBoundEvent.agentID == "finance")

        let handoff = try BighelpLinkActivityEvent.decode([
            "version": 1,
            "type": "activity.event",
            "eventId": "handoff_event_fixture_0001",
            "sessionId": "session_fixture_0001",
            "turnId": "turn_fixture_0000001",
            "kind": "bot_handoff",
            "lifecycle": "running",
            "title": "Contacting Nova",
            "summary": "Message sent to @nova",
            "arguments": "Review this.",
            "botRunId": "agent_message_call_0001",
            "memberId": "nova",
            "fromMemberId": "default",
            "occurredAt": 1_788_000_004,
        ])
        #expect(handoff.chatEvent.memberID == "nova")
        #expect(handoff.chatEvent.fromMemberID == "default")
        #expect(handoff.chatEvent.arguments == "Review this.")
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "handoff_event_fixture_0002",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "bot_handoff",
                "lifecycle": "running",
                "title": "Oversized collaboration request",
                "arguments": String(repeating: "x", count: 64_001),
                "botRunId": "agent_message_call_0002",
                "memberId": "nova",
                "fromMemberId": "default",
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "tool_event_fixture_0005",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "tool",
                "lifecycle": "running",
                "title": "Malformed source identity",
                "toolCallId": "call_weather_fixture_05",
                "fromMemberId": "default",
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "tool_event_fixture_0002",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "tool",
                "lifecycle": "running",
                "title": "Missing canonical tool identity",
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "reason_event_fixture_02",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "reasoning",
                "lifecycle": "running",
                "title": "Thinking",
                "toolName": "must_not_bind_to_reasoning",
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "reason_event_fixture_02b",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "reasoning",
                "lifecycle": "running",
                "title": "Thinking",
                "arguments": "tool-only detail",
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "tool_event_fixture_0004",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "tool",
                "lifecycle": "running",
                "title": "Oversized tool detail",
                "toolCallId": "call_weather_fixture_04",
                "result": String(repeating: "x", count: 65_537),
                "occurredAt": 1_788_000_004,
            ])
        }
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkActivityEvent.decode([
                "version": 1,
                "type": "activity.event",
                "eventId": "reason_event_fixture_01",
                "sessionId": "session_fixture_0001",
                "turnId": "turn_fixture_0000001",
                "kind": "reasoning",
                "lifecycle": "running",
                "title": "Thinking",
                "summary": String(repeating: "x", count: 501),
                "occurredAt": 1_788_000_004,
            ])
        }
    }

    @Test func generativeUICardsPersistInTimeline() throws {
        let data = Data(
            """
            {
              "version": 1,
              "type": "generative.ui",
              "eventId": "card_event_fixture_0001",
              "sessionId": "session_fixture_0001",
              "turnId": "turn_fixture_0000001",
              "toolCallId": "call_weather_fixture_01",
              "agentId": "finance",
              "agentName": "Avery Park",
              "occurredAt": 1788000004,
              "card": {
                "schema": "loopdy.generative_ui",
                "version": 1,
                "component": "summary",
                "title": "Weather ready",
                "body": "Clear skies through this afternoon."
              }
            }
            """.utf8
        )

        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let card = try JSONDecoder().decode(GenerativeUICard.self,
            from: JSONSerialization.data(withJSONObject: try #require(value["card"])))
        #expect(card.component == .summary)
        #expect(card.title == "Weather ready")
        let item = TimelineItem(id: "card_event_fixture_0001", role: .assistant,
            sender: .agent(id: "finance", snapshot: .init(name: "Avery Park", avatarFileName: "avery.png")),
            content: .generativeUI(card), metadata: .init())
        let roundTrip = try JSONDecoder().decode(
            TimelineItem.self,
            from: JSONEncoder().encode(item)
        )
        #expect(roundTrip == item)
        #expect(roundTrip.content.kind == .generativeUI)
    }

    @Test func generativeUICardsRejectExecutableFieldsAndUnsupportedComponents() {
        let unsafe = Data(
            """
            {
              "version": 1,
              "type": "generative.ui",
              "eventId": "card_event_fixture_0002",
              "sessionId": "session_fixture_0001",
              "turnId": "turn_fixture_0000001",
              "toolCallId": "call_weather_fixture_01",
              "agentId": "finance",
              "agentName": "Avery Park",
              "occurredAt": 1788000004,
              "card": {
                "schema": "loopdy.generative_ui",
                "version": 1,
                "component": "html",
                "title": "Unsafe",
                "url": "https://unsafe.example"
              }
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            let value = try #require(JSONSerialization.jsonObject(with: unsafe) as? [String: Any])
            _ = try JSONDecoder().decode(GenerativeUICard.self,
                from: JSONSerialization.data(withJSONObject: try #require(value["card"])))
        }
    }

    @Test func generativeUIFormActionsEncodeValuesAndDecodeOnlyTheBoundResult() throws {
        let submission = try BighelpLinkGenerativeUIFormSubmission(
            requestID: String(repeating: "a", count: 32),
            sessionID: "session_fixture_0001",
            profile: "personal",
            idempotencyKey: UUID(uuidString: "123e4567-e89b-42d3-a456-426614174000")!,
            values: [
                "departure_day": .string("friday"),
                "bags": .integer(2),
                "flexible": .boolean(true),
            ],
            submittedAt: 1_788_000_005
        )
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any]
        )
        #expect(Set(encoded.keys) == Set([
            "version", "type", "requestId", "sessionId", "profile",
            "idempotencyKey", "values", "submittedAt",
        ]))
        #expect(encoded["type"] as? String == "generative.ui.form.submit")
        #expect((encoded["values"] as? [String: Any])?["bags"] as? Int == 2)

        let resultData = Data(
            """
            {
              "version": 1,
              "type": "generative.ui.form.result",
              "requestId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "sessionId": "session_fixture_0001",
              "idempotencyKey": "123e4567-e89b-42d3-a456-426614174000",
              "state": "success",
              "code": "accepted",
              "message": "Form response accepted.",
              "sentAt": 1788000006
            }
            """.utf8
        )
        let result = try JSONDecoder().decode(BighelpLinkGenerativeUIFormResult.self, from: resultData)
        #expect(result.requestID == submission.requestID)
        #expect(result.sessionID == submission.sessionID)
        #expect(result.idempotencyKey == submission.idempotencyKey)
        #expect(result.state == .success)
        #expect(result.code == "accepted")

        let unbound = Data(
            String(decoding: resultData, as: UTF8.self)
                .replacingOccurrences(of: "\"sentAt\": 1788000006", with: "\"extra\": true, \"sentAt\": 1788000006")
                .utf8
        )
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(BighelpLinkGenerativeUIFormResult.self, from: unbound)
        }
    }

    @Test func generativeUIV2FormsPermitOnlyTheNativeBoundSubmitAction() throws {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "form",
              "title": "Trip preference",
              "data": {
                "description": "Choose a departure day.",
                "submit_label": "Send preference",
                "fields": [
                  {
                    "id": "departure_day",
                    "kind": "select",
                    "label": "Departure day",
                    "required": true,
                    "default": "friday",
                    "options": [
                      {"id": "friday", "label": "Friday"},
                      {"id": "saturday", "label": "Saturday"}
                    ]
                  }
                ]
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "action": {
                "kind": "submit_form",
                "request_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "owner": {
                  "profile": "personal",
                  "session_id": "session_fixture_0001"
                },
                "expires_at": "2026-08-29T12:05:00Z"
              }
            }
            """.utf8
        )

        let card = try JSONDecoder().decode(GenerativeUICard.self, from: data)

        #expect(card.component == .form)
        #expect(card.action?["request_id"]?.string == String(repeating: "a", count: 32))
        #expect(card.action?["owner"]?.object?["profile"]?.string == "personal")
        let action = try #require(card.action)
        let owner = try #require(action["owner"]?.object)
        let field = try #require(card.data["fields"]?.array?.first?.object)
        let submission = try BighelpLinkGenerativeUIFormSubmission(
            requestID: try #require(action["request_id"]?.string),
            sessionID: try #require(owner["session_id"]?.string),
            profile: try #require(owner["profile"]?.string),
            values: [
                try #require(field["id"]?.string): try #require(field["default"]),
            ],
            submittedAt: 1_788_000_005
        )
        #expect(submission.values == ["departure_day": .string("friday")])
    }

    @Test func generativeUIV2FormsRejectFieldsTheRendererCannotConstruct() {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "form",
              "title": "Trip preference",
              "data": {
                "submit_label": "Send preference",
                "fields": [
                  {
                    "id": "departure_day",
                    "type": "select",
                    "label": "Departure day"
                  }
                ]
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "action": {
                "kind": "submit_form",
                "request_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "owner": {
                  "profile": "personal",
                  "session_id": "session_fixture_0001"
                },
                "expires_at": "2026-08-29T12:05:00Z"
              }
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2FormsRejectActionsTheRendererCannotBind() {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "form",
              "title": "Trip preference",
              "data": {
                "submit_label": "Send preference",
                "fields": [
                  {
                    "id": "departure_day",
                    "kind": "text",
                    "label": "Departure day",
                    "required": true
                  }
                ]
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "action": {
                "kind": "submit_form",
                "request_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "owner": {
                  "profile": "personal"
                },
                "expires_at": "not-a-date"
              }
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2FormsRejectFieldIDsTheOutboundSubmissionCannotEncode() {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "form",
              "title": "Trip preference",
              "data": {
                "submit_label": "Send preference",
                "fields": [{
                  "id": "Departure Day",
                  "kind": "text",
                  "label": "Departure day",
                  "required": true,
                  "default": "Friday"
                }]
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "action": {
                "kind": "submit_form",
                "request_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "owner": {
                  "profile": "personal",
                  "session_id": "session_fixture_0001"
                },
                "expires_at": "2026-08-29T12:05:00Z"
              }
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2FormsRejectOwnerCoordinatesTheOutboundSubmissionCannotEncode() {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "form",
              "title": "Trip preference",
              "data": {
                "submit_label": "Send preference",
                "fields": [{
                  "id": "departure_day",
                  "kind": "text",
                  "label": "Departure day",
                  "required": true,
                  "default": "Friday"
                }]
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "action": {
                "kind": "submit_form",
                "request_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "owner": {
                  "profile": "personal profile",
                  "session_id": "short"
                },
                "expires_at": "2026-08-29T12:05:00Z"
              }
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2FormsRejectMultiSelectsThatCanExceedTheOutboundArrayLimit() throws {
        let options = (1...11).map { index in
            ["id": "option_\(index)", "label": "Option \(index)"]
        }
        let payload: [String: Any] = [
            "schema": "loopdy.generative_ui",
            "version": 2,
            "component": "form",
            "title": "Trip preferences",
            "data": [
                "submit_label": "Send preferences",
                "fields": [[
                    "id": "preferences",
                    "kind": "multi_select",
                    "label": "Preferences",
                    "required": true,
                    "options": options,
                ]],
            ],
            "content_hash": String(repeating: "b", count: 64),
            "created_at": "2026-08-29T12:00:00Z",
            "origin": "live",
            "card_id": String(repeating: "a", count: 32),
            "action": [
                "kind": "submit_form",
                "request_id": String(repeating: "a", count: 32),
                "owner": [
                    "profile": "personal",
                    "session_id": "session_fixture_0001",
                ],
                "expires_at": "2026-08-29T12:05:00Z",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2FormsRejectDefaultsOverTheOutboundEightKiBLimit() throws {
        let fields: [[String: Any]] = (1...5).map { index in
            [
                "id": "response_\(index)",
                "kind": "textarea",
                "label": "Response \(index)",
                "required": true,
                "default": String(repeating: "x", count: 2_000),
            ]
        }
        let payload: [String: Any] = [
            "schema": "loopdy.generative_ui",
            "version": 2,
            "component": "form",
            "title": "Detailed responses",
            "data": [
                "submit_label": "Send responses",
                "fields": fields,
            ],
            "content_hash": String(repeating: "b", count: 64),
            "created_at": "2026-08-29T12:00:00Z",
            "origin": "live",
            "card_id": String(repeating: "a", count: 32),
            "action": [
                "kind": "submit_form",
                "request_id": String(repeating: "a", count: 32),
                "owner": [
                    "profile": "personal",
                    "session_id": "session_fixture_0001",
                ],
                "expires_at": "2026-08-29T12:05:00Z",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GenerativeUICard.self, from: data)
        }
    }

    @Test func generativeUIV2NonFormCardsRemainValidWithoutAnAction() throws {
        let data = Data(
            """
            {
              "schema": "loopdy.generative_ui",
              "version": 2,
              "component": "stock_quote",
              "title": "Acme quote",
              "data": {
                "symbol": "ACME",
                "company_name": "Acme Corp",
                "price": 42.5
              },
              "provenance": {
                "source": "market-feed"
              },
              "content_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "created_at": "2026-08-29T12:00:00Z",
              "origin": "live",
              "card_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }
            """.utf8
        )

        let card = try JSONDecoder().decode(GenerativeUICard.self, from: data)

        #expect(card.component == .stockQuote)
        #expect(card.action == nil)
    }

    @Test func pickerContractsCarryOnlyBoundedSessionControlsAndSafeCatalogFields() throws {
        let open = BighelpLinkPickerOpenRequest(
            requestID: "picker_request_fixture_0001",
            sessionID: "session_fixture_0001",
            agentID: "finance",
            kind: .model,
            sentAt: 1_788_000_005
        )
        let selection = try BighelpLinkPickerSelection(
            pickerID: open.requestID,
            sessionID: open.sessionID,
            kind: .model,
            provider: "openai-codex",
            model: "gpt-5.6",
            value: nil,
            sentAt: 1_788_000_006
        )
        let openValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(open)) as? [String: Any]
        )
        let selectionValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any]
        )
        let model = try JSONDecoder().decode(
            BighelpLinkModelPicker.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.model",
                  "pickerId": "picker_request_fixture_0001",
                  "sessionId": "session_fixture_0001",
                  "currentModel": "gpt-5.5",
                  "currentProvider": "openai-codex",
                  "providers": [
                    {
                      "id": "openai-codex",
                      "name": "OpenAI Codex",
                      "isCurrent": true,
                      "isCustom": false,
                      "models": ["gpt-5.6", "gpt-5.5"]
                    }
                  ],
                  "sentAt": 1788000007
                }
                """.utf8
            )
        )
        let reasoning = try JSONDecoder().decode(
            BighelpLinkChoicePicker.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.choice",
                  "pickerId": "picker_request_fixture_0002",
                  "sessionId": "session_fixture_0001",
                  "kind": "reasoning",
                  "title": "Reasoning effort · Medium",
                  "choices": [
                    {"value": "low", "label": "Low", "isCurrent": false},
                    {"value": "medium", "label": "Medium", "isCurrent": true}
                  ],
                  "sentAt": 1788000008
                }
                """.utf8
            )
        )

        #expect(openValue["type"] as? String == "picker.open")
        #expect(openValue["kind"] as? String == "model")
        #expect(selectionValue["type"] as? String == "picker.select")
        #expect(selectionValue["provider"] as? String == "openai-codex")
        #expect(selectionValue["value"] == nil)
        #expect(model.currentModel == "gpt-5.5")
        #expect(model.providers.first?.models == ["gpt-5.6", "gpt-5.5"])
        #expect(reasoning.choices.first(where: \.isCurrent)?.value == "medium")
    }

    @Test func existingTwelveCharacterHermesSessionIDsRemainValid() throws {
        let sessionID = "abc123def456"
        let selection = try BighelpLinkPickerSelection(
            pickerID: "picker_request_fixture_short_0001",
            sessionID: sessionID,
            kind: .model,
            provider: "openai-codex",
            model: "gpt-5.6",
            value: nil,
            sentAt: 1_788_000_006
        )
        let commandRequest = try BighelpLinkSlashCommandCatalogRequest(
            requestID: "commands_request_fixture_short_0001",
            sessionID: sessionID,
            agentID: "juno",
            sentAt: 1_788_000_007
        )
        let picker = try JSONDecoder().decode(
            BighelpLinkModelPicker.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.model",
                  "pickerId": "picker_request_fixture_short_0001",
                  "sessionId": "abc123def456",
                  "currentModel": "gpt-5.6",
                  "currentProvider": "openai-codex",
                  "providers": [
                    {
                      "id": "openai-codex",
                      "name": "OpenAI Codex",
                      "isCurrent": true,
                      "isCustom": false,
                      "models": ["gpt-5.6"]
                    }
                  ],
                  "sentAt": 1788000008
                }
                """.utf8
            )
        )

        #expect(selection.sessionID == sessionID)
        #expect(commandRequest.sessionID == sessionID)
        #expect(picker.sessionID == sessionID)
    }

    @Test func modelPickerAcceptsPrintableNamedModelsWithSpaces() throws {
        let picker = try JSONDecoder().decode(
            BighelpLinkModelPicker.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.model",
                  "pickerId": "picker_request_fixture_0001",
                  "sessionId": "session_fixture_0001",
                  "currentModel": "Hermes 4 405B",
                  "currentProvider": "nous",
                  "providers": [
                    {
                      "id": "nous",
                      "name": "Nous Research",
                      "isCurrent": true,
                      "isCustom": false,
                      "models": ["Hermes 4 405B", "Hermes 4 70B"]
                    }
                  ],
                  "sentAt": 1788000007
                }
                """.utf8
            )
        )

        #expect(picker.currentModel == "Hermes 4 405B")
        #expect(picker.providers.first?.models == ["Hermes 4 405B", "Hermes 4 70B"])
    }

    @Test func modelPickerSelectionAcceptsPrintableNamedModelsWithSpaces() throws {
        let selection = try BighelpLinkPickerSelection(
            pickerID: "picker_request_fixture_0001",
            sessionID: "session_fixture_0001",
            kind: .model,
            provider: "nous",
            model: "Hermes 4 405B",
            value: nil,
            sentAt: 1_788_000_006
        )

        #expect(selection.model == "Hermes 4 405B")
    }

    @Test func pickerDecodingRejectsUnknownFieldsAndMismatchedSelections() throws {
        #expect(throws: BighelpLinkWireError.self) {
            try JSONDecoder().decode(
                BighelpLinkModelPicker.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "picker.model",
                      "pickerId": "picker_request_fixture_0001",
                      "sessionId": "session_fixture_0001",
                      "currentModel": "gpt-5.5",
                      "currentProvider": "openai-codex",
                      "providers": [{"id":"openai-codex","name":"OpenAI","isCurrent":true,"isCustom":false,"models":["gpt-5.5"]}],
                      "apiKey": "never",
                      "sentAt": 1788000007
                    }
                    """.utf8
                )
            )
        }
        #expect(throws: BighelpLinkWireError.self) {
            _ = try BighelpLinkPickerSelection(
                pickerID: "picker_request_fixture_0002",
                sessionID: "session_fixture_0001",
                kind: .reasoning,
                provider: "openai-codex",
                model: "gpt-5.6",
                value: nil,
                sentAt: 1_788_000_009
            )
        }
    }

    @Test func sessionForkContractsBindAnExactCheckpointAndNeverCarryTranscriptText() throws {
        let checkpoint = SessionForkCheckpoint(
            userTurn: 2,
            role: .assistant,
            content: "Second answer"
        )
        let request = try BighelpLinkSessionForkRequest(
            requestID: "fork_request_fixture_0001",
            sourceSessionID: "source_session_fixture_0001",
            forkSessionID: "fork_session_fixture_000001",
            agentID: "finance",
            actorID: "family-member-1",
            actorName: "Alex",
            deviceName: "Kitchen iPad",
            checkpoint: checkpoint,
            title: "Budget review · Fork",
            sentAt: 1_788_000_010
        )
        let requestValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let result = try JSONDecoder().decode(
            BighelpLinkSessionForkResult.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "session.fork.result",
                  "requestId": "fork_request_fixture_0001",
                  "sourceSessionId": "source_session_fixture_0001",
                  "forkSessionId": "fork_session_fixture_000001",
                  "status": "completed",
                  "title": "Budget review · Fork",
                  "message": "Fork ready.",
                  "sentAt": 1788000011
                }
                """.utf8
            )
        )

        #expect(requestValue["type"] as? String == "session.fork.request")
        #expect(requestValue["userTurn"] as? Int == 2)
        #expect(requestValue["checkpointRole"] as? String == "assistant")
        #expect((requestValue["checkpointDigest"] as? String)?.count == 43)
        #expect(requestValue["text"] == nil)
        #expect(result.status == .completed)
        #expect(result.forkSessionID == request.forkSessionID)
        #expect(result.title == "Budget review · Fork")
    }

    @Test func slashCommandCatalogIsSessionBoundStrictAndCarriesNoExecutionSecrets() throws {
        let request = try BighelpLinkSlashCommandCatalogRequest(
            requestID: "commands_request_fixture_0001",
            sessionID: "session_fixture_0001",
            agentID: "juno",
            sentAt: 1_788_000_020
        )
        let value = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let catalog = try JSONDecoder().decode(
            BighelpLinkSlashCommandCatalog.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "commands.catalog",
                  "requestId": "commands_request_fixture_0001",
                  "sessionId": "session_fixture_0001",
                  "agentId": "juno",
                  "commands": [
                    {
                      "name": "help",
                      "description": "Show available commands",
                      "category": "Help",
                      "argsHint": "[query]",
                      "aliases": ["commands"],
                      "argumentMode": "text",
                      "source": "core",
                      "requiresArguments": false
                    }
                  ],
                  "sentAt": 1788000021
                }
                """.utf8
            )
        )

        #expect(value["type"] as? String == "commands.catalog.request")
        #expect(value["sessionId"] as? String == request.sessionID)
        #expect(value["token"] == nil)
        #expect(catalog.commands.first?.name == "help")
        #expect(catalog.commands.first?.aliases == ["commands"])
        #expect(catalog.commands.first?.source == .core)
        #expect(catalog.agentID == request.agentID)

        #expect(throws: BighelpLinkWireError.self) {
            try JSONDecoder().decode(
                BighelpLinkSlashCommandCatalog.self,
                from: Data(
                    """
                    {
                      "version": 1,
                      "type": "commands.catalog",
                      "requestId": "commands_request_fixture_0001",
                      "sessionId": "session_fixture_0001",
                      "agentId": "juno",
                      "commands": [],
                      "gatewayToken": "never",
                      "sentAt": 1788000021
                    }
                    """.utf8
                )
            )
        }
    }

    @Test func userMessageBehaviorUsesCanonicalWireValuesAndRemainsOptional() throws {
        func message(
            id: String,
            behavior: BighelpLinkUserMessageBehavior? = nil
        ) -> BighelpLinkUserMessage {
            BighelpLinkUserMessage(
                messageID: id,
                sessionID: "session_fixture_behavior_0001",
                agentID: "finance",
                actorID: "loopdy-user",
                actorName: "Alex",
                deviceName: "Alex's iPhone",
                text: "Change course",
                behavior: behavior,
                sentAt: 1_788_000_040
            )
        }

        let ordinary = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(message(id: "message_fixture_behavior_0001"))
            ) as? [String: Any]
        )
        #expect(ordinary["behavior"] == nil)

        for behavior in [
            BighelpLinkUserMessageBehavior.steer,
            .queue,
            .interrupt,
        ] {
            let value = try #require(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(
                        message(
                            id: "message_fixture_behavior_\(behavior.rawValue)",
                            behavior: behavior
                        )
                    )
                ) as? [String: Any]
            )
            #expect(value["behavior"] as? String == behavior.rawValue)
        }
    }

    @Test func attachmentChunksAndMessageReferencesAreBoundByDigestAndCarryNoLocalPaths() throws {
        let digest = String(repeating: "A", count: 43)
        let reference = try BighelpLinkAttachmentReference(
            attachmentID: "attachment_fixture_0001",
            fileName: "forecast.png",
            mimeType: "image/png",
            totalBytes: 4,
            sha256: digest
        )
        let chunk = try BighelpLinkAttachmentChunk(
            uploadID: "upload_fixture_00000001",
            sessionID: "session_fixture_0001",
            agentID: "finance",
            reference: reference,
            index: 0,
            count: 1,
            data: BighelpLinkBase64URL.encode(Data([0x89, 0x50, 0x4E, 0x47])),
            sentAt: 1_788_000_040
        )
        let message = BighelpLinkUserMessage(
            messageID: "message_fixture_0001",
            sessionID: "session_fixture_0001",
            agentID: "finance",
            actorID: "loopdy-user",
            actorName: "Alex",
            deviceName: "Alex's iPhone",
            text: "What is in this image?",
            attachments: [reference],
            sentAt: 1_788_000_041
        )
        let chunkValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(chunk)) as? [String: Any]
        )
        let messageValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )

        #expect(chunkValue["type"] as? String == "attachment.chunk")
        #expect(chunkValue["sessionId"] as? String == message.sessionID)
        #expect(chunkValue["fileName"] as? String == "forecast.png")
        #expect(chunkValue["path"] == nil)
        #expect((messageValue["attachments"] as? [[String: Any]])?.first?["sha256"] as? String == digest)
        #expect(messageValue["data"] == nil)
    }

    @Test func personalityMutationAndCatalogAreRevisionBoundWithoutConfigOrCredentialFields() throws {
        let draft = PersonalityDraft(
            originalName: nil,
            name: "focused",
            description: "Quietly deliberate",
            systemPrompt: "Work carefully.",
            tone: "Calm",
            style: "Structured"
        )
        let request = try BighelpLinkPersonalityRequest(
            requestID: "personality_request_0001",
            action: .save,
            expectedRevision: 4,
            name: "focused",
            draft: draft,
            sentAt: 1_788_000_050
        )
        let requestValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let catalog = try JSONDecoder().decode(
            BighelpLinkPersonalityCatalog.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "personalities.catalog",
                  "requestId": "personality_request_0001",
                  "revision": 5,
                  "activeName": "focused",
                  "personalities": [{
                    "name": "focused",
                    "description": "Quietly deliberate",
                    "systemPrompt": "Work carefully.",
                    "tone": "Calm",
                    "style": "Structured",
                    "builtIn": false,
                    "customized": true
                  }],
                  "sentAt": 1788000051
                }
                """.utf8
            )
        )

        #expect(requestValue["type"] as? String == "personalities.mutate")
        #expect(requestValue["expectedRevision"] as? Int == 4)
        #expect(requestValue["config"] == nil)
        #expect(requestValue["token"] == nil)
        #expect(catalog.catalog.activeName == "focused")
        #expect(catalog.catalog.personalities.first?.tone == "Calm")
    }

    @Test func workspaceControlsAreExplicitBoundedAndNeverCarryGatewayCredentials() throws {
        let request = try BighelpLinkWorkspaceRequest(
            requestID: "workspace_request_0001",
            operation: .agentsList,
            payload: [:],
            sentAt: 1_788_000_060
        )
        let requestValue = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let resultData = Data(
            """
            {
              "version": 1,
              "type": "workspace.result",
              "requestId": "workspace_request_0001",
              "operation": "agents.list",
              "status": "completed",
              "payload": {
                "profiles": [{
                  "id": "juno",
                  "name": "Juno",
                  "role": "Default agent",
                  "summary": "General help",
                  "instructions": "Be helpful.",
                  "isDefault": true
                }]
              },
              "sentAt": 1788000061
            }
            """.utf8
        )
        let result = try JSONDecoder().decode(BighelpLinkWorkspaceResult.self, from: resultData)

        #expect(Set(requestValue.keys) == Set([
            "version", "type", "requestId", "operation", "payload", "sentAt",
        ]))
        #expect(requestValue["type"] as? String == "workspace.request")
        #expect(requestValue["operation"] as? String == "agents.list")
        #expect(requestValue["gatewayURL"] == nil)
        #expect(requestValue["gatewayToken"] == nil)
        #expect(result.operation == .agentsList)
        #expect(result.status == .completed)
        #expect(result.payload["profiles"]?.array?.count == 1)

        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkWorkspaceRequest(
                requestID: "workspace_request_0002",
                operation: .agentsList,
                payload: ["gatewayToken": .string("must-never-cross-link")],
                sentAt: 1_788_000_062
            )
        }
    }

    @Test func workspaceAvatarSetAcceptsOneHermesSizedAsset() throws {
        let request = try BighelpLinkWorkspaceRequest(
            requestID: "workspace_avatar_set_0001",
            operation: .agentsAvatarSet,
            payload: Self.hermesSizedAvatarPayload(),
            sentAt: 1_788_000_063
        )

        #expect(request.operation == .agentsAvatarSet)
    }

    @Test func genericWorkspaceRequestRejectsOneHermesSizedAsset() throws {
        #expect(throws: BighelpLinkWireError.self) {
            try BighelpLinkWorkspaceRequest(
                requestID: "workspace_agents_list_0003",
                operation: .agentsList,
                payload: Self.hermesSizedAvatarPayload(),
                sentAt: 1_788_000_064
            )
        }
    }

    @Test func workspaceAvatarGetAcceptsOneHermesSizedAsset() throws {
        let result = try JSONDecoder().decode(
            BighelpLinkWorkspaceResult.self,
            from: try Self.hermesSizedAvatarResultData(operation: "agents.avatar.get")
        )
        #expect(result.operation == .agentsAvatarGet)
    }

    @Test func genericWorkspaceResultRejectsOneHermesSizedAsset() throws {
        #expect(throws: BighelpLinkWireError.self) {
            try JSONDecoder().decode(
                BighelpLinkWorkspaceResult.self,
                from: try Self.hermesSizedAvatarResultData(operation: "agents.list")
            )
        }
    }

    private static func hermesSizedAvatarPayload() -> [String: BighelpJSONValue] {
        [
            "agentId": .string("default"),
            "avatar": .object([
                "mimeType": .string("image/png"),
                "byteCount": .integer(2_000_000),
                "sha256": .string("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                "data": .string(
                    "data:image/png;base64," + String(repeating: "A", count: 2_666_668)
                ),
            ]),
        ]
    }

    private static func hermesSizedAvatarResultData(operation: String) throws -> Data {
        let dataURL = "data:image/png;base64," + String(repeating: "A", count: 2_666_668)
        return try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "type": "workspace.result",
            "requestId": "workspace_avatar_get_0001",
            "operation": operation,
            "status": "completed",
            "payload": [
                "agentId": "default",
                "avatar": [
                    "mimeType": "image/png",
                    "byteCount": 2_000_000,
                    "sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    "data": dataURL,
                ],
            ],
            "sentAt": 1_788_000_065,
        ])
    }

    @Test func projectManagerOperationsEncodeOnlyInsideTheWorkspaceRequestEnvelope() throws {
        let operations: [(BighelpLinkWorkspaceOperation, String)] = [
            (.projectsCreate, "projects.create"),
            (.projectsArchive, "projects.archive"),
            (.projectsListDirectory, "projects.list_directory"),
        ]

        for (index, pair) in operations.enumerated() {
            let (operation, rawValue) = pair
            let request = try BighelpLinkWorkspaceRequest(
                requestID: "workspace_project_manager_000\(index)",
                operation: operation,
                payload: ["agentId": .string("default")],
                sentAt: 1_788_000_070 + index
            )
            let value = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
            )

            #expect(value["type"] as? String == "workspace.request")
            #expect(value["operation"] as? String == operation.rawValue)
            #expect(value["operation"] as? String == rawValue)
            #expect(value["method"] == nil)
            #expect(value["command"] == nil)
            #expect(value["gatewayToken"] == nil)
        }
    }

    @Test func scheduledTaskDeliveryCatalogUsesTheWorkspaceRequestEnvelope() throws {
        let request = try BighelpLinkWorkspaceRequest(
            requestID: "workspace_scheduled_delivery_0001",
            operation: .scheduledTaskDeliveryTargets,
            payload: [:],
            sentAt: 1_788_000_080
        )
        let value = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(value["type"] as? String == "workspace.request")
        #expect(value["operation"] as? String == "scheduled_tasks.delivery_targets")
        #expect(value["method"] == nil)
        #expect(value["command"] == nil)
    }

    @Test func hermesRuntimeSizedCommandCatalogPayloadDecodesAcrossAllCommandSources() throws {
        let sourceRows: [(name: String, description: String, category: String, argsHint: String, mode: String, source: String, requiresArguments: Bool)] = [
            (
                "start",
                "Acknowledge platform start pings without a reply",
                "Session",
                "",
                "none",
                "core",
                false
            ),
            (
                "help",
                "Show available commands (/help skills lists skill commands, /help <text> filters)",
                "Info",
                "[skills|<filter>]",
                "text",
                "core",
                false
            ),
            (
                "usage-copilot",
                "Show GitHub Copilot credit usage and dollar value",
                "Saved commands",
                "",
                "none",
                "user",
                false
            ),
            (
                "disk-cleanup",
                "Track and clean up ephemeral Hermes session files.",
                "Plugins",
                "",
                "none",
                "plugin",
                false
            ),
            (
                "agents-sdk",
                "Build AI agents with stateful WebSocket apps.",
                "Skills",
                "[instruction]",
                "text",
                "skill",
                false
            ),
        ]
        var rows = sourceRows.map { row in
            [
                "name": row.name,
                "description": row.description,
                "category": row.category,
                "argsHint": row.argsHint,
                "aliases": [],
                "argumentMode": row.mode,
                "source": row.source,
                "requiresArguments": row.requiresArguments,
            ] as [String: Any]
        }
        // The installed Hermes runtime currently exposes hundreds of commands.
        // Exercise the same bounded payload shape at that scale so a catalog that
        // works with one fixture command cannot regress when skills are enabled.
        rows.append(contentsOf: (0..<294).map { index in
            [
                "name": "skill-\(index)",
                "description": "Use the Hermes skill for task \(index) — keep the response concise.",
                "category": "Skills",
                "argsHint": "[instruction]",
                "aliases": [],
                "argumentMode": "text",
                "source": "skill",
                "requiresArguments": false,
            ] as [String: Any]
        })
        let payload: [String: Any] = [
            "version": 1,
            "type": "commands.catalog",
            "requestId": "commands_request_fixture_0001",
            "sessionId": "session_fixture_0001",
            "agentId": "juno",
            "commands": rows,
            "sentAt": 1_788_000_002,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let catalog = try JSONDecoder().decode(
            BighelpLinkSlashCommandCatalog.self,
            from: data
        )

        #expect(catalog.commands.count == 299)
        #expect(catalog.commands.filter { $0.source == .core }.count == 2)
        #expect(catalog.commands.filter { $0.source == .user }.count == 1)
        #expect(catalog.commands.filter { $0.source == .plugin }.count == 1)
        #expect(catalog.commands.filter { $0.source == .skill }.count == 295)
        #expect(catalog.commands.first?.name == "start")
        #expect(catalog.commands[1].description.contains("/help <text>"))
        #expect(SlashCommandIndex(commands: catalog.commands).suggestions(for: "/disk").map(\.name) == ["disk-cleanup"])
    }

}
