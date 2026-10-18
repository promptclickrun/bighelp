import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// The Bots widget: one, two or four chosen bots on a chosen gateway, each face
/// opening that bot's chat, from files the app writes for when it's closed.
@MainActor
struct BighelpBotsWidgetTests {
    private static let studio = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000002")!

    private func bot(_ id: String, hidden: Bool = false, isDefault: Bool = false) -> AgentProfile {
        AgentProfile(id: id, name: id.capitalized, role: "", summary: "", instructions: "", avatarFileName: nil,
                     isDefault: isDefault, placement: hidden ? AgentListPlacement(isHidden: true) : nil)
    }

    @Test func showsTheChosenBotsInTheirOrderElseTheGatewaysFirst() {
        let roster = BighelpBotsWidgetRoster(
            gateways: ["home": [.init(agentID: "thurman", name: "Thurman"), .init(agentID: "gordie", name: "Gordie"),
                                .init(agentID: "nova", name: "Nova")],
                       Self.studio.uuidString: [.init(agentID: "dolly", name: "Dolly")]],
            inUseHostID: "home")
        #expect(roster.shown(onGateway: nil, picked: ["nova", "thurman"]).map(\.agentID) == ["nova", "thurman"])
        #expect(roster.shown(onGateway: nil, picked: []).map(\.agentID) == ["thurman", "gordie", "nova"],
                "Nothing chosen yet: the gateway's first bots")
        #expect(roster.shown(onGateway: Self.studio.uuidString, picked: ["dolly"]).map(\.agentID) == ["dolly"])
        #expect(roster.shown(onGateway: "unknown", picked: ["dolly"]).isEmpty)
    }

    @Test func planListsEachGatewaysBotsPrimaryThenPinnedThenByName() {
        let profiles = [bot("zed"), bot("default", isDefault: true), bot("ivy"), bot("ghost", hidden: true), bot("bob")]
        let plan = BighelpBotsWidgetFeed.plan(current: profiles, primaryID: nil, pinnedIDs: ["ivy"], picture: { _ in nil },
                                              currentHostID: Self.studio, fleet: nil)
        #expect(plan.roster.inUseHostID == Self.studio.uuidString)
        #expect(plan.roster.bots(onGateway: nil).map(\.agentID) == ["default", "ivy", "bob", "zed"])
        #expect(plan.roster.bots(onGateway: Self.studio.uuidString) == plan.roster.bots(onGateway: nil))
        let key = BighelpPinnedAvatarWriter.key(hostID: Self.studio, agentID: "bob")
        #expect(plan.faces[key] == .shape(.defaultMark(for: "bob")), "A bot without a picture shows its default shape")
    }

    /// The app writes faces and the list; the widget, with the app closed, reads them back.
    @Test func facesAreWrittenAsShapesOrPhotosAndTheListReadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bots-widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let faces = folder.appending(path: "faces"), rosterURL = folder.appending(path: "roster.json")
        try FileManager.default.createDirectory(at: faces, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: faces.appending(path: "stale.png"))
        let photo = folder.appending(path: "photo.png")
        try photoPNG().write(to: photo)

        var plan = BighelpBotsWidgetFeed.Plan()
        plan.roster = BighelpBotsWidgetRoster(gateways: ["home": [
            .init(agentID: "photo", name: "Photo", faceKey: "a1"), .init(agentID: "shape", name: "Shape", faceKey: "b2"),
            .init(agentID: "gone", name: "Gone", faceKey: "c3"),
        ]], inUseHostID: "home")
        plan.faces = ["a1": .picture(photo), "b2": .shape(.defaultMark(for: "shape")),
                      "c3": .picture(folder.appending(path: "missing.png"))]
        let shape = try #require(SimpleBotMarkView.png(.defaultMark(for: "shape"), pixels: 180))
        BighelpBotsWidgetFeed.write(plan, drawn: ["b2": shape], faces: faces, roster: rosterURL)

        let bots = BighelpBotsWidgetRoster.load(from: rosterURL).bots(onGateway: nil)
        #expect(bots.map(\.agentID) == ["photo", "shape", "gone"])
        #expect(bots[0].faceKey == "a1" && !bots[0].isShape, "A photo sits in a circle")
        #expect(bots[1].faceKey == "b2" && bots[1].isShape, "A Simple Bot shape stands free")
        #expect(bots[2].faceKey == nil, "No picture to copy: its first letter")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: faces.path))
        #expect(files == ["a1.png", "b2.png"], "Faces no longer listed go")
    }

    /// The widget went empty after bighelp opened from it: at launch, before the computer answered,
    /// the app wrote "no bots" over the saved list and removed every face. A gateway whose bots the app
    /// doesn't know yet keeps its saved ones; a gateway no longer set up goes.
    @Test func botsNotKnownYetKeepTheSavedOnesAndTheirFaces() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bots-widget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let faces = folder.appending(path: "faces"), rosterURL = folder.appending(path: "roster.json")
        try FileManager.default.createDirectory(at: faces, withIntermediateDirectories: true)
        let home = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!.uuidString
        let removed = UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000009")!.uuidString
        try BighelpBotsWidgetRoster(gateways: [
            home: [.init(agentID: "nova", name: "Nova", faceKey: "nova", isShape: true)],
            removed: [.init(agentID: "old", name: "Old", faceKey: "old")],
        ], inUseHostID: home).save(to: rosterURL)
        try Data("nova".utf8).write(to: faces.appending(path: "nova.png"))
        try Data("old".utf8).write(to: faces.appending(path: "old.png"))

        // A launch before the computer answers: its agents aren't known, and All agents has no copy.
        let unknown = BighelpBotsWidgetFeed.plan(current: nil, primaryID: nil, pinnedIDs: [], picture: { _ in nil },
                                                 currentHostID: UUID(uuidString: home), fleet: nil)
        #expect(unknown.roster.gateways.isEmpty)
        BighelpBotsWidgetFeed.write(unknown, drawn: [:], keeping: [home, Self.studio.uuidString],
                                    faces: faces, roster: rosterURL)

        let roster = BighelpBotsWidgetRoster.load(from: rosterURL)
        #expect(roster.shown(onGateway: nil, picked: ["nova"]).map(\.agentID) == ["nova"])
        #expect(roster.bots(onGateway: home).first?.isShape == true)
        #expect(roster.bots(onGateway: removed).isEmpty, "A gateway no longer set up goes")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: faces.path)) == ["nova.png"])
    }

    @Test func tappingABotOpensItsChatOnTheChosenGateway() {
        let thurman = BighelpBotsWidgetRoster.Bot(agentID: "thurman", name: "Thurman")
        let chosen = BighelpBotsWidgetView(bots: [thurman], hostID: Self.studio.uuidString)
        #expect(BighelpIncomingURLRoute.parse(chosen.link(thurman)) == .agentChat(agentID: "thurman", hostID: Self.studio))
        let inUse = BighelpBotsWidgetView(bots: [thurman], hostID: nil)
        #expect(BighelpIncomingURLRoute.parse(inUse.link(thurman)) == .agentChat(agentID: "thurman", hostID: nil))
        #expect(BighelpWidgetSnapshot.widgetKinds.contains(BighelpWidgetSnapshot.botsWidgetKind),
                "The app reloads it when bots change")
    }

    /// Small, medium and large, light and dark, shapes and photos; saved for review when
    /// BIGHELP_WIDGET_RENDER_DIR is set.
    @Test func botsWidgetRendersEverySizeInBothModes() throws {
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        let faces = FileManager.default.temporaryDirectory.appending(path: "bots-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: faces, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: faces) }
        var bots: [BighelpBotsWidgetRoster.Bot] = []
        for (index, name) in ["Thurman", "Gordie", "Nova", "Dolly"].enumerated() {
            let key = "face\(index)"
            let png = index == 2 ? try photoPNG() : try #require(SimpleBotMarkView.png(.defaultMark(for: name), pixels: 180))
            try png.write(to: faces.appending(path: "\(key).png"))
            bots.append(.init(agentID: name.lowercased(), name: name, faceKey: key, isShape: index != 2))
        }
        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, .init(width: 170, height: 170)),
                                                          ("medium", .systemMedium, .init(width: 364, height: 170)),
                                                          ("large", .systemLarge, .init(width: 364, height: 382))]
        for scheme in [ColorScheme.light, .dark] {
            for (name, family, size) in families {
                for (state, list) in [("bots", bots), ("empty", [])] {
                    let colors = BighelpWidgetColors(snapshot: .preview, scheme: scheme, isFullColor: true)
                    let view = BighelpBotsWidgetView(bots: list, hostID: nil, familyOverride: family)
                        .environment(\.bighelpBotsWidgetFaces, faces)
                        .environment(\.bighelpWidgetColors, colors)
                        .foregroundStyle(colors.primary)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(colors.canvas)
                        .clipShape(.rect(cornerRadius: 22))
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage, "\(state) \(name) did not render")
                    #expect(image.size.width >= size.width)
                    if let out, let data = image.pngData() {
                        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        try data.write(to: out.appendingPathComponent(
                            "bots-\(state)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    /// A square picture with no clear corners, like a photo.
    private func photoPNG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 50, y: 40, width: 80, height: 80))
        }
        return try #require(image.pngData())
    }
}
