import Foundation
import Testing
@testable import Bighelp

/// App Review 5.1.1(i), 5.1.2(i): nobody shares data before agreeing, including a bighelp set up
/// before the agreement existed. After agreeing, nobody is asked again.
struct AIDataConsentTests {
    @Test func anyoneWhoHasntAgreedIsAskedOutsideFirstSetup() {
        #expect(AIDataConsent.needsAsking(agreed: false, inFirstSetup: false, usesDemoData: false))
    }

    @Test func firstSetupAsksInItsOwnFlow() {
        #expect(!AIDataConsent.needsAsking(agreed: false, inFirstSetup: true, usesDemoData: false))
    }

    @Test func nobodyIsAskedAgainAfterAgreeing() {
        #expect(!AIDataConsent.needsAsking(agreed: true, inFirstSetup: false, usesDemoData: false))
    }

    @Test func theAgreementIsKeptUnderItsOriginalKey() {
        let suite = "ai-consent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AIDataConsent.key == "bighelp.privacy.ai-data-agreed")
        defaults.set(true, forKey: AIDataConsent.key)
        #expect(AIDataConsent.isAgreed(defaults))
    }
}
