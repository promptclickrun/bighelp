import SwiftUI
import UIKit

enum AvatarFileURL {
    static func resolve(fileName: String?, in directory: URL?) -> URL? {
        guard
            let fileName,
            !fileName.isEmpty,
            fileName != ".",
            fileName != "..",
            !fileName.contains("/"),
            !fileName.contains("\\")
        else {
            return nil
        }
        guard let directory else { return nil }
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }
}

struct AvatarView: View {
    enum Kind { case agent, person }

    let stableID: String
    let displayName: String
    let imageURL: URL?
    var size: CGFloat
    var kind: Kind
    var state: AgentLiveState?

    init(
        stableID: String,
        displayName: String,
        imageURL: URL? = nil,
        size: CGFloat = 44,
        kind: Kind = .agent,
        state: AgentLiveState? = nil
    ) {
        self.stableID = stableID
        self.displayName = displayName
        self.imageURL = imageURL
        self.size = size
        self.kind = kind
        self.state = state
    }

    var body: some View {
        Group {
            if let imageURL, let image = UIImage(contentsOfFile: imageURL.bighelpFileSystemPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .overlay(alignment: .topTrailing) {
                        if state == .nudge {
                            Circle().fill(BighelpBrand.ember)
                                .frame(width: size * 0.24, height: size * 0.24)
                                .overlay(Circle().stroke(.white, lineWidth: max(1, size * 0.03)))
                        }
                    }
            } else if kind == .agent {
                // Agents are organic blobs and orbs; the avatar is their live status.
                AgentPersonaAvatar(persona: AgentPersona(stableID: stableID), state: state ?? .idle, size: size)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: size, height: size)
                    .background(theme.incomingMessageBackground, in: .circle)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(displayName)
        .accessibilityIdentifier("avatar.\(stableID)")
    }

    private var initials: String {
        let words = displayName.split(whereSeparator: \.isWhitespace)
        let characters = words.prefix(2).compactMap { $0.first }.map(String.init)
        return characters.isEmpty ? "?" : characters.joined().uppercased()
    }

    @BighelpThemeReader private var theme
}

struct AvatarStack: View {
    struct Avatar: Identifiable {
        let stableID: String
        let displayName: String
        let imageURL: URL?

        var id: String { stableID }
    }

    let avatars: [Avatar]
    var size: CGFloat
    var outlineColor: Color

    init(avatars: [Avatar], size: CGFloat = 32, outlineColor: Color = .white) {
        self.avatars = avatars
        self.size = size
        self.outlineColor = outlineColor
    }

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(avatars) { avatar in
                AvatarView(
                    stableID: avatar.stableID,
                    displayName: avatar.displayName,
                    imageURL: avatar.imageURL,
                    size: size
                )
                .overlay(Circle().stroke(outlineColor, lineWidth: 2))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
