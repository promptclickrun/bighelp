import Foundation
import Darwin

struct HostAuthenticationDiscovery: Equatable {
    struct Provider: Equatable, Identifiable {
        let id: String
        let name: String
        let supportsPassword: Bool
    }
    let endpoint: DirectHermesEndpoint
    let requiresAuthentication: Bool
    let nativePKCE: Bool
    let providers: [Provider]
    var supportsToken: Bool { true }
    var supportsDashboard: Bool { !requiresAuthentication }
    var supportsPassword: Bool { nativePKCE && !providers.filter(\.supportsPassword).isEmpty }
    var supportsBrowser: Bool { nativePKCE && !providers.isEmpty }

    /// Hermes's status check needs no sign-in, so a refusal there comes from
    /// something in front of Hermes.
    enum Gate: Error, Equatable {
        /// A proxy asked for a username and password (HTTP basic auth).
        case passwordProxy
        /// Refused for another reason: a firewall, forward-auth or allow list.
        case blocked
        /// Sent to a login page, such as Cloudflare Access without a token.
        case loginPage
    }

    @MainActor
    static func discover(endpoint: DirectHermesEndpoint) async throws -> Self {
        let authenticator = DirectHermesAuthenticator(endpoint: endpoint)
        defer { authenticator.http.invalidate() }
        let discovery: DirectHermesAuthenticationDiscovery
        do {
            discovery = try await authenticator.discoverAuthentication()
        } catch DirectHermesError.invalidCredentials {
            let response = try? await authenticator.http.send(route: "/api/status")
            throw gate(challenge: response?.http.value(forHTTPHeaderField: "WWW-Authenticate"))
        } catch DirectHermesError.redirectRefused {
            throw Gate.loginPage
        }
        return Self(endpoint: endpoint, requiresAuthentication: discovery.authRequired,
            nativePKCE: discovery.supportsNativePKCE,
            providers: discovery.providers.map { Provider(id: $0.name, name: $0.displayName, supportsPassword: $0.supportsPassword) })
    }

    enum Method: String, Equatable { case dashboard, token, password, browser }

    /// The method a host most likely wants: none when it isn't gated, the
    /// credential form when every sign-in provider takes a password, the
    /// browser for single sign-on, and a token when it offers nothing else.
    static func preferredMethod(for discovery: Self, reauthenticating: Bool = false) -> Method {
        if discovery.supportsDashboard { return .dashboard }
        if reauthenticating, discovery.nativePKCE { return .browser }
        if discovery.supportsPassword, discovery.providers.allSatisfy(\.supportsPassword) { return .password }
        if discovery.nativePKCE { return .browser }
        return .token
    }

    static func gate(challenge: String?) -> Gate {
        let scheme = challenge?.trimmingCharacters(in: .whitespaces).prefix(6).lowercased() ?? ""
        return scheme.hasPrefix("basic") ? .passwordProxy : .blocked
    }
}

/// Keep the port a separate explicit input. Reject conflicting URL/port values
/// rather than silently changing the endpoint after credentials were entered.
enum HostAddressInput {
    static func endpoint(address: String, port: String, allowPrivateHTTP: Bool) throws -> DirectHermesEndpoint {
        var input = address
        var address = address
        if !input.contains("://") {
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, input, &ipv6) == 1 { input = "[\(input)]" }
            // With HTTP allowed, a bare private address ("10.8.0.5:9119") means the
            // plain-HTTP host people run on a VPN or home network. Typing https:// keeps TLS.
            let assumed = try DirectHermesEndpoint(address: address)
            let scheme = allowPrivateHTTP && DirectHermesEndpoint.isPrivateNetworkHost(assumed.host) ? "http://" : "https://"
            input = scheme + input
            address = input
        }
        // Validate the original address too: URLComponents must not repair tokens.
        let original = try DirectHermesEndpoint(address: address, allowPrivateHTTP: allowPrivateHTTP)
        guard !port.isEmpty else { return original }
        guard port.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(port), (1...65535).contains(number),
              var components = URLComponents(string: input), components.port == nil || components.port == number else {
            throw DirectHermesError.invalidEndpoint
        }
        components.port = number
        guard let url = components.url else { throw DirectHermesError.invalidEndpoint }
        return try DirectHermesEndpoint(address: url.absoluteString, allowPrivateHTTP: allowPrivateHTTP)
    }
}
