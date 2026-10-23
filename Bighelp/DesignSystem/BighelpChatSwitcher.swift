import SwiftUI

/// The switcher beside a chat: in Bots mode the faces of the bots on top of the home (then the
/// ones under them), in Code mode the running sessions. A tap goes to that chat; Back still goes
/// home. It lives in the Duo's side column when folded (on unless turned off), and beside the
/// chat on iPad and Mac in landscape once turned on (Settings › Experience › Chat switcher).
enum BighelpChatSwitcher {
    /// Six at most, the most the Bots home's top shows.
    static let limit = 6

    /// Where the setting's row shows: the Duo, iPad and Mac. Other iPhones never show the switcher.
    static func isOffered(screen: BighelpScreenGeometry) -> Bool {
        screen.posture != .standard || isPadOrMac
    }

    /// Whether a chat shows it now.
    static func isShown(isOn: Bool, screen: BighelpScreenGeometry,
                        horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        guard isOn else { return false }
        switch screen.posture {
        case .cover: return true
        // Open, the list beside the chat already does its job; upright, it's a big phone.
        case .open, .openUpright: return false
        case .standard: return isPadOrMac && horizontalSizeClass == .regular && screen.isLandscape
        }
    }

    /// Before the person picks: on for phones, where only the Duo shows it, off on iPad and Mac.
    static var isOnByDefault: Bool { BighelpScreenPosture.isPhone }

    static var isPadOrMac: Bool {
        #if os(iOS)
        BighelpPlatform.isMac || UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
}

/// One stop in the switcher.
struct BighelpChatSwitcherStop: Identifiable {
    let id: String
    /// What VoiceOver and the pointer's help say: the bot's or session's name.
    let title: String
    /// What it's doing, after its name ("Working", "Needs you"); empty when there's nothing to say.
    var state = ""
    let isCurrent: Bool
    let face: AnyView
    let open: () -> Void
}

/// A slim glass column of faces, one above the other.
struct BighelpChatSwitcherColumn: View {
    let stops: [BighelpChatSwitcherStop]

    @State private var taps = 0

    var body: some View {
        VStack(spacing: BighelpTokens.space4) {
            ForEach(stops.prefix(BighelpChatSwitcher.limit)) { stop in
                Button {
                    guard !stop.isCurrent else { return }
                    BighelpKeyboard.dismiss()
                    taps += 1
                    stop.open()
                } label: {
                    stop.face
                        .frame(width: 38, height: 38)
                        .padding(3)
                        .overlay {
                            if stop.isCurrent {
                                Circle().strokeBorder(theme.primaryText, lineWidth: 2).accessibilityHidden(true)
                            }
                        }
                        .frame(width: 48, height: 48)
                        .contentShape(.circle)
                }
                .buttonStyle(.bighelpTilePress)
                .bighelpHelp(stop.title)
                .accessibilityLabel(stop.title)
                .accessibilityValue(stop.state)
                .accessibilityAddTraits(stop.isCurrent ? .isSelected : [])
                .accessibilityIdentifier("chat-switcher.stop")
            }
        }
        .padding(.vertical, 6)
        .frame(width: 54)
        .bighelpNavigationGlass(in: Capsule())
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch chats")
        .accessibilityIdentifier("chat-switcher")
    }

    @BighelpThemeReader private var theme
}
