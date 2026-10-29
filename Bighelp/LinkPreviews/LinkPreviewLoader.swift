import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum LinkPreviewError: Error { case unavailable }

/// Loads a page's preview and its picture. Pages are read only up to the end
/// of their head, pictures are shrunk to card size, and nothing sends cookies.
struct LinkPreviewLoader: Sendable {
    /// Loads a request, reading at most `maximumBytes`; `stopsAfterHead` ends a
    /// page once its head has arrived.
    typealias Fetch = @Sendable (_ request: URLRequest, _ maximumBytes: Int, _ stopsAfterHead: Bool)
        async throws -> (Data, HTTPURLResponse)

    struct Loaded: Sendable {
        var preview: LinkPreview
        /// The card-size picture (JPEG, or PNG when it has see-through parts).
        var imageData: Data?
    }

    static let maximumPageBytes = 1_048_576
    static let maximumPictureBytes = 8_388_608
    static let picturePixels = 1_200
    /// Smaller pictures are site icons, not previews.
    static let minimumPicturePixels = 80

    let fetch: Fetch

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func load(_ url: URL) async throws -> Loaded {
        guard let url = LinkPreviewPolicy.loadableURL(url) else { throw LinkPreviewError.unavailable }
        if let video = YouTubeVideo(url: url) { return await youTube(video) }
        let (data, response) = try await fetch(
            Self.request(url, accept: "text/html,application/xhtml+xml;q=0.9,image/*;q=0.8,*/*;q=0.5"),
            Self.maximumPageBytes, true)
        guard (200..<300).contains(response.statusCode) else { throw LinkPreviewError.unavailable }
        let page = response.url.flatMap(LinkPreviewPolicy.loadableURL) ?? url
        let type = response.mimeType?.lowercased() ?? ""

        if type.hasPrefix("image/") {
            // A link straight to a picture: use what was read, unless it was cut off at the limit.
            let picture: (data: Data, aspect: Double)
            if data.count < Self.maximumPageBytes {
                picture = try Self.cardPicture(data)
            } else {
                picture = try await self.picture(page)
            }
            return Loaded(preview: LinkPreview(url: page, imageURL: page, imageAspect: picture.aspect),
                          imageData: picture.data)
        }
        guard type == "text/html" || type == "application/xhtml+xml" else { throw LinkPreviewError.unavailable }
        guard var preview = LinkPreviewParser.preview(html: Self.text(data, encoding: response.textEncodingName),
                                                      pageURL: page) else { throw LinkPreviewError.unavailable }
        var imageData: Data?
        if let imageURL = preview.imageURL, let picture = try? await picture(imageURL) {
            preview.imageAspect = picture.aspect
            imageData = picture.data
        } else {
            preview.imageURL = nil
        }
        return Loaded(preview: preview, imageData: imageData)
    }

    /// YouTube's own oEmbed answer has the video's real title and channel; its
    /// page gives crawlers only generic text. Without an answer (a private or
    /// removed video) the card is a plain, still playable "YouTube video". The
    /// picture is YouTube's 16:9 one when made.
    private func youTube(_ video: YouTubeVideo) async -> Loaded {
        var preview = LinkPreview(url: video.watchURL, siteName: "YouTube")
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: video.watchURL.absoluteString),
                                 URLQueryItem(name: "format", value: "json")]
        if let (data, response) = try? await fetch(Self.request(components.url!, accept: "application/json"), 65_536, false),
           (200..<300).contains(response.statusCode),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            preview.title = LinkPreviewParser.clean(object["title"] as? String, limit: LinkPreviewParser.maximumTitle)
            preview.summary = LinkPreviewParser.clean(object["author_name"] as? String, limit: LinkPreviewParser.maximumSummary)
        }
        var imageData: Data?
        for size in ["maxresdefault", "hqdefault"] {
            guard let picture = try? await picture(video.thumbnailURL(size)) else { continue }
            preview.imageURL = video.thumbnailURL(size)
            preview.imageAspect = picture.aspect
            imageData = picture.data
            break
        }
        return Loaded(preview: preview, imageData: imageData)
    }

    private func picture(_ url: URL) async throws -> (data: Data, aspect: Double) {
        guard let url = LinkPreviewPolicy.loadableURL(url) else { throw LinkPreviewError.unavailable }
        let (data, response) = try await fetch(Self.request(url, accept: "image/*"), Self.maximumPictureBytes, false)
        // A picture cut off at the limit would draw half-empty.
        guard (200..<300).contains(response.statusCode), data.count < Self.maximumPictureBytes else {
            throw LinkPreviewError.unavailable
        }
        return try Self.cardPicture(data)
    }

    static func cardPicture(_ data: Data) throws -> (data: Data, aspect: Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: picturePixels,
              ] as CFDictionary),
              min(image.width, image.height) >= minimumPicturePixels else { throw LinkPreviewError.unavailable }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw LinkPreviewError.unavailable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LinkPreviewError.unavailable }
        return (output as Data, Double(image.width) / Double(image.height))
    }

    static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        // Sites give their full preview tags to link-preview crawlers, like the one Messages uses.
        // A phone browser gets sent to mobile pages that often have generic tags.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15 facebookexternalhit/1.1 "
            + "Facebot Twitterbot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        return request
    }

    /// The page's text in its own encoding (the header's, else its meta charset).
    static func text(_ data: Data, encoding name: String?) -> String {
        if let name = name ?? metaCharset(data) {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(
                   rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        // A page cut off mid-character still reads, minus that character.
        return String(decoding: data, as: UTF8.self)
    }

    private static func metaCharset(_ data: Data) -> String? {
        let start = String(decoding: data.prefix(4_096), as: UTF8.self)
        guard let range = start.range(of: #"charset\s*=\s*["']?[A-Za-z0-9_.:-]+"#,
                                      options: [.regularExpression, .caseInsensitive]) else { return nil }
        return start[range].split(whereSeparator: { "=\"' ".contains($0) }).last.map(String.init)
    }
}

extension LinkPreviewLoader {
    static let live = LinkPreviewLoader { request, maximumBytes, stopsAfterHead in
        let (bytes, response) = try await session.bytes(for: request, delegate: LinkPreviewRedirectGuard())
        guard let response = response as? HTTPURLResponse else { throw LinkPreviewError.unavailable }
        guard (200..<300).contains(response.statusCode) else { return (Data(), response) }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 65_536))
        var searched = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maximumBytes { break }
            if stopsAfterHead, data.count - searched >= 4_096 {
                let window = max(0, searched - 8)..<data.count
                if data.range(of: Data("</head".utf8), in: window) != nil
                    || data.range(of: Data("</HEAD".utf8), in: window) != nil { break }
                searched = data.count
            }
        }
        return (data, response)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    #if DEBUG
    /// Demo runs: a made-up preview for any link, without the network.
    static let fixture = LinkPreviewLoader { request, _, _ in
        guard let url = request.url else { throw LinkPreviewError.unavailable }
        let host = LinkPreview.host(of: url)
        if url.path == "/oembed" {
            let json = #"{"title":"A demo video","author_name":"Demo Channel","provider_name":"YouTube"}"#
            return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Type": "application/json"])!)
        }
        if url.path.hasPrefix("/bighelp-demo-banner/") {
            return (demoBanner(named: url.lastPathComponent), HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        }
        if url.path == "/bighelp-demo-preview.png" || url.host() == "i.ytimg.com" {
            let picture = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 630), format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return format
            }()).pngData { context in
                let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
                    context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1200, y: 630), options: [])
                }
            }
            return (picture, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "image/png"])!)
        }
        let html = """
        <head><meta property="og:title" content="A story from \(host)">
        <meta property="og:description" content="A made-up preview for demo mode. The page's own summary shows here.">
        <meta property="og:site_name" content="Example News">
        <meta property="og:image" content="/bighelp-demo-preview.png"></head>
        """
        return (Data(html.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
    }

    /// A made-up 2:1 banner for the demo plugin catalog: a dusk gradient and two hills, colored by name.
    private static func demoBanner(named name: String) -> Data {
        let palettes: [(UInt32, UInt32, UInt32)] = [
            (0x2A3A5C, 0x5470B0, 0x1E2B46), (0x3B2A22, 0xE87D3E, 0x5C4334),
            (0x1F3D34, 0x7CC79A, 0x16302A), (0x3A2350, 0xB58CF0, 0x2A1A3C),
        ]
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let (back, glow, ground) = palettes[Int(hash % UInt32(palettes.count))]
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let size = CGSize(width: 1200, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            color(back).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            color(glow).withAlphaComponent(0.55).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 760 - CGFloat(hash % 300), y: -120, width: 560, height: 560))
            color(glow).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 560, y: 260, width: 300, height: 300))
            color(ground).setFill()
            let hill = UIBezierPath()
            hill.move(to: CGPoint(x: 0, y: 520))
            hill.addCurve(to: CGPoint(x: 1200, y: 420), controlPoint1: CGPoint(x: 300, y: 380),
                          controlPoint2: CGPoint(x: 700, y: 620))
            hill.addLine(to: CGPoint(x: 1200, y: 600))
            hill.addLine(to: CGPoint(x: 0, y: 600))
            hill.close()
            hill.fill()
        }
    }
    #endif
}

/// Redirects stay on public web pages, over HTTPS.
private final class LinkPreviewRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, let allowed = LinkPreviewPolicy.loadableURL(url) else { return nil }
        var redirected = request
        redirected.url = allowed
        return redirected
    }
}
