import Foundation
import Testing
@testable import Bighelp

@MainActor
struct HostSignInMethodTests {
    private func discovery(gated: Bool, pkce: Bool = true, providers: [(String, Bool)] = []) throws -> HostAuthenticationDiscovery {
        HostAuthenticationDiscovery(
            endpoint: try DirectHermesEndpoint(address: "https://hermes.example.com"),
            requiresAuthentication: gated, nativePKCE: pkce,
            providers: providers.map { .init(id: $0.0, name: $0.0, supportsPassword: $0.1) })
    }

    @Test func anOpenHostNeedsNoSignIn() throws {
        #expect(HostAuthenticationDiscovery.preferredMethod(for: try discovery(gated: false, pkce: false)) == .dashboard)
    }

    @Test func passwordOnlyHostsGetTheUsernameAndPasswordForm() throws {
        let host = try discovery(gated: true, providers: [("basic", true)])
        #expect(host.supportsPassword)
        #expect(HostAuthenticationDiscovery.preferredMethod(for: host) == .password)
    }

    @Test func signingInAgainStartsTheBrowserWhenTheHostOffersIt() throws {
        let host = try discovery(gated: true, providers: [("basic", true)])
        #expect(HostAuthenticationDiscovery.preferredMethod(for: host, reauthenticating: true) == .browser)
        let token = try discovery(gated: true, pkce: false)
        #expect(HostAuthenticationDiscovery.preferredMethod(for: token, reauthenticating: true) == .token)
    }

    @Test func singleSignOnHostsLeadWithTheBrowser() throws {
        let sso = try discovery(gated: true, providers: [("self-hosted", false)])
        #expect(HostAuthenticationDiscovery.preferredMethod(for: sso) == .browser)
        let mixed = try discovery(gated: true, providers: [("basic", true), ("self-hosted", false)])
        #expect(HostAuthenticationDiscovery.preferredMethod(for: mixed) == .browser)
        #expect(mixed.supportsPassword, "Username & password stays available as a choice")
    }

    @Test func everyPrivateNameAllowsPlainHTTPInTheAppTransportRules() throws {
        let transport = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        let domains = try #require(transport["NSExceptionDomains"] as? [String: [String: Any]])
        for suffix in DirectHermesEndpoint.privateNameSuffixes where suffix != "local" {
            #expect(domains[suffix]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true, "\(suffix)")
            #expect(domains[suffix]?["NSIncludesSubdomains"] as? Bool == true, "\(suffix)")
        }
        #expect(DirectHermesEndpoint.isPrivateNetworkHost("hermes.localhost"))
    }

    @Test func hostsWithOnlyTokensAskForAToken() throws {
        let tokenOnly = try discovery(gated: true, pkce: false)
        #expect(HostAuthenticationDiscovery.preferredMethod(for: tokenOnly) == .token)
        // Providers that failed to load still leave browser sign-in available.
        let unknown = try discovery(gated: true, providers: [])
        #expect(HostAuthenticationDiscovery.preferredMethod(for: unknown) == .browser)
    }
}
