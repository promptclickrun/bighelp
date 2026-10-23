import Contacts
import Foundation
import Testing
@testable import Bighelp

/// The agent's `iphone_contacts` tool on the phone: iOS permission, limited access, the checks that
/// run before the address book is touched, stale revisions and the bounded result. Every person,
/// number and address here is made up.
@MainActor
struct DeviceContactsToolTests {
    private static let context = DeviceToolCallContext(requestID: "a1b2c3d4-0000-4000-8000-000000000001", hostID: "host-1",
                                                       agentID: "agent-1", sessionID: "session-1", turnID: "turn-1")

    private static func avery() -> DeviceContactRecord {
        DeviceContactRecord(
            id: "contact-avery", givenName: "Avery", familyName: "Example", nickname: "Ave", organization: "Sample Co",
            jobTitle: "Gardener", birthday: DeviceContactBirthday(year: 1990, month: 4, day: 12),
            phones: [DeviceContactLabeledValue(label: CNLabelPhoneNumberMobile, value: "(555) 010-0199"),
                     DeviceContactLabeledValue(label: "_$!<Anniversary>!$_", value: "555-0100")],
            emails: [DeviceContactLabeledValue(label: CNLabelWork, value: "avery@example.com")],
            urls: [DeviceContactLabeledValue(label: nil, value: "https://example.com/avery")],
            addresses: [DeviceContactAddress(label: CNLabelHome, street: "100 Example Street", city: "Sampleton",
                                             region: "Example State", postalCode: "00000", country: "Exampleland")])
    }

    private static func sam() -> DeviceContactRecord {
        DeviceContactRecord(id: "contact-sam", givenName: "Sam", familyName: "Sample",
                            emails: [DeviceContactLabeledValue(label: CNLabelHome, value: "sam@example.org")])
    }

    private func tool(_ provider: FakeContactsProvider) -> DeviceContactsTool {
        DeviceContactsTool(provider: provider)
    }

    private func run(
        _ tool: DeviceContactsTool, _ operation: String, _ arguments: [String: BighelpJSONValue] = [:],
        authorize: @escaping @MainActor () throws -> Void = {}
    ) async throws -> [String: BighelpJSONValue] {
        try await tool.execute(operation: operation, arguments: arguments, context: Self.context, authorize: authorize)
    }

    // MARK: Capability

    @Test func contactsIsItsOwnSwitchAndNeedsTheNewerPlugin() {
        #expect(DeviceToolCapability.contacts.pluginFeature == "native-device-contacts-v1")
        #expect(DeviceContactsTool(provider: FakeContactsProvider()).capability == .contacts)
    }

    @Test func catalogJournalsOnlyTheChangesAndNeverKeepsContactData() {
        #expect(DeviceToolCatalog.operations["contacts.list"]?.journaled == false)
        for name in ["create", "update", "delete"] {
            let operation = DeviceToolCatalog.operations["contacts.\(name)"]
            #expect(operation?.journaled == true)
            #expect(operation?.liveOnlyKeys.isEmpty == true)
            #expect(operation?.capability == .contacts)
        }
    }

    // MARK: iOS permission

    @Test func statusFollowsIOSAndNeverAsks() async {
        for (authorization, expected) in [
            (DeviceContactsAuthorization.notDetermined, DeviceToolSystemAccess.notRequested),
            (.authorized, .available),
            (.limited, .available),
            (.denied, .denied),
            (.restricted, .unavailable),
        ] {
            let provider = FakeContactsProvider(authorization: authorization)
            #expect(await tool(provider).status() == expected)
            #expect(provider.accessRequests == 0)
        }
    }

    @Test func requestAsksOnlyTheFirstTime() async {
        let fresh = FakeContactsProvider(authorization: .notDetermined)
        #expect(await tool(fresh).request() == .available)
        #expect(fresh.accessRequests == 1)

        let refused = FakeContactsProvider(authorization: .notDetermined)
        refused.grantsAccess = false
        #expect(await tool(refused).request() == .denied)

        let denied = FakeContactsProvider(authorization: .denied)
        #expect(await tool(denied).request() == .denied)
        #expect(denied.accessRequests == 0, "iOS never asks twice; the person fixes it in Settings")
    }

    @Test func everyOperationNeedsIOSAccessBeforeTouchingTheAddressBook() async {
        for (authorization, expected) in [
            (DeviceContactsAuthorization.notDetermined, AppleDeviceToolError.authorizationRequired),
            (.denied, .authorizationRequired),
            (.restricted, .unavailable),
        ] {
            let provider = FakeContactsProvider(authorization: authorization, records: [Self.avery()])
            let tool = tool(provider)
            let calls: [(String, [String: BighelpJSONValue])] = [
                ("contacts.list", [:]),
                ("contacts.create", ["givenName": .string("Robin")]),
                ("contacts.update", ["id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
                                     "nickname": .string("A")]),
                ("contacts.delete", ["id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision)]),
            ]
            for (operation, arguments) in calls {
                await #expect(throws: expected) { try await self.run(tool, operation, arguments) }
            }
            #expect(provider.touches == 0)
        }
    }

    // MARK: List

    @Test func listReturnsTheContactsTheDocsPromise() async throws {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let result = try await run(tool(provider), "contacts.list")
        #expect(result["access"] == .string("full"))
        #expect(result["truncated"] == .boolean(false))
        let contacts = try #require(result["contacts"]?.array)
        #expect(contacts.count == 1)
        let contact = try #require(contacts.first?.object)
        #expect(contact["id"] == .string("contact-avery"))
        #expect(contact["revision"] == .string(Self.avery().revision))
        #expect(contact["givenName"] == .string("Avery"))
        #expect(contact["familyName"] == .string("Example"))
        #expect(contact["nickname"] == .string("Ave"))
        #expect(contact["organization"] == .string("Sample Co"))
        #expect(contact["jobTitle"] == .string("Gardener"))
        #expect(contact["birthday"] == .string("1990-04-12"))
        #expect(contact["phones"] == .array([
            .object(["label": .string("mobile"), "value": .string("(555) 010-0199")]),
            .object(["label": .string("Anniversary"), "value": .string("555-0100")]),
        ]))
        #expect(contact["emails"] == .array([.object(["label": .string("work"), "value": .string("avery@example.com")])]))
        #expect(contact["urls"] == .array([.object(["value": .string("https://example.com/avery")])]))
        #expect(contact["addresses"] == .array([.object([
            "label": .string("home"), "street": .string("100 Example Street"), "city": .string("Sampleton"),
            "region": .string("Example State"), "postalCode": .string("00000"), "country": .string("Exampleland"),
        ])]))
    }

    @Test func listLeavesOutWhatIsNotSetAndWritesBirthdaysWithoutAYear() async throws {
        var record = DeviceContactRecord(id: "contact-x", givenName: "Robin")
        record.birthday = DeviceContactBirthday(year: nil, month: 2, day: 29)
        let result = try await run(tool(FakeContactsProvider(records: [record])), "contacts.list")
        let contact = try #require(result["contacts"]?.array?.first?.object)
        #expect(Set(contact.keys) == ["id", "revision", "givenName", "birthday"])
        #expect(contact["birthday"] == .string("--02-29"))
    }

    @Test func listDefaultsToTwentyAndSaysWhenThereAreMore() async throws {
        let people = (0..<25).map { DeviceContactRecord(id: "c\($0)", givenName: "Person\($0)") }
        let provider = FakeContactsProvider(records: people)
        let result = try await run(tool(provider), "contacts.list")
        #expect(result["contacts"]?.array?.count == 20)
        #expect(result["truncated"] == .boolean(true))

        let five = try await run(tool(provider), "contacts.list", ["limit": .integer(5)])
        #expect(five["contacts"]?.array?.count == 5)
        #expect(five["truncated"] == .boolean(true))

        let all = try await run(tool(provider), "contacts.list", ["limit": .integer(50)])
        #expect(all["contacts"]?.array?.count == 25)
        #expect(all["truncated"] == .boolean(false))
    }

    @Test func listFindsPeopleByNameEmailOrPhone() async throws {
        let provider = FakeContactsProvider(records: [Self.avery(), Self.sam()])
        func ids(_ query: String) async throws -> [String] {
            let result = try await run(tool(provider), "contacts.list", ["query": .string(query)])
            return result["contacts"]?.array?.compactMap { $0.object?["id"]?.string } ?? []
        }
        #expect(try await ids("avery") == ["contact-avery"])
        #expect(try await ids("EXAMPLE ave") == ["contact-avery"])
        #expect(try await ids("sample co") == ["contact-avery"])
        #expect(try await ids("sam@example.ORG") == ["contact-sam"])
        #expect(try await ids("555 010 0199") == ["contact-avery"], "spaces and punctuation do not matter")
        #expect(try await ids("+1 (555) 010-0199") == ["contact-avery"])
        #expect(try await ids("0100") == ["contact-avery"])
        #expect(try await ids("nobody") == [])
    }

    @Test func listUnderLimitedAccessSeesOnlyWhatThePersonShared() async throws {
        let provider = FakeContactsProvider(authorization: .limited, records: [Self.avery(), Self.sam()])
        provider.shared = ["contact-sam"]
        let result = try await run(tool(provider), "contacts.list")
        #expect(result["access"] == .string("limited"))
        #expect(result["contacts"]?.array?.compactMap { $0.object?["id"]?.string } == ["contact-sam"])
        // Searching for someone who wasn't shared finds nobody, as if they didn't exist.
        let search = try await run(tool(provider), "contacts.list", ["query": .string("avery")])
        #expect(search["contacts"]?.array?.isEmpty == true)
    }

    @Test func listReportsAccessAsItIsAfterTheWait() async throws {
        let provider = FakeContactsProvider(authorization: .authorized, records: [Self.sam()])
        provider.afterRead = { provider.authorization = .limited }
        let result = try await run(tool(provider), "contacts.list")
        #expect(result["access"] == .string("limited"))

        provider.afterRead = { provider.authorization = .denied }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) { try await self.run(self.tool(provider), "contacts.list") }
    }

    @Test func listRefusesBadArgumentsBeforeTouchingTheAddressBook() async {
        let bad: [[String: BighelpJSONValue]] = [
            ["unknown": .boolean(true)],
            ["limit": .integer(0)], ["limit": .integer(51)], ["limit": .string("5")], ["limit": .number(2.5)],
            ["query": .string("")], ["query": .string("   ")], ["query": .string(String(repeating: "a", count: 201))],
            ["query": .integer(5)], ["query": .null], ["query": .string("a\u{0}b")],
        ]
        let provider = FakeContactsProvider(records: [Self.avery()])
        for arguments in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(self.tool(provider), "contacts.list", arguments) }
        }
        #expect(provider.touches == 0)
    }

    @Test func listAcceptsTheLargestQueryAndLimit() async throws {
        let provider = FakeContactsProvider(records: [Self.avery()])
        _ = try await run(tool(provider), "contacts.list", ["query": .string(String(repeating: "a", count: 200)), "limit": .integer(50)])
        _ = try await run(tool(provider), "contacts.list", ["query": .string("a"), "limit": .integer(1)])
    }

    @Test func listStaysUnderTheHostResultLimit() async throws {
        let big = (0..<50).map { index in
            DeviceContactRecord(
                id: "big-\(index)", givenName: String(repeating: "g", count: 200),
                phones: (0..<10).map { DeviceContactLabeledValue(label: nil, value: String(repeating: "\($0)", count: 64)) },
                emails: (0..<10).map { DeviceContactLabeledValue(label: nil, value: String(repeating: "e\($0)", count: 160)) })
        }
        let result = try await run(tool(FakeContactsProvider(records: big)), "contacts.list", ["limit": .integer(50)])
        #expect(result["truncated"] == .boolean(true))
        let count = try #require(result["contacts"]?.array?.count)
        #expect(count > 0 && count < 50)
        let bytes = try JSONEncoder().encode(BighelpJSONValue.object(result)).count
        #expect(bytes <= 128 * 1024)
    }

    @Test func listDropsWhatItReadWhenAuthorizationFailsAfterTheWait() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let calls = CallCounter()
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await self.run(self.tool(provider), "contacts.list") {
                calls.count += 1
                if calls.count == 2 { throw AppleDeviceToolError.authorizationRequired }
            }
        }
        #expect(calls.count == 2, "checked before the read and again after it")
    }

    // MARK: Create

    @Test func createSavesAndReturnsTheIDAndRevision() async throws {
        let provider = FakeContactsProvider()
        let result = try await run(tool(provider), "contacts.create", [
            "givenName": .string("Robin"), "familyName": .string("Placeholder"), "nickname": .string("Rob"),
            "organization": .string("Sample Co"), "jobTitle": .string("Editor"), "birthday": .string("--07-04"),
            "phones": .array([.object(["label": .string("Mobile"), "value": .string("555-0111")])]),
            "emails": .array([.object(["label": .string("Studio"), "value": .string("robin@example.com")])]),
            "urls": .array([.object(["value": .string("https://example.com/robin")])]),
            "addresses": .array([.object(["street": .string("1 Sample Way"), "city": .string("Sampleton"),
                                          "label": .string("other")])]),
        ])
        #expect(Set(result.keys) == ["id", "revision"], "the journal keeps only these")
        let saved = try #require(provider.records.first)
        #expect(result["id"] == .string(saved.id))
        #expect(result["revision"] == .string(saved.revision))
        #expect(saved.givenName == "Robin")
        #expect(saved.birthday == DeviceContactBirthday(year: nil, month: 7, day: 4))
        // Names the agent knows become Apple's own labels; anything else stays as written.
        #expect(saved.phones == [DeviceContactLabeledValue(label: CNLabelPhoneNumberMobile, value: "555-0111")])
        #expect(saved.emails == [DeviceContactLabeledValue(label: "Studio", value: "robin@example.com")])
        #expect(saved.urls == [DeviceContactLabeledValue(label: nil, value: "https://example.com/robin")])
        #expect(saved.addresses == [DeviceContactAddress(label: CNLabelOther, street: "1 Sample Way", city: "Sampleton")])
        #expect(provider.writes == 1)
    }

    @Test func createNeedsAName() async {
        let provider = FakeContactsProvider()
        for arguments: [String: BighelpJSONValue] in [
            [:], ["nickname": .string("Rob")], ["givenName": .string("  ")], ["jobTitle": .string("Editor")],
            ["phones": .array([.object(["value": .string("555-0111")])])],
        ] {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(self.tool(provider), "contacts.create", arguments) }
        }
        #expect(provider.touches == 0)
        for key in ["givenName", "familyName", "organization"] {
            let fresh = FakeContactsProvider()
            _ = try? await run(tool(fresh), "contacts.create", [key: .string("Robin")])
            #expect(fresh.writes == 1, "\(key) alone is enough")
        }
    }

    @Test func createRefusesBadFieldsBeforeTouchingTheAddressBook() async {
        let phone = { (value: BighelpJSONValue) in BighelpJSONValue.array([.object(["value": value])]) }
        let bad: [[String: BighelpJSONValue]] = [
            ["givenName": .string("Robin"), "unknown": .string("x")],
            ["givenName": .string("Robin"), "note": .string("secret")],
            ["givenName": .string("Robin"), "notes": .string("secret")],
            ["givenName": .integer(5)],
            ["givenName": .string(String(repeating: "a", count: 201))],
            ["givenName": .string("Rob\u{7}in")],
            ["givenName": .string("Robin"), "nickname": .string(String(repeating: "a", count: 201))],
            ["givenName": .string("Robin"), "birthday": .string("2024-02-30")],
            ["givenName": .string("Robin"), "birthday": .string("1990-13-01")],
            ["givenName": .string("Robin"), "birthday": .string("90-01-01")],
            ["givenName": .string("Robin"), "birthday": .string("--02-30")],
            ["givenName": .string("Robin"), "birthday": .string("2023-02-29")],
            ["givenName": .string("Robin"), "birthday": .string("0000-01-01")],
            ["givenName": .string("Robin"), "birthday": .string("1990/01/01")],
            ["givenName": .string("Robin"), "birthday": .integer(19900101)],
            ["givenName": .string("Robin"), "phones": .string("555-0111")],
            ["givenName": .string("Robin"), "phones": phone(.string(""))],
            ["givenName": .string("Robin"), "phones": phone(.integer(5550111))],
            ["givenName": .string("Robin"), "phones": phone(.string(String(repeating: "5", count: 65)))],
            ["givenName": .string("Robin"), "phones": .array((0..<11).map { _ in .object(["value": .string("555")]) })],
            ["givenName": .string("Robin"), "emails": .array((0..<11).map { _ in .object(["value": .string("a@example.com")]) })],
            ["givenName": .string("Robin"), "urls": .array((0..<6).map { _ in .object(["value": .string("https://example.com")]) })],
            ["givenName": .string("Robin"), "addresses": .array((0..<6).map { _ in .object(["city": .string("Sampleton")]) })],
            ["givenName": .string("Robin"), "addresses": .array([.object([:])])],
            ["givenName": .string("Robin"), "addresses": .array([.object(["county": .string("x")])])],
            ["givenName": .string("Robin"), "addresses": .array([.object(["city": .integer(1)])])],
            ["givenName": .string("Robin"), "phones": .array([.object(["value": .string("555"), "kind": .string("x")])])],
            ["givenName": .string("Robin"), "phones": .array([.object(["value": .string("555"), "label": .string("")])])],
            ["givenName": .string("Robin"), "phones": .array([.object(["value": .string("555"), "label": .string(String(repeating: "l", count: 41))])])],
            ["givenName": .string("Robin"), "phones": .array([.object(["value": .string("555"), "label": .null])])],
            ["givenName": .string("Robin"), "phones": .array([.string("555")])],
        ]
        let provider = FakeContactsProvider()
        for arguments in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(self.tool(provider), "contacts.create", arguments) }
        }
        #expect(provider.touches == 0)
    }

    @Test func createAcceptsTheLargestAllowedValues() async throws {
        let provider = FakeContactsProvider()
        _ = try await run(tool(provider), "contacts.create", [
            "givenName": .string(String(repeating: "g", count: 200)),
            "phones": .array((0..<10).map { _ in .object(["value": .string(String(repeating: "5", count: 64)),
                                                          "label": .string(String(repeating: "l", count: 40))]) }),
            "emails": .array((0..<10).map { _ in .object(["value": .string(String(repeating: "e", count: 320))]) }),
            "urls": .array((0..<5).map { _ in .object(["value": .string("https://example.com/" + String(repeating: "u", count: 2_000))]) }),
            "addresses": .array((0..<5).map { _ in .object(["street": .string("Line one\nLine two"), "city": .string("Sampleton")]) }),
            "birthday": .string("2024-02-29"),
        ])
        #expect(provider.writes == 1)
    }

    @Test func createUnderLimitedAccessIsAllowed() async throws {
        let provider = FakeContactsProvider(authorization: .limited, records: [Self.avery()])
        provider.shared = []
        let result = try await run(tool(provider), "contacts.create", ["givenName": .string("Robin")])
        // The contact the app made is one it can see afterwards.
        let list = try await run(tool(provider), "contacts.list")
        #expect(list["contacts"]?.array?.compactMap { $0.object?["id"] } == [result["id"]!])
    }

    // MARK: Update

    @Test func updateChangesOnlyWhatItIsGivenAndReturnsTheNewRevision() async throws {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let before = Self.avery()
        let result = try await run(tool(provider), "contacts.update", [
            "id": .string(before.id), "expectedRevision": .string(before.revision),
            "jobTitle": .string("Head gardener"),
        ])
        var expected = before
        expected.jobTitle = "Head gardener"
        #expect(provider.records == [expected])
        #expect(result == ["id": .string(before.id), "revision": .string(expected.revision)])
        #expect(expected.revision != before.revision)
    }

    @Test func updateReplacesAWholeListAndClearsWithEmptyValues() async throws {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let before = Self.avery()
        _ = try await run(tool(provider), "contacts.update", [
            "id": .string(before.id), "expectedRevision": .string(before.revision),
            "phones": .array([.object(["label": .string("work"), "value": .string("555-0222")])]),
            "emails": .array([]),
            "nickname": .string(""),
            "birthday": .string(""),
            "addresses": .array([]),
        ])
        let after = try #require(provider.records.first)
        #expect(after.phones == [DeviceContactLabeledValue(label: CNLabelWork, value: "555-0222")])
        #expect(after.emails.isEmpty)
        #expect(after.nickname.isEmpty)
        #expect(after.birthday == nil)
        #expect(after.addresses.isEmpty)
        #expect(after.urls == before.urls, "lists that weren't given stay as they were")
        #expect(after.givenName == "Avery")
    }

    @Test func updateWithAStaleRevisionChangesNothing() async throws {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let oldRevision = Self.avery().revision
        // Someone else edits the contact after the agent read it.
        provider.records[0].jobTitle = "Changed elsewhere"
        let edited = provider.records
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string("contact-avery"), "expectedRevision": .string(oldRevision), "nickname": .string("A"),
            ])
        }
        #expect(provider.records == edited)
        #expect(provider.writes == 0)
    }

    @Test func updateCatchesAnEditThatLandsBetweenTheCheckAndTheSave() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        provider.beforeWrite = { provider.records[0].familyName = "Edited meanwhile" }
        let edited = { () -> [DeviceContactRecord] in var copy = [Self.avery()]; copy[0].familyName = "Edited meanwhile"; return copy }()
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision), "nickname": .string("A"),
            ])
        }
        #expect(provider.records == edited)
    }

    @Test func updateOrDeleteOfAMissingContactIsNotFound() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        await #expect(throws: DeviceContactsTool.Failure.notFound) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string("nobody"), "expectedRevision": .string("abc"), "nickname": .string("A"),
            ])
        }
        await #expect(throws: DeviceContactsTool.Failure.notFound) {
            try await self.run(self.tool(provider), "contacts.delete", ["id": .string("nobody"), "expectedRevision": .string("abc")])
        }
        #expect(DeviceContactsTool.Failure.notFound.code == "not_found")
        #expect(provider.writes == 0)
    }

    @Test func updateOfAContactThePersonDidNotShareIsNotFound() async {
        let provider = FakeContactsProvider(authorization: .limited, records: [Self.avery(), Self.sam()])
        provider.shared = ["contact-sam"]
        await #expect(throws: DeviceContactsTool.Failure.notFound) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision), "nickname": .string("A"),
            ])
        }
        await #expect(throws: DeviceContactsTool.Failure.notFound) {
            try await self.run(self.tool(provider), "contacts.delete", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
            ])
        }
        #expect(provider.writes == 0)
    }

    @Test func updateRefusesBadArgumentsBeforeTouchingTheAddressBook() async {
        let id: [String: BighelpJSONValue] = ["id": .string("contact-avery"), "expectedRevision": .string("rev")]
        func merged(_ more: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] { id.merging(more) { $1 } }
        let bad: [[String: BighelpJSONValue]] = [
            [:], ["id": .string("contact-avery")], ["expectedRevision": .string("rev"), "nickname": .string("A")],
            id,  // nothing to change
            merged(["id": .string("")]), merged(["id": .string(String(repeating: "i", count: 513)), "nickname": .string("A")]),
            merged(["expectedRevision": .string(""), "nickname": .string("A")]),
            merged(["expectedRevision": .integer(1), "nickname": .string("A")]),
            merged(["nickname": .string("A"), "note": .string("x")]),
            merged(["birthday": .string("1990-02-31")]),
            merged(["givenName": .string("A"), "unexpected": .boolean(true)]),
        ]
        let provider = FakeContactsProvider(records: [Self.avery()])
        for arguments in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(self.tool(provider), "contacts.update", arguments) }
        }
        #expect(provider.touches == 0)
    }

    @Test func updateCannotLeaveAContactWithoutAName() async {
        let provider = FakeContactsProvider(records: [Self.sam()])
        let before = Self.sam()
        await #expect(throws: AppleDeviceToolError.invalidArguments) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string(before.id), "expectedRevision": .string(before.revision),
                "givenName": .string(""), "familyName": .string(""),
            ])
        }
        #expect(provider.writes == 0)
    }

    @Test func updateStopsWhenAuthorizationFailsBeforeTheSave() async {
        for failingCall in 1...3 {
            let provider = FakeContactsProvider(records: [Self.avery()])
            let calls = CallCounter()
            await #expect(throws: AppleDeviceToolError.authorizationRequired) {
                try await self.run(self.tool(provider), "contacts.update", [
                    "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
                    "nickname": .string("A"),
                ]) {
                    calls.count += 1
                    if calls.count == failingCall { throw AppleDeviceToolError.authorizationRequired }
                }
            }
            #expect(provider.writes == 0, "check \(failingCall) must come before the save")
            #expect(provider.records == [Self.avery()])
        }
    }

    @Test func updateStopsWhenIOSTakesAccessBackJustBeforeTheSave() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        provider.beforeWrite = { provider.authorization = .denied }
        await #expect(throws: AppleDeviceToolError.authorizationRequired) {
            try await self.run(self.tool(provider), "contacts.update", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision), "nickname": .string("A"),
            ])
        }
        #expect(provider.records == [Self.avery()])
    }

    // MARK: Delete

    @Test func deleteRemovesTheContactAndReturnsOnlyTheIDAndDeleted() async throws {
        let provider = FakeContactsProvider(records: [Self.avery(), Self.sam()])
        let result = try await run(tool(provider), "contacts.delete", [
            "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
        ])
        #expect(result == ["id": .string("contact-avery"), "deleted": .boolean(true)])
        #expect(provider.records == [Self.sam()])
    }

    @Test func deleteWithAStaleRevisionKeepsTheContact() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        provider.records[0].nickname = "Edited"
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await self.run(self.tool(provider), "contacts.delete", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
            ])
        }
        #expect(provider.records.count == 1)
        #expect(provider.writes == 0)
    }

    @Test func deleteCatchesAnEditThatLandsBetweenTheCheckAndTheSave() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        provider.beforeWrite = { provider.records[0].jobTitle = "Edited meanwhile" }
        await #expect(throws: AppleDeviceToolError.staleRevision) {
            try await self.run(self.tool(provider), "contacts.delete", [
                "id": .string("contact-avery"), "expectedRevision": .string(Self.avery().revision),
            ])
        }
        #expect(provider.records.count == 1)
    }

    @Test func deleteRefusesBadArguments() async {
        let provider = FakeContactsProvider(records: [Self.avery()])
        let bad: [[String: BighelpJSONValue]] = [
            [:], ["id": .string("contact-avery")], ["expectedRevision": .string("rev")],
            ["id": .string("contact-avery"), "expectedRevision": .string("rev"), "nickname": .string("A")],
            ["id": .string("contact-avery"), "expectedRevision": .string("rev"), "extra": .string("x")],
        ]
        for arguments in bad {
            await #expect(throws: AppleDeviceToolError.invalidArguments) { try await self.run(self.tool(provider), "contacts.delete", arguments) }
        }
        #expect(provider.touches == 0)
    }

    @Test func anUnknownOperationIsUnsupported() async {
        await #expect(throws: AppleDeviceToolError.unsupportedOperation) {
            try await self.run(self.tool(FakeContactsProvider()), "contacts.merge")
        }
    }

    // MARK: Revision

    @Test func revisionIsStableAndFollowsEveryFieldTheToolReads() {
        #expect(Self.avery().revision == Self.avery().revision)
        #expect(Self.avery().revision.count == 64)
        #expect(Self.avery().revision.allSatisfy { "0123456789abcdef".contains($0) })
        let changes: [(inout DeviceContactRecord) -> Void] = [
            { $0.givenName = "Other" }, { $0.familyName = "Other" }, { $0.nickname = "Other" },
            { $0.organization = "Other" }, { $0.jobTitle = "Other" },
            { $0.birthday = DeviceContactBirthday(year: 1990, month: 4, day: 13) },
            { $0.birthday = DeviceContactBirthday(year: nil, month: 4, day: 12) },
            { $0.birthday = nil },
            { $0.phones[0].value = "555-0000" }, { $0.phones[0].label = CNLabelHome }, { $0.phones.removeLast() },
            { $0.emails[0].value = "other@example.com" }, { $0.urls[0].value = "https://example.com/other" },
            { $0.addresses[0].street = "2 Example Street" }, { $0.addresses[0].label = nil }, { $0.addresses.removeAll() },
        ]
        let original = Self.avery().revision
        var seen: Set<String> = [original]
        for change in changes {
            var record = Self.avery()
            change(&record)
            #expect(record.revision != original)
            seen.insert(record.revision)
        }
        #expect(seen.count == changes.count + 1, "every kind of change gives its own revision")
    }

    @Test func revisionDoesNotConfuseWhereOneFieldEndsAndTheNextBegins() {
        let first = DeviceContactRecord(id: "x", givenName: "ab", familyName: "c")
        let second = DeviceContactRecord(id: "x", givenName: "a", familyName: "bc")
        #expect(first.revision != second.revision)
        let third = DeviceContactRecord(id: "x", givenName: "a", familyName: "", nickname: "bc")
        #expect(second.revision != third.revision)
    }

    // MARK: Birthday, labels and search

    @Test func birthdayParsesOnlyRealDates() {
        #expect(DeviceContactBirthday("1990-04-12") == DeviceContactBirthday(year: 1990, month: 4, day: 12))
        #expect(DeviceContactBirthday("--04-12") == DeviceContactBirthday(year: nil, month: 4, day: 12))
        #expect(DeviceContactBirthday("--02-29")?.text == "--02-29")
        #expect(DeviceContactBirthday("2024-02-29")?.text == "2024-02-29")
        #expect(DeviceContactBirthday("0042-01-01")?.text == "0042-01-01")
        for bad in ["", "1990", "1990-04", "1990-4-12", "--4-12", "--04-12-01", "2023-02-29", "1990-00-10", "1990-04-00",
                    "1990-04-31", "-1990-04-12", "1990-04-12T00:00:00Z", "١٩٩٠-٠٤-١٢", "0000-01-01", "--13-01"] {
            #expect(DeviceContactBirthday(bad) == nil, "\(bad) is not a birthday")
        }
    }

    @Test func labelsMapBothWaysAndOtherTextStaysCustom() {
        let pairs: [(String, String)] = [
            ("home", CNLabelHome), ("work", CNLabelWork), ("other", CNLabelOther), ("mobile", CNLabelPhoneNumberMobile),
            ("iPhone", CNLabelPhoneNumberiPhone), ("main", CNLabelPhoneNumberMain),
        ]
        for (agent, apple) in pairs {
            #expect(DeviceContactLabels.contactsLabel(agent, kind: .phone) == apple)
            #expect(DeviceContactLabels.agentLabel(apple) == agent)
        }
        #expect(DeviceContactLabels.contactsLabel("Mobile", kind: .phone) == CNLabelPhoneNumberMobile, "case does not matter")
        #expect(DeviceContactLabels.contactsLabel("Cabin", kind: .phone) == "Cabin")
        // Phone-only names mean nothing on an email, so they stay what the agent wrote.
        #expect(DeviceContactLabels.contactsLabel("mobile", kind: .other) == "mobile")
        #expect(DeviceContactLabels.contactsLabel("work", kind: .other) == CNLabelWork)
        #expect(DeviceContactLabels.agentLabel("_$!<Anniversary>!$_") == "Anniversary")
        #expect(DeviceContactLabels.agentLabel("Cabin") == "Cabin")
        #expect(DeviceContactLabels.agentLabel(nil) == nil)
        #expect(DeviceContactLabels.agentLabel("") == nil)
        #expect(DeviceContactLabels.agentLabel(String(repeating: "l", count: 90))?.count == 40)
    }

    @Test func searchMatchesLikeThePersonWouldExpect() {
        let avery = Self.avery()
        let matches = { (query: String?) in DeviceContactMatcher.matches(avery, query: query) }
        #expect(matches(nil))
        #expect(matches("  "))
        #expect(matches("ave"))
        #expect(matches("example avery"))
        #expect(!matches("avery smith"), "every word has to match")
        #expect(matches("AVERY@EXAMPLE.COM"))
        #expect(matches("avery@exa"))
        #expect(!matches("other@example.com"))
        #expect(matches("5550100"))
        #expect(matches("555-0100"))
        #expect(matches("+44 555 0100"), "a longer number that ends with a saved one")
        #expect(!matches("555-0101"))
        #expect(!matches("12"), "two digits are not a phone number, and no name has them")
        var accent = DeviceContactRecord(id: "x", givenName: "José")
        #expect(DeviceContactMatcher.matches(accent, query: "jose"))
        accent.givenName = ""
        #expect(!DeviceContactMatcher.matches(accent, query: "jose"))
    }

    // MARK: Apple's records

    @Test func theNoteIsNeverFetched() {
        #expect(!LiveDeviceContactsProvider.keyNames.contains(CNContactNoteKey))
        #expect(!LiveDeviceContactsProvider.keyNames.contains(CNContactImageDataKey))
        #expect(Set(LiveDeviceContactsProvider.keyNames) == [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactBirthdayKey, CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey, CNContactUrlAddressesKey, CNContactPostalAddressesKey,
        ])
    }

    @Test func aRecordSurvivesTheTripThroughAContactAndKeepsItsRevision() {
        let record = Self.avery()
        let contact = CNMutableContact()
        LiveDeviceContactsProvider.apply(DeviceContactChange(
            givenName: record.givenName, familyName: record.familyName, nickname: record.nickname,
            organization: record.organization, jobTitle: record.jobTitle, birthday: .set(record.birthday!),
            phones: record.phones, emails: record.emails, urls: record.urls, addresses: record.addresses), to: contact)
        var back = LiveDeviceContactsProvider.record(from: contact)
        // Apple gives the new contact its own identifier.
        #expect(!back.id.isEmpty)
        back.id = record.id
        #expect(back == record)
        #expect(back.revision == record.revision)
        #expect(contact.note.isEmpty, "nothing writes a note")
    }

    @Test func aBirthdayWithoutAYearStaysWithoutOne() {
        let contact = CNMutableContact()
        LiveDeviceContactsProvider.apply(DeviceContactChange(givenName: "Robin", birthday: .set(DeviceContactBirthday(year: nil, month: 2, day: 29))),
                                         to: contact)
        #expect(contact.birthday?.year == nil)
        #expect(LiveDeviceContactsProvider.record(from: contact).birthday?.text == "--02-29")
        LiveDeviceContactsProvider.apply(DeviceContactChange(birthday: .clear), to: contact)
        #expect(contact.birthday == nil)
    }

    @Test func applyingAChangeLeavesWhatItDoesNotNameAlone() {
        let contact = CNMutableContact()
        contact.givenName = "Avery"
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "555-0100"))]
        LiveDeviceContactsProvider.apply(DeviceContactChange(jobTitle: "Gardener"), to: contact)
        #expect(contact.givenName == "Avery")
        #expect(contact.phoneNumbers.count == 1)
        #expect(contact.jobTitle == "Gardener")
        LiveDeviceContactsProvider.apply(DeviceContactChange(phones: []), to: contact)
        #expect(contact.phoneNumbers.isEmpty)
    }

    @Test func iosStatusesMapToTheToolsOwn() {
        #expect(LiveDeviceContactsProvider.mapAuthorization(.notDetermined) == .notDetermined)
        #expect(LiveDeviceContactsProvider.mapAuthorization(.denied) == .denied)
        #expect(LiveDeviceContactsProvider.mapAuthorization(.restricted) == .restricted)
        #expect(LiveDeviceContactsProvider.mapAuthorization(.authorized) == .authorized)
        if #available(iOS 18.0, *) {
            #expect(LiveDeviceContactsProvider.mapAuthorization(.limited) == .limited)
        }
    }

    // MARK: Demo

    @Test func theDemoAddressBookWorksWithoutAnyPermission() async throws {
        let demo = DemoDeviceContactsProvider()
        let tool = DeviceContactsTool(provider: demo)
        #expect(await tool.status() == .available)
        let list = try await run(tool, "contacts.list", ["query": .string("avery")])
        #expect(list["contacts"]?.array?.count == 1)
        let created = try await run(tool, "contacts.create", ["givenName": .string("Robin")])
        let revision = try #require(created["revision"]?.string)
        let id = try #require(created["id"]?.string)
        _ = try await run(tool, "contacts.delete", ["id": .string(id), "expectedRevision": .string(revision)])
        await #expect(throws: DeviceContactsTool.Failure.notFound) {
            try await self.run(tool, "contacts.delete", ["id": .string(id), "expectedRevision": .string(revision)])
        }
    }
}

/// A stand-in for the address book that behaves like Apple's: people the person did not share are
/// invisible under limited access, writes fail once access is gone, and a write whose revision no
/// longer matches the contact is refused in the same step that saves.
@MainActor
final class FakeContactsProvider: DeviceContactsProviding {
    var authorization: DeviceContactsAuthorization
    var records: [DeviceContactRecord]
    /// Under limited access, the contacts the person shared. Everyone, when nil.
    var shared: Set<String>?
    var grantsAccess = true
    private(set) var accessRequests = 0
    /// Every read or save that reached the address book.
    private(set) var touches = 0
    private(set) var writes = 0
    /// Another app edits the address book just before this save runs.
    var beforeWrite: (@MainActor () -> Void)?
    var afterRead: (@MainActor () -> Void)?

    init(authorization: DeviceContactsAuthorization = .authorized, records: [DeviceContactRecord] = []) {
        self.authorization = authorization
        self.records = records
    }

    private var visible: [DeviceContactRecord] {
        guard authorization == .limited, let shared else { return records }
        return records.filter { shared.contains($0.id) }
    }

    func requestAccess() async -> Bool {
        accessRequests += 1
        authorization = grantsAccess ? .authorized : .denied
        return grantsAccess
    }

    func list(query: String?, limit: Int) async throws -> DeviceContactsPage {
        touches += 1
        let matches = visible.filter { DeviceContactMatcher.matches($0, query: query) }
        let page = DeviceContactsPage(records: Array(matches.prefix(limit)), truncated: matches.count > limit)
        afterRead?()
        return page
    }

    func record(id: String) async throws -> DeviceContactRecord? {
        touches += 1
        return visible.first { $0.id == id }
    }

    func create(_ change: DeviceContactChange) async throws -> DeviceContactRecord {
        try beginWrite()
        let record = DeviceContactRecord(id: "new-\(records.count + 1)").applying(change)
        records.append(record)
        writes += 1
        if authorization == .limited { shared?.insert(record.id) }
        return record
    }

    func update(id: String, expectedRevision: String, change: DeviceContactChange) async throws -> DeviceContactRecord {
        try beginWrite()
        guard let index = records.firstIndex(where: { $0.id == id }), visible.contains(where: { $0.id == id }) else {
            throw DeviceContactsProviderError.notFound
        }
        guard records[index].revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
        records[index] = records[index].applying(change)
        writes += 1
        return records[index]
    }

    func delete(id: String, expectedRevision: String) async throws {
        try beginWrite()
        guard let index = records.firstIndex(where: { $0.id == id }), visible.contains(where: { $0.id == id }) else {
            throw DeviceContactsProviderError.notFound
        }
        guard records[index].revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
        records.remove(at: index)
        writes += 1
    }

    /// What the real provider does first: let anything that happens meanwhile happen, then check access.
    private func beginWrite() throws {
        touches += 1
        beforeWrite?()
        guard authorization == .authorized || authorization == .limited else { throw DeviceContactsProviderError.unauthorized }
    }
}

@MainActor
private final class CallCounter {
    var count = 0
}
