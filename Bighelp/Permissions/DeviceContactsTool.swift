@preconcurrency import Contacts
import CryptoKit
import Foundation

// MARK: - What the tool reads and writes

/// A phone number, email address or web address with the person's label for it. `label` is
/// Apple's own (`CNLabelHome`, `_$!<Mobile>!$_`, ...) or the person's own text.
struct DeviceContactLabeledValue: Equatable, Sendable {
    var label: String?
    var value: String
}

struct DeviceContactAddress: Equatable, Sendable {
    var label: String?
    var street = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = ""

    var isEmpty: Bool { [street, city, region, postalCode, country].allSatisfy(\.isEmpty) }
}

/// `year` is nil for a birthday kept without one.
struct DeviceContactBirthday: Equatable, Sendable {
    var year: Int?
    var month: Int
    var day: Int

    /// `YYYY-MM-DD`, or `--MM-DD` without a year. Nil for anything else, or a day the calendar lacks.
    init?(_ text: String) {
        func number(_ part: Substring, digits: Int) -> Int? {
            guard part.count == digits, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        let year: Int?
        let rest: [Substring]
        if text.hasPrefix("--") {
            year = nil
            rest = text.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
        } else {
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, let value = number(parts[0], digits: 4), value >= 1 else { return nil }
            year = value
            rest = Array(parts.dropFirst())
        }
        guard rest.count == 2, let month = number(rest[0], digits: 2), let day = number(rest[1], digits: 2),
              (1...12).contains(month) else { return nil }
        // Without a year, February 29 is allowed: the birthday comes back every leap year.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let first = calendar.date(from: DateComponents(year: year ?? 2000, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first),
              days.contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init(year: Int?, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    var text: String {
        let monthDay = String(format: "%02d-%02d", month, day)
        guard let year else { return "--" + monthDay }
        return String(format: "%04d-", year) + monthDay
    }
}

/// One contact as the tool reads it: only the fields the docs list, never the note.
struct DeviceContactRecord: Equatable, Sendable {
    var id: String
    var givenName = ""
    var familyName = ""
    var nickname = ""
    var organization = ""
    var jobTitle = ""
    var birthday: DeviceContactBirthday?
    var phones: [DeviceContactLabeledValue] = []
    var emails: [DeviceContactLabeledValue] = []
    var urls: [DeviceContactLabeledValue] = []
    var addresses: [DeviceContactAddress] = []

    var hasName: Bool { !givenName.isEmpty || !familyName.isEmpty || !organization.isEmpty }

    /// Contacts keeps no modification date, so the revision is a hash of everything the tool reads, in
    /// a fixed order. Any change to those fields changes it; a change to anything else (a photo, a
    /// note) can't matter to the agent and doesn't.
    var revision: String {
        var hasher = SHA256()
        func put(_ text: String) {
            // The length first, so ("ab", "c") and ("a", "bc") hash differently.
            hasher.update(data: Data("\(text.utf8.count):".utf8))
            hasher.update(data: Data(text.utf8))
        }
        func put(_ values: [DeviceContactLabeledValue]) {
            put("\(values.count)")
            for value in values { put(value.label ?? "\u{0}"); put(value.value) }
        }
        put("bighelp.contact.v1")
        put(id)
        for text in [givenName, familyName, nickname, organization, jobTitle] { put(text) }
        put(birthday?.text ?? "")
        put(phones); put(emails); put(urls)
        put("\(addresses.count)")
        for address in addresses {
            put(address.label ?? "\u{0}")
            for text in [address.street, address.city, address.region, address.postalCode, address.country] { put(text) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func applying(_ change: DeviceContactChange) -> DeviceContactRecord {
        var record = self
        if let value = change.givenName { record.givenName = value }
        if let value = change.familyName { record.familyName = value }
        if let value = change.nickname { record.nickname = value }
        if let value = change.organization { record.organization = value }
        if let value = change.jobTitle { record.jobTitle = value }
        switch change.birthday {
        case .clear: record.birthday = nil
        case .set(let birthday): record.birthday = birthday
        case nil: break
        }
        if let value = change.phones { record.phones = value }
        if let value = change.emails { record.emails = value }
        if let value = change.urls { record.urls = value }
        if let value = change.addresses { record.addresses = value }
        return record
    }
}

/// What a create or an update sets. A nil field stays as it is; an empty string or list clears it.
struct DeviceContactChange: Equatable, Sendable {
    enum BirthdayChange: Equatable, Sendable { case clear, set(DeviceContactBirthday) }

    var givenName: String?
    var familyName: String?
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var birthday: BirthdayChange?
    var phones: [DeviceContactLabeledValue]?
    var emails: [DeviceContactLabeledValue]?
    var urls: [DeviceContactLabeledValue]?
    var addresses: [DeviceContactAddress]?

    var isEmpty: Bool { self == DeviceContactChange() }
}

enum DeviceContactsAuthorization: Equatable, Sendable {
    case notDetermined, denied, restricted
    case authorized
    /// iOS 18: the person shared only some contacts.
    case limited
}

struct DeviceContactsPage: Equatable, Sendable {
    var records: [DeviceContactRecord]
    /// More matched than `limit`.
    var truncated: Bool
}

enum DeviceContactsProviderError: Error, Equatable, Sendable {
    /// No such contact, or one the person didn't share (limited access).
    case notFound
    /// The contact no longer reads as the revision the caller checked.
    case staleRevision
    /// iOS stopped allowing access during the call.
    case unauthorized
    case failed
}

/// Contacts behind a seam, so the choices below can be tested without a device. A write checks the
/// revision again in the same step that saves, since the contact can change between a read and it.
@MainActor
protocol DeviceContactsProviding: AnyObject {
    /// iOS's current answer. Never asks.
    var authorization: DeviceContactsAuthorization { get }
    func requestAccess() async -> Bool
    /// People matching `query` (or the first ones, in the person's sort order), at most `limit`.
    func list(query: String?, limit: Int) async throws -> DeviceContactsPage
    /// Nil when there is no such contact among those the app may see.
    func record(id: String) async throws -> DeviceContactRecord?
    func create(_ change: DeviceContactChange) async throws -> DeviceContactRecord
    func update(id: String, expectedRevision: String, change: DeviceContactChange) async throws -> DeviceContactRecord
    func delete(id: String, expectedRevision: String) async throws
}

// MARK: - The tool

/// `contacts.list`, `contacts.create`, `contacts.update` and `contacts.delete`: the agent's `iphone_contacts` tool.
/// Contact notes are never read or written: Apple gives them only to apps with a special entitlement.
@MainActor
final class DeviceContactsTool: DeviceCapabilityTool {
    enum Failure: String, DeviceToolFailure, Equatable {
        /// No contact with that ID (or the person didn't share it with bighelp).
        case notFound = "not_found"

        var code: String { rawValue }
    }

    nonisolated static let maximumNameLength = 200
    nonisolated static let maximumLabelLength = 40
    nonisolated static let maximumQueryLength = 200
    nonisolated static let maximumLimit = 50
    nonisolated static let defaultLimit = 20
    /// The host accepts 128 KB; stay well inside it.
    nonisolated static let maximumResultBytes = 96_000

    let capability = DeviceToolCapability.contacts
    private let provider: any DeviceContactsProviding

    init(provider: any DeviceContactsProviding) {
        self.provider = provider
    }

    static func live(_ environment: DeviceToolEnvironment) -> DeviceContactsTool {
        // Demo mode never asks iOS or touches the real address book.
        DeviceContactsTool(provider: environment.usesFixtures ? DemoDeviceContactsProvider() : LiveDeviceContactsProvider())
    }

    func status() async -> DeviceToolSystemAccess {
        switch provider.authorization {
        case .notDetermined: .notRequested
        case .authorized, .limited: .available
        case .denied: .denied
        case .restricted: .unavailable
        }
    }

    /// The Settings switch: the first time, iOS asks, from the person's tap.
    func request() async -> DeviceToolSystemAccess {
        if provider.authorization == .notDetermined { _ = await provider.requestAccess() }
        return await status()
    }

    func execute(
        operation: String,
        arguments: [String: BighelpJSONValue],
        context: DeviceToolCallContext,
        authorize: @escaping @MainActor () throws -> Void
    ) async throws -> [String: BighelpJSONValue] {
        // Everything is checked before iOS or the store is touched.
        switch operation {
        case "contacts.list":
            let request = try ListRequest(arguments)
            try await requireAccess(authorize)
            let page = try await run { try await self.provider.list(query: request.query, limit: request.limit) }
            try authorize()
            return try payload(page, access: currentAccess())
        case "contacts.create":
            let change = try Self.createChange(arguments)
            try await requireAccess(authorize)
            try authorize()
            let created = try await run { try await self.provider.create(change) }
            try authorize()
            return Self.mutation(created)
        case "contacts.update":
            let target = try Self.target(arguments, allowed: Self.fieldKeys)
            let change = try Self.change(arguments)
            guard !change.isEmpty else { throw AppleDeviceToolError.invalidArguments }
            try await requireAccess(authorize)
            let current = try await existing(target, authorize: authorize)
            // A change that would leave no name is a bad request, not a half-applied one.
            guard current.applying(change).hasName else { throw AppleDeviceToolError.invalidArguments }
            try authorize()
            let updated = try await run {
                try await self.provider.update(id: target.id, expectedRevision: target.revision, change: change)
            }
            try authorize()
            return Self.mutation(updated)
        case "contacts.delete":
            let target = try Self.target(arguments, allowed: [])
            try await requireAccess(authorize)
            _ = try await existing(target, authorize: authorize)
            try authorize()
            try await run { try await self.provider.delete(id: target.id, expectedRevision: target.revision) }
            try authorize()
            return ["id": .string(target.id), "deleted": .boolean(true)]
        default:
            throw AppleDeviceToolError.unsupportedOperation
        }
    }

    // MARK: Steps

    private func requireAccess(_ authorize: @MainActor () throws -> Void) async throws {
        try authorize()
        switch await status() {
        case .available: break
        case .unavailable: throw AppleDeviceToolError.unavailable
        case .notRequested, .denied: throw AppleDeviceToolError.authorizationRequired
        }
    }

    /// The contact the request names, as it reads now, if its revision is the one the agent saw.
    private func existing(
        _ target: Target, authorize: @MainActor () throws -> Void
    ) async throws -> DeviceContactRecord {
        let current = try await run { try await self.provider.record(id: target.id) }
        try authorize()
        guard let current else { throw Failure.notFound }
        guard current.revision == target.revision else { throw AppleDeviceToolError.staleRevision }
        return current
    }

    /// Runs one provider call and names what went wrong the way the agent expects.
    private func run<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as DeviceContactsProviderError {
            switch error {
            case .notFound: throw Failure.notFound
            case .staleRevision: throw AppleDeviceToolError.staleRevision
            case .unauthorized: throw AppleDeviceToolError.authorizationRequired
            case .failed: throw AppleDeviceToolError.nativeFailure
            }
        }
    }

    /// Read again after the wait: the person can change what they share while a list is out.
    private func currentAccess() throws -> String {
        switch provider.authorization {
        case .authorized: return "full"
        case .limited: return "limited"
        case .notDetermined, .denied: throw AppleDeviceToolError.authorizationRequired
        case .restricted: throw AppleDeviceToolError.unavailable
        }
    }

    // MARK: Results

    private func payload(_ page: DeviceContactsPage, access: String) throws -> [String: BighelpJSONValue] {
        var contacts: [BighelpJSONValue] = []
        var bytes = 0
        var truncated = page.truncated
        let encoder = JSONEncoder()
        for record in page.records {
            let value = Self.json(record)
            let size = (try? encoder.encode(value).count) ?? Self.maximumResultBytes
            if bytes + size > Self.maximumResultBytes, !contacts.isEmpty {
                truncated = true
                break
            }
            // One contact too big to fit alone never reaches the agent in pieces.
            guard size <= Self.maximumResultBytes else { throw AppleDeviceToolError.resultLimitExceeded }
            bytes += size
            contacts.append(value)
        }
        return [
            "contacts": .array(contacts),
            "truncated": .boolean(truncated),
            "access": .string(access),
        ]
    }

    static func mutation(_ record: DeviceContactRecord) -> [String: BighelpJSONValue] {
        ["id": .string(record.id), "revision": .string(record.revision)]
    }

    static func json(_ record: DeviceContactRecord) -> BighelpJSONValue {
        var contact: [String: BighelpJSONValue] = [
            "id": .string(record.id),
            "revision": .string(record.revision),
        ]
        let texts: [(String, String)] = [
            ("givenName", record.givenName), ("familyName", record.familyName), ("nickname", record.nickname),
            ("organization", record.organization), ("jobTitle", record.jobTitle),
        ]
        for (key, value) in texts where !value.isEmpty { contact[key] = .string(value) }
        if let birthday = record.birthday { contact["birthday"] = .string(birthday.text) }
        func labeled(_ values: [DeviceContactLabeledValue]) -> BighelpJSONValue {
            .array(values.map { value in
                var item: [String: BighelpJSONValue] = ["value": .string(value.value)]
                if let label = DeviceContactLabels.agentLabel(value.label) { item["label"] = .string(label) }
                return .object(item)
            })
        }
        if !record.phones.isEmpty { contact["phones"] = labeled(record.phones) }
        if !record.emails.isEmpty { contact["emails"] = labeled(record.emails) }
        if !record.urls.isEmpty { contact["urls"] = labeled(record.urls) }
        if !record.addresses.isEmpty {
            contact["addresses"] = .array(record.addresses.map { address in
                var item: [String: BighelpJSONValue] = [:]
                if let label = DeviceContactLabels.agentLabel(address.label) { item["label"] = .string(label) }
                let parts: [(String, String)] = [
                    ("street", address.street), ("city", address.city), ("region", address.region),
                    ("postalCode", address.postalCode), ("country", address.country),
                ]
                for (key, value) in parts where !value.isEmpty { item[key] = .string(value) }
                return .object(item)
            })
        }
        return .object(contact)
    }

    // MARK: Arguments

    private struct ListRequest {
        let query: String?
        let limit: Int

        init(_ arguments: [String: BighelpJSONValue]) throws {
            guard Set(arguments.keys).isSubset(of: ["query", "limit"]) else { throw AppleDeviceToolError.invalidArguments }
            if let value = arguments["query"] {
                guard let text = value.string, (1...DeviceContactsTool.maximumQueryLength).contains(text.count),
                      DeviceContactsTool.isClean(text) else { throw AppleDeviceToolError.invalidArguments }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw AppleDeviceToolError.invalidArguments }
                query = trimmed
            } else {
                query = nil
            }
            if let value = arguments["limit"] {
                guard let limit = value.integer, (1...DeviceContactsTool.maximumLimit).contains(limit) else {
                    throw AppleDeviceToolError.invalidArguments
                }
                self.limit = limit
            } else {
                limit = DeviceContactsTool.defaultLimit
            }
        }
    }

    private struct Target {
        let id: String
        let revision: String
    }

    static let fieldKeys: Set<String> = [
        "givenName", "familyName", "organization", "nickname", "jobTitle", "birthday",
        "phones", "emails", "urls", "addresses",
    ]

    /// `id` and `expectedRevision`, plus any of `allowed`.
    private static func target(_ arguments: [String: BighelpJSONValue], allowed: Set<String>) throws -> Target {
        guard Set(arguments.keys).isSubset(of: allowed.union(["id", "expectedRevision"])),
              let id = arguments["id"]?.string, !id.isEmpty, id.count <= 512,
              let revision = arguments["expectedRevision"]?.string, !revision.isEmpty, revision.count <= 512
        else { throw AppleDeviceToolError.invalidArguments }
        return Target(id: id, revision: revision)
    }

    /// A create needs a name of some kind; the other fields are optional.
    static func createChange(_ arguments: [String: BighelpJSONValue]) throws -> DeviceContactChange {
        guard Set(arguments.keys).isSubset(of: fieldKeys) else { throw AppleDeviceToolError.invalidArguments }
        let change = try self.change(arguments)
        let empty = DeviceContactRecord(id: "")
        guard empty.applying(change).hasName else { throw AppleDeviceToolError.invalidArguments }
        return change
    }

    /// The fields of an update (or a create), checked and cleaned. Keys that aren't fields are ignored
    /// here: the caller has already refused any that aren't allowed.
    static func change(_ arguments: [String: BighelpJSONValue]) throws -> DeviceContactChange {
        var change = DeviceContactChange()
        func text(_ key: String) throws -> String? {
            guard let value = arguments[key] else { return nil }
            guard let string = value.string, string.count <= maximumNameLength, isClean(string) else {
                throw AppleDeviceToolError.invalidArguments
            }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        change.givenName = try text("givenName")
        change.familyName = try text("familyName")
        change.organization = try text("organization")
        change.nickname = try text("nickname")
        change.jobTitle = try text("jobTitle")
        if let value = arguments["birthday"] {
            guard let string = value.string else { throw AppleDeviceToolError.invalidArguments }
            if string.isEmpty {
                change.birthday = .clear
            } else {
                guard let birthday = DeviceContactBirthday(string) else { throw AppleDeviceToolError.invalidArguments }
                change.birthday = .set(birthday)
            }
        }
        change.phones = try labeledValues(arguments["phones"], kind: .phone, maximumCount: 10, maximumLength: 64)
        change.emails = try labeledValues(arguments["emails"], kind: .other, maximumCount: 10, maximumLength: 320)
        change.urls = try labeledValues(arguments["urls"], kind: .other, maximumCount: 5, maximumLength: 2_048)
        change.addresses = try addresses(arguments["addresses"])
        return change
    }

    private static func labeledValues(
        _ value: BighelpJSONValue?, kind: DeviceContactLabels.Kind, maximumCount: Int, maximumLength: Int
    ) throws -> [DeviceContactLabeledValue]? {
        guard let value else { return nil }
        guard let items = value.array, items.count <= maximumCount else { throw AppleDeviceToolError.invalidArguments }
        return try items.map { item in
            guard let object = item.object, Set(object.keys).isSubset(of: ["label", "value"]),
                  let raw = object["value"]?.string, isClean(raw) else { throw AppleDeviceToolError.invalidArguments }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maximumLength else { throw AppleDeviceToolError.invalidArguments }
            return DeviceContactLabeledValue(label: try label(object["label"], kind: kind), value: text)
        }
    }

    private static func addresses(_ value: BighelpJSONValue?) throws -> [DeviceContactAddress]? {
        guard let value else { return nil }
        guard let items = value.array, items.count <= 5 else { throw AppleDeviceToolError.invalidArguments }
        return try items.map { item in
            guard let object = item.object,
                  Set(object.keys).isSubset(of: ["label", "street", "city", "region", "postalCode", "country"])
            else { throw AppleDeviceToolError.invalidArguments }
            func part(_ key: String, allowsLineBreak: Bool = false) throws -> String {
                guard let value = object[key] else { return "" }
                guard let string = value.string, string.count <= maximumNameLength,
                      isClean(string, allowsLineBreak: allowsLineBreak) else { throw AppleDeviceToolError.invalidArguments }
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let address = DeviceContactAddress(
                label: try label(object["label"], kind: .other), street: try part("street", allowsLineBreak: true),
                city: try part("city"), region: try part("region"), postalCode: try part("postalCode"),
                country: try part("country"))
            guard !address.isEmpty else { throw AppleDeviceToolError.invalidArguments }
            return address
        }
    }

    private static func label(_ value: BighelpJSONValue?, kind: DeviceContactLabels.Kind) throws -> String? {
        guard let value else { return nil }
        guard let string = value.string, isClean(string) else { throw AppleDeviceToolError.invalidArguments }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLabelLength else { throw AppleDeviceToolError.invalidArguments }
        return DeviceContactLabels.contactsLabel(text, kind: kind)
    }

    /// No control characters (a line break only where the field is a street).
    nonisolated static func isClean(_ text: String, allowsLineBreak: Bool = false) -> Bool {
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || (allowsLineBreak && $0 == "\n") }
    }
}

// MARK: - Labels

/// The names an agent uses for labels, and Apple's constants for them.
enum DeviceContactLabels {
    enum Kind { case phone, other }

    /// Apple wraps its built-in labels like `_$!<Home>!$_`.
    private static let wrapperPrefix = "_$!<"
    private static let wrapperSuffix = ">!$_"

    private static var common: [(agent: String, apple: String)] {
        [("home", CNLabelHome), ("work", CNLabelWork), ("other", CNLabelOther)]
    }

    private static var phoneOnly: [(agent: String, apple: String)] {
        [("mobile", CNLabelPhoneNumberMobile), ("iPhone", CNLabelPhoneNumberiPhone), ("main", CNLabelPhoneNumberMain)]
    }

    /// The label to store for what an agent wrote: Apple's constant for a name it knows, else the text.
    /// Mobile, iPhone and main are phone labels; on anything else they stay the person's own text.
    static func contactsLabel(_ agentLabel: String, kind: Kind) -> String {
        let table = kind == .phone ? common + phoneOnly : common
        let lowered = agentLabel.lowercased()
        return table.first { $0.agent.lowercased() == lowered }?.apple ?? agentLabel
    }

    /// The label to show an agent for what Contacts holds, at most 40 characters. Nil for none.
    static func agentLabel(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if let known = (common + phoneOnly).first(where: { $0.apple == stored }) { return known.agent }
        var text = stored
        if text.hasPrefix(wrapperPrefix), text.hasSuffix(wrapperSuffix), text.count > wrapperPrefix.count + wrapperSuffix.count {
            text = String(text.dropFirst(wrapperPrefix.count).dropLast(wrapperSuffix.count))
        }
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(DeviceContactsTool.maximumLabelLength))
    }
}

// MARK: - Search

/// Which contacts a `query` finds. The real store and the test store both use it.
enum DeviceContactMatcher {
    static func matches(_ record: DeviceContactRecord, query: String?) -> Bool {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return true }
        if nameMatches(record, query) { return true }
        if isPhoneLike(query) {
            let wanted = digits(query)
            return record.phones.contains { phone in
                let have = digits(phone.value)
                // "+1 555 0100" finds a number saved as "555-0100".
                return have.contains(wanted) || (have.count >= 7 && wanted.hasSuffix(have))
            }
        }
        if query.contains("@"), !query.contains(where: \.isWhitespace) {
            return record.emails.contains { $0.value.range(of: query, options: .caseInsensitive) != nil }
        }
        return false
    }

    private static func nameMatches(_ record: DeviceContactRecord, _ query: String) -> Bool {
        let haystack = [record.givenName, record.familyName, record.nickname, record.organization].joined(separator: " ")
        let words = query.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy {
            haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Digits with the usual separators, and enough of them to be a number.
    static func isPhoneLike(_ query: String) -> Bool {
        query.allSatisfy { $0.isASCII && ($0.isNumber || "+-(). ".contains($0)) } && digits(query).count >= 3
    }

    private static func digits(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber })
    }
}

// MARK: - Apple's Contacts

/// The real address book. Reads and saves run off the main actor, because Apple says they block.
@MainActor
final class LiveDeviceContactsProvider: DeviceContactsProviding {
    /// The only keys ever fetched. `CNContactNoteKey` is not here and must never be: notes need an
    /// entitlement Apple gives to few apps.
    nonisolated static let keyNames: [String] = [
        CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
        CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactBirthdayKey, CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey, CNContactUrlAddressesKey, CNContactPostalAddressesKey,
    ]

    private let store = CNContactStore()

    var authorization: DeviceContactsAuthorization { Self.mapAuthorization(CNContactStore.authorizationStatus(for: .contacts)) }

    nonisolated static func mapAuthorization(_ status: CNAuthorizationStatus) -> DeviceContactsAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .restricted: return .restricted
        default:
            // Newer than the oldest iOS bighelp runs on.
            if #available(iOS 18.0, *), status == .limited { return .limited }
            return .restricted
        }
    }

    func requestAccess() async -> Bool {
        let store = store
        // iOS answers on its own queue: a Sendable callback, or a main-actor closure traps there.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestAccess(for: .contacts) { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
    }

    func list(query: String?, limit: Int) async throws -> DeviceContactsPage {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            let request = CNContactFetchRequest(keysToFetch: Self.keys)
            request.sortOrder = .userDefault
            var records: [DeviceContactRecord] = []
            var truncated = false
            do {
                try store.enumerateContacts(with: request) { contact, stop in
                    let record = Self.record(from: contact)
                    guard DeviceContactMatcher.matches(record, query: query) else { return }
                    if records.count == limit {
                        truncated = true
                        stop.pointee = true
                    } else {
                        records.append(record)
                    }
                }
            } catch {
                throw DeviceContactsProviderError.failed
            }
            return DeviceContactsPage(records: records, truncated: truncated)
        }.value
    }

    func record(id: String) async throws -> DeviceContactRecord? {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            return try Self.fetch(id, in: store).map(Self.record(from:))
        }.value
    }

    func create(_ change: DeviceContactChange) async throws -> DeviceContactRecord {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            let contact = CNMutableContact()
            Self.apply(change, to: contact)
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            // Right before the save: iOS may have withdrawn access during the wait.
            try Self.requireAccess()
            do { try store.execute(request) } catch { throw DeviceContactsProviderError.failed }
            // Read it back, so the revision is the one a later list shows.
            if let saved = try? Self.fetch(contact.identifier, in: store) { return Self.record(from: saved) }
            return Self.record(from: contact)
        }.value
    }

    func update(id: String, expectedRevision: String, change: DeviceContactChange) async throws -> DeviceContactRecord {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            guard let current = try Self.fetch(id, in: store) else { throw DeviceContactsProviderError.notFound }
            guard Self.record(from: current).revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
            guard let contact = current.mutableCopy() as? CNMutableContact else { throw DeviceContactsProviderError.failed }
            Self.apply(change, to: contact)
            let request = CNSaveRequest()
            request.update(contact)
            try Self.requireAccess()
            do { try store.execute(request) } catch { throw DeviceContactsProviderError.failed }
            if let saved = try? Self.fetch(id, in: store) { return Self.record(from: saved) }
            return Self.record(from: contact)
        }.value
    }

    func delete(id: String, expectedRevision: String) async throws {
        let store = store
        try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            guard let current = try Self.fetch(id, in: store) else { throw DeviceContactsProviderError.notFound }
            guard Self.record(from: current).revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
            guard let contact = current.mutableCopy() as? CNMutableContact else { throw DeviceContactsProviderError.failed }
            let request = CNSaveRequest()
            request.delete(contact)
            try Self.requireAccess()
            do { try store.execute(request) } catch { throw DeviceContactsProviderError.failed }
        }.value
    }

    // MARK: Store helpers (off the main actor)

    private nonisolated static var keys: [CNKeyDescriptor] { keyNames.map { $0 as CNKeyDescriptor } }

    private nonisolated static func requireAccess() throws {
        switch mapAuthorization(CNContactStore.authorizationStatus(for: .contacts)) {
        case .authorized, .limited: return
        case .notDetermined, .denied, .restricted: throw DeviceContactsProviderError.unauthorized
        }
    }

    /// Nil when there is no such contact, or the person didn't share it.
    private nonisolated static func fetch(_ id: String, in store: CNContactStore) throws -> CNContact? {
        do {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        } catch let error as NSError where error.domain == CNErrorDomain && error.code == CNError.Code.recordDoesNotExist.rawValue {
            return nil
        } catch {
            throw DeviceContactsProviderError.failed
        }
    }

    // MARK: Conversion

    nonisolated static func record(from contact: CNContact) -> DeviceContactRecord {
        func labeled<Value>(_ values: [CNLabeledValue<Value>], _ text: (Value) -> String) -> [DeviceContactLabeledValue] {
            values.map { DeviceContactLabeledValue(label: $0.label, value: text($0.value)) }
        }
        var birthday: DeviceContactBirthday?
        if let parts = contact.birthday, let month = parts.month, let day = parts.day {
            birthday = DeviceContactBirthday(year: parts.year, month: month, day: day)
        }
        return DeviceContactRecord(
            id: contact.identifier, givenName: contact.givenName, familyName: contact.familyName,
            nickname: contact.nickname, organization: contact.organizationName, jobTitle: contact.jobTitle,
            birthday: birthday,
            phones: labeled(contact.phoneNumbers) { $0.stringValue },
            emails: labeled(contact.emailAddresses) { $0 as String },
            urls: labeled(contact.urlAddresses) { $0 as String },
            addresses: contact.postalAddresses.map {
                DeviceContactAddress(label: $0.label, street: $0.value.street, city: $0.value.city,
                                     region: $0.value.state, postalCode: $0.value.postalCode, country: $0.value.country)
            })
    }

    /// Sets only what `change` names, and only keys `keys` fetched.
    nonisolated static func apply(_ change: DeviceContactChange, to contact: CNMutableContact) {
        if let value = change.givenName { contact.givenName = value }
        if let value = change.familyName { contact.familyName = value }
        if let value = change.nickname { contact.nickname = value }
        if let value = change.organization { contact.organizationName = value }
        if let value = change.jobTitle { contact.jobTitle = value }
        switch change.birthday {
        case .clear:
            contact.birthday = nil
        case .set(let birthday):
            contact.birthday = DateComponents(calendar: Calendar(identifier: .gregorian), year: birthday.year,
                                              month: birthday.month, day: birthday.day)
        case nil:
            break
        }
        if let values = change.phones {
            contact.phoneNumbers = values.map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
        }
        if let values = change.emails {
            contact.emailAddresses = values.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        }
        if let values = change.urls {
            contact.urlAddresses = values.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        }
        if let values = change.addresses {
            contact.postalAddresses = values.map { address in
                let postal = CNMutablePostalAddress()
                postal.street = address.street
                postal.city = address.city
                postal.state = address.region
                postal.postalCode = address.postalCode
                postal.country = address.country
                return CNLabeledValue(label: address.label, value: postal as CNPostalAddress)
            }
        }
    }
}

/// Demo mode: a few made-up people, kept in memory, so screens and tests need no iOS permission.
@MainActor
final class DemoDeviceContactsProvider: DeviceContactsProviding {
    private var records: [DeviceContactRecord] = [
        DeviceContactRecord(
            id: "demo-contact-1", givenName: "Avery", familyName: "Example", organization: "Sample Co",
            phones: [DeviceContactLabeledValue(label: CNLabelPhoneNumberMobile, value: "555-0100")],
            emails: [DeviceContactLabeledValue(label: CNLabelWork, value: "avery@example.com")]),
        DeviceContactRecord(id: "demo-contact-2", givenName: "Sam", familyName: "Sample"),
    ]

    var authorization: DeviceContactsAuthorization { .authorized }
    func requestAccess() async -> Bool { true }

    func list(query: String?, limit: Int) async throws -> DeviceContactsPage {
        let matches = records.filter { DeviceContactMatcher.matches($0, query: query) }
        return DeviceContactsPage(records: Array(matches.prefix(limit)), truncated: matches.count > limit)
    }

    func record(id: String) async throws -> DeviceContactRecord? { records.first { $0.id == id } }

    func create(_ change: DeviceContactChange) async throws -> DeviceContactRecord {
        let record = DeviceContactRecord(id: "demo-contact-\(UUID().uuidString.lowercased())").applying(change)
        records.append(record)
        return record
    }

    func update(id: String, expectedRevision: String, change: DeviceContactChange) async throws -> DeviceContactRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw DeviceContactsProviderError.notFound }
        guard records[index].revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
        records[index] = records[index].applying(change)
        return records[index]
    }

    func delete(id: String, expectedRevision: String) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw DeviceContactsProviderError.notFound }
        guard records[index].revision == expectedRevision else { throw DeviceContactsProviderError.staleRevision }
        records.remove(at: index)
    }
}
