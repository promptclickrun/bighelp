import Foundation
import Testing

/// On the Mac, Catalyst sometimes leaves a sheet on screen after SwiftUI closes
/// it: Done runs, the state says closed, and the sheet stays and blocks the
/// window. `bighelpSheet` and `bighelpFullScreenCover` close it through UIKit
/// then, so every presentation in the app must use them.
struct MacSheetPresentationTests {
    @Test func everySheetAndCoverUsesTheMacSafePresentation() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = repository.appending(path: "Bighelp")
        let pattern = try Regex(#"(?<![A-Za-z0-9_])\.(sheet|fullScreenCover)\((\s*$|isPresented:|item:)"#)
            .anchorsMatchLineEndings()
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "BighelpSheetSize.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(pattern) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Use .bighelpSheet / .bighelpFullScreenCover in: \(offenders.sorted())")
    }

    @Test func theMacSafePresentationClosesThroughUIKit() throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appending(path: "Bighelp/DesignSystem/BighelpSheetSize.swift"),
                                encoding: .utf8)
        #expect(source.contains("BighelpMacSheetCloser"))
        #expect(source.contains("sheet.dismiss(animated: true)"))
    }
}
