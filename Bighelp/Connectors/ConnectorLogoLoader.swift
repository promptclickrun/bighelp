import Foundation
import ImageIO

/// Fetches and draws app logos for Native App Connections and Composio Apps. The catalogs link
/// SVGs, which `AsyncImage` can't show; this draws them (`ConnectorLogoSVG`) and keeps the result.
/// Requests carry no cookies, follow only HTTPS and stop at `ConnectorLogoSVG.maximumBytes`.
@MainActor
final class ConnectorLogoLoader {
    static let shared = ConnectorLogoLoader()
    /// Drawn once at this size; a row shows it at 36 or 48 points.
    nonisolated static let pixels = 192

    /// A drawn logo. `isDarkInk`: dark marks on a clear background, which vanish on a dark page.
    struct Logo: @unchecked Sendable {
        let image: CGImage
        let isDarkInk: Bool
    }

    private var images: [URL: Logo] = [:]
    private var order: [URL] = []
    private var failed: Set<URL> = []
    private var loads: [URL: Task<Logo?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        // The logo service marks its files immutable for days; keep them across launches.
        configuration.urlCache = URLCache(memoryCapacity: 2_000_000, diskCapacity: 20_000_000,
                                          directory: URL.cachesDirectory.appending(path: "ConnectorLogos", directoryHint: .isDirectory))
        session = URLSession(configuration: configuration)
    }

    func cached(_ url: URL) -> Logo? { images[url] }

    func logo(for url: URL) async -> Logo? {
        if let logo = images[url] { return logo }
        guard !failed.contains(url), url.scheme == "https", url.host != nil else { return nil }
        if let load = loads[url] { return await load.value }
        let session = session
        let load = Task.detached(priority: .utility) { () -> Logo? in
            guard let data = await Self.fetch(url, session: session), let image = Self.draw(data) else { return nil }
            return Logo(image: image, isDarkInk: Self.isDarkInk(image))
        }
        loads[url] = load
        let logo = await load.value
        loads[url] = nil
        guard let logo else { failed.insert(url); return nil }
        images[url] = logo
        order.append(url)
        if order.count > 300 { images[order.removeFirst()] = nil }
        return logo
    }

    /// Mostly clear, and what's painted is nearly black (a black wordmark or glyph).
    nonisolated static func isDarkInk(_ image: CGImage) -> Bool {
        let side = 32
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var clear = 0, painted = 0, light = 0.0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[index + 3])
            guard alpha > 40 else { clear += 1; continue }
            painted += 1
            let red = Double(bytes[index]), green = Double(bytes[index + 1]), blue = Double(bytes[index + 2])
            light += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / alpha
        }
        guard painted > 0 else { return false }
        return Double(clear) / Double(side * side) > 0.25 && light / Double(painted) < 0.2
    }

    nonisolated static func draw(_ data: Data) -> CGImage? {
        let head = data.prefix(512)
        if let text = String(data: head, encoding: .utf8), text.contains("<svg") || text.hasPrefix("<?xml") {
            return ConnectorLogoSVG.render(data, pixels: pixels)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("image/svg+xml, image/png, image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
              http.expectedContentLength <= ConnectorLogoSVG.maximumBytes else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > ConnectorLogoSVG.maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}
