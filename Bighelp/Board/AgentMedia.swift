import ImageIO
import Observation
import SwiftUI
import UIKit

/// A picture or video the agent sent in chat or generated.
struct AgentMediaItem: Identifiable, Equatable, Sendable {
    let id: String
    let fileName: String
    let mimeType: String
    let byteCount: Int
    let createdAt: Date?

    var isVideo: Bool { mimeType.hasPrefix("video/") }
}

@MainActor
protocol AgentMediaClient: AnyObject {
    func recent(agentID: String) async throws -> [AgentMediaItem]
    func data(agentID: String, item: AgentMediaItem) async throws -> Data
}

/// The plugin's `attachments/recent` (2.15+): opaque attachment IDs that go
/// through the host's delivery policy, fetched in chunks like chat attachments.
@MainActor
final class DirectHermesAgentMediaClient: AgentMediaClient {
    static let limit = 36
    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner) {
        self.workspace = workspace
        self.owner = owner
    }

    private func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws
        -> [String: BighelpJSONValue] {
        guard workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        return try await workspace.perform(operation, payload: payload, owner: owner)
    }

    func recent(agentID: String) async throws -> [AgentMediaItem] {
        let result = try await perform(.attachmentsRecent, ["agentId": .string(agentID), "limit": .integer(Self.limit)])
        guard let rows = result["items"]?.array, rows.count <= Self.limit else { throw WorkspaceClientError.invalidResponse }
        return try rows.map { value in
            guard let row = value.object, let id = row["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
                  let name = row["fileName"]?.string, !name.isEmpty,
                  let mime = row["mimeType"]?.string?.lowercased(),
                  mime.hasPrefix("image/") || mime.hasPrefix("video/"),
                  let size = row["byteCount"]?.integer, (1...ChatAttachment.maximumAgentBytes).contains(size) else {
                throw WorkspaceClientError.invalidResponse
            }
            let created = row["createdAt"]?.number.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return AgentMediaItem(id: id, fileName: name, mimeType: mime, byteCount: size, createdAt: created)
        }
    }

    func data(agentID: String, item: AgentMediaItem) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await perform(.attachmentsFetch, [
                "agentId": .string(agentID), "attachmentId": .string(item.id), "offset": .integer(offset),
            ])
            guard chunk["attachmentId"]?.string == item.id, chunk["offset"]?.integer == offset,
                  chunk["byteCount"]?.integer == item.byteCount, let encoded = chunk["data"]?.string,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                  data.count + bytes.count <= item.byteCount else { throw WorkspaceClientError.invalidResponse }
            data.append(bytes)
            offset = data.count
            if chunk["nextOffset"] == nil || chunk["nextOffset"] == .null {
                guard data.count == item.byteCount else { throw WorkspaceClientError.invalidResponse }
                return data
            }
            guard chunk["nextOffset"]?.integer == offset else { throw WorkspaceClientError.invalidResponse }
        }
    }
}

/// The Apps tab's Media: what the agent sent or made, newest first. Pictures
/// load small thumbnails as they scroll into view; videos load when opened.
@MainActor
@Observable
final class AgentMediaStore {
    enum State: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    private(set) var items: [AgentMediaItem] = []
    private(set) var state: State = .idle
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var openingID: String?

    @ObservationIgnored private var client: (any AgentMediaClient)?
    @ObservationIgnored private var agentID: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingThumbnails: Set<String> = []

    func configure(client: (any AgentMediaClient)?) {
        guard client !== self.client else { return }
        self.client = client
        generation &+= 1
        items = []; thumbnails = [:]; pendingThumbnails = []; agentID = nil; openingID = nil
        state = client == nil ? .unavailable : .idle
    }

    func load(agentID: String) async {
        guard let client else { state = .unavailable; return }
        let generation = generation
        if self.agentID != agentID {
            self.agentID = agentID
            items = []; thumbnails = [:]; pendingThumbnails = []
        }
        state = .loading
        do {
            let loaded = try await client.recent(agentID: agentID)
            guard generation == self.generation, self.agentID == agentID else { return }
            items = loaded
            state = .loaded
        } catch WorkspaceClientError.unavailable {
            guard generation == self.generation else { return }
            state = .unavailable
        } catch is CancellationError {
        } catch {
            guard generation == self.generation, self.agentID == agentID else { return }
            state = .failed((error as? WorkspaceClientError)?.localizedDescription ?? "Couldn't load media right now.")
        }
    }

    /// A small copy of a picture for the grid.
    func loadThumbnail(for item: AgentMediaItem) async {
        guard !item.isVideo, thumbnails[item.id] == nil, pendingThumbnails.insert(item.id).inserted,
              let client, let agentID else { return }
        let generation = generation
        defer { pendingThumbnails.remove(item.id) }
        guard let data = try? await client.data(agentID: agentID, item: item),
              generation == self.generation, let image = Self.thumbnail(data, side: 360) else { return }
        thumbnails[item.id] = image
    }

    /// The full file, ready for the native preview.
    func attachment(for item: AgentMediaItem) async -> ChatAttachment? {
        guard let client, let agentID, openingID == nil else { return nil }
        openingID = item.id
        defer { openingID = nil }
        guard let data = try? await client.data(agentID: agentID, item: item) else { return nil }
        return try? DirectHermesGeneratedMediaClient.nativeAttachment(
            id: item.id, fileName: item.fileName, mimeType: item.mimeType, data: data)
    }

    static func thumbnail(_ data: Data, side: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// One square in the Media grid.
struct AgentMediaTile: View {
    let item: AgentMediaItem
    let store: AgentMediaStore
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = store.thumbnails[item.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if item.isVideo {
                        ZStack {
                            LinearGradient(colors: [theme.action.opacity(0.35), theme.action.opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(item.fileName)
                                .font(.bighelp(.caption2).weight(.medium))
                                .foregroundStyle(theme.primaryText)
                                .lineLimit(3)
                                .multilineTextAlignment(.center)
                                .padding(8)
                        }
                    } else {
                        // The picture is on the host; its small copy is on the way.
                        Rectangle().fill(BighelpSkeletonPalette.block(in: theme))
                            .bighelpSkeleton(isLoading: true, accessibilityLabel: "Loading picture")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.bighelp(.caption).weight(.bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(6)
                    }
                }
                .overlay {
                    if store.openingID == item.id {
                        BighelpSpinner(size: 18, color: .white)
                            .padding(10)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
                .clipped()
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .task(id: item.id) { await store.loadThumbnail(for: item) }
        .accessibilityLabel("\(item.isVideo ? "Video" : "Picture"): \(item.fileName)")
        .accessibilityIdentifier("board.media.item")
    }

    @BighelpThemeReader private var theme
}
