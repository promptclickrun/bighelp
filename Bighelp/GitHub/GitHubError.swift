import Foundation

/// Deliberately carries no upstream body, URL, token or underlying NSError.
enum GitHubError: Error, Equatable, Sendable, LocalizedError {
    case notConfigured, invalidConfiguration, invalidResponse, invalidInput
    case cancelled, expiredCode, authorizationDenied, deviceFlowDisabled
    case reconnectRequired, accountNotConfirmed, accessUnavailable, notFound
    case vaultUnavailable, networkUnavailable, responseTooLarge, identityChanged
    case invalidPersonalAccessToken, credentialSelectionRequired, personalAccessTokenReplacementRequired
    case throttled(until: Date)

    var errorDescription: String? {
        switch self {
        case .invalidPersonalAccessToken: "Enter the token exactly as issued, without spaces, line breaks or other header-unsafe characters."
        case .credentialSelectionRequired: "Choose the specific saved credential for this GitHub account."
        case .personalAccessTokenReplacementRequired: "This personal access token is expired or revoked. Replace it with a token issued by GitHub; it cannot be refreshed by Bighelp."
        case .notConfigured: "Device-code login needs this build’s GitHub App registration. You can use a personal access token independently, or keep using Bighelp without GitHub."
        case .invalidConfiguration: "The GitHub App registration settings need to be corrected."
        case .invalidResponse: "GitHub returned an unexpected response. Please try again."
        case .invalidInput: "Use a qualified GitHub repository and a valid reference or search."
        case .cancelled: "GitHub operation cancelled."
        case .expiredCode: "This code expired. Connect again to request a new code."
        case .authorizationDenied: "GitHub authorization was declined."
        case .deviceFlowDisabled: "Device authorization must be enabled for the Bighelp GitHub App."
        case .reconnectRequired: "Reconnect GitHub to continue. Your saved references have not been sent."
        case .accountNotConfirmed: "Select and confirm a GitHub account first."
        case .accessUnavailable: "GitHub access is unavailable. Check token permissions, repository/resource-owner selection, organization approval and SSO. Device login also requires an eligible App installation."
        case .notFound: "This GitHub resource is no longer available to the selected account."
        case .vaultUnavailable: "GitHub credentials could not be accessed securely. Unlock your device and try again."
        case .networkUnavailable: "GitHub could not be reached. Try again when you are online."
        case .responseTooLarge: "GitHub returned more data than Bighelp can safely load. Narrow your selection."
        case .identityChanged: "The GitHub identity or resource changed. Select it again before sharing."
        case .throttled: "GitHub is limiting requests. Wait before trying again."
        }
    }

    static func safe(_ error: any Error) -> GitHubError {
        if error is CancellationError { return .cancelled }
        return error as? GitHubError ?? .networkUnavailable
    }
}
