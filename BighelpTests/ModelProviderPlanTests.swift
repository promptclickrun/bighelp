import Foundation
import Testing
@testable import Bighelp

/// The model picker's "17% left · resets 3:00 PM", read from `model.options`.
struct ModelProviderPlanTests {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let english = Locale(identifier: "en_US")
    /// 1:25 PM UTC on a made-up day.
    private static let now = Date(timeIntervalSince1970: 1_791_984_300)

    private static func summary(_ row: [String: BighelpJSONValue], now: Date = now) -> String? {
        ModelProviderPlan(row: row)?.summary(now: now, locale: english, timeZone: utc)
            .map { $0.text.replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    private static func window(used: Double, resets: String?, label: String = "Session") -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = ["label": .string(label), "used_percent": .number(used),
                                                 "scope": .string("account")]
        if let resets { value["resets_at"] = .string(resets) }
        return .object(value)
    }

    @Test func theTightestWindowSaysHowMuchIsLeftAndWhenItResets() {
        // Python's isoformat: microseconds and an offset.
        let row: [String: BighelpJSONValue] = ["slug": .string("demo"), "usage": .object(["windows": .array([
            Self.window(used: 40, resets: "2026-10-20T06:13:27+00:00", label: "Week"),
            Self.window(used: 83, resets: "2026-10-14T15:00:00.949495+00:00"),
        ])])]
        #expect(Self.summary(row) == "17% left · resets 3:00 PM")
        #expect(ModelProviderPlan(row: row)?.summary(now: Self.now)?.isLow == false)
    }

    @Test func aWindowWithoutAResetTimeStillSaysWhatIsLeftAndNearlyOutIsLow() {
        let row: [String: BighelpJSONValue] = ["usage": .object(["windows": .array([Self.window(used: 93.6, resets: nil)])])]
        #expect(Self.summary(row) == "6% left")
        #expect(ModelProviderPlan(row: row)?.summary(now: Self.now)?.isLow == true)
    }

    @Test func aResetFurtherAwayNamesTheDay() {
        let row: [String: BighelpJSONValue] = ["usage": .object(["windows": .array([
            Self.window(used: 7, resets: "2026-10-20T06:13:27+00:00"),
        ])])]
        #expect(Self.summary(row) == "93% left · resets Oct 20, 6:13 AM")
    }

    @Test func aWindowThatAlreadyResetIsLeftOut() {
        let row: [String: BighelpJSONValue] = ["usage": .object(["windows": .array([
            Self.window(used: 99, resets: "2026-10-14T12:00:00+00:00"),
            Self.window(used: 30, resets: "2026-10-14T18:00:00+00:00"),
        ])])]
        #expect(Self.summary(row) == "70% left · resets 6:00 PM")
    }

    @Test(arguments: [
        [String: BighelpJSONValue](),
        ["usage": .null, "limit": .null],
        ["usage": .object([:])],
        ["usage": .object(["windows": .array([])])],
        ["usage": .string("broken"), "limit": .integer(3)],
        ["usage": .object(["windows": .array([.object(["label": .string("Session"), "used_percent": .string("17")])])])],
    ])
    func aProviderThatReportsNothingUsableShowsNothing(row: [String: BighelpJSONValue]) {
        #expect(ModelProviderPlan(row: row) == nil)
    }

    @Test func unknownFieldsAreIgnored() {
        let row: [String: BighelpJSONValue] = ["usage": .object([
            "windows": .array([.object(["used_percent": .number(50), "resets_at": .string("not a date"),
                                        "future_field": .array([.null])])]),
            "something_new": .boolean(true),
        ])]
        #expect(Self.summary(row) == "50% left")
    }

    @Test func aLimitedLoginSaysWhenItLifts() {
        var row: [String: BighelpJSONValue] = [
            "limit": .object(["scope": .string("account"), "resets_at": .string("2026-10-14T15:00:00+00:00")]),
            "usage": .object(["windows": .array([Self.window(used: 20, resets: nil)])]),
        ]
        #expect(Self.summary(row) == "Limited until 3:00 PM")
        #expect(ModelProviderPlan(row: row)?.summary(now: Self.now)?.isLow == true)
        // Once the time passes the limit has lifted; the window speaks again.
        #expect(Self.summary(row, now: Self.now.addingTimeInterval(3 * 3600)) == "80% left")
        row["limit"] = .object(["scope": .string("account")])
        #expect(Self.summary(row) == "Limited")
    }

    @Test func aModelLimitedOnItsOwnSaysSoForThatModelOnly() throws {
        let plan = try #require(ModelProviderPlan(row: ["limit": .object([
            "scope": .string("models"), "models": .object(["big-model": .string("2026-10-14T15:00:00+00:00")]),
        ])]))
        #expect(plan.modelLimit("big-model", now: Self.now, locale: Self.english, timeZone: Self.utc)?
            .replacingOccurrences(of: "\u{202F}", with: " ") == "Limited until 3:00 PM")
        #expect(plan.modelLimit("small-model", now: Self.now) == nil)
        #expect(plan.summary(now: Self.now) == nil)
    }

    @Test func severalLoginsNeverShareOnePercentage() {
        func accounts(_ states: [(String, String?)]) -> [String: BighelpJSONValue] {
            ["usage": .object(["windows": .array([]), "accounts": .array(states.enumerated().map { index, state in
                var account: [String: BighelpJSONValue] = ["id": .string("account-\(index)"), "state": .string(state.0),
                                                           "windows": .array([Self.window(used: 10, resets: nil)])]
                if let reset = state.1 { account["resets_at"] = .string(reset) }
                return .object(account)
            })])]
        }
        #expect(Self.summary(accounts([("ready", nil), ("unknown", nil)])) == nil)
        #expect(Self.summary(accounts([("limited", "2026-10-14T15:00:00+00:00"), ("ready", nil)]))
                == "1 of 2 accounts limited")
        #expect(Self.summary(accounts([("limited", "2026-10-14T15:00:00+00:00"),
                                       ("limited", "2026-10-14T16:00:00+00:00")])) == "Limited until 3:00 PM")
        #expect(Self.summary(accounts([("limited", "2026-10-14T15:00:00+00:00"), ("limited", nil)])) == "Limited")
    }

    @Test @MainActor func theCatalogCarriesEachProvidersPlan() throws {
        let providers = try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(["providers": .array([
            .object(["slug": .string("plan"), "name": .string("Plan Cloud"), "models": .array([.string("m1")]),
                     "usage": .object(["windows": .array([Self.window(used: 83, resets: nil)])])]),
            .object(["slug": .string("plain"), "name": .string("Plain Cloud"), "models": .array([.string("m2")])]),
        ])])
        #expect(providers.first?.plan?.summary(now: Self.now)?.text == "17% left")
        #expect(providers.last?.plan == nil)
    }
}
