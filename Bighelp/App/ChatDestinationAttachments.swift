import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Attachment work remains bound to the existing conversation and view state.
extension ChatDestinationView {
    func attachmentPickerPresentation(_ binding: Binding<Bool>, onMac: Bool) -> Binding<Bool> {
        BighelpPlatform.isMac == onMac ? binding : .constant(false)
    }

    private func presentAttachmentPicker(_ binding: Binding<Bool>) {
        #if targetEnvironment(macCatalyst)
        attachmentFlow.isActionMenuPresented = false
        Task { @MainActor in
            // Finish the popover dismissal before asking UIKit for its panel.
            try? await Task.sleep(for: .milliseconds(200))
            binding.wrappedValue = true
        }
        #else
        binding.wrappedValue = true
        #endif
    }

    func performChatAction(_ action: ChatActionMenuAction) {
        switch action {
            case .camera:
                guard ChatCameraPicker.isAvailable else {
                    attachmentRecoveryKind = nil
                    attachmentErrorMessage = "Camera capture is unavailable on this device."
                    return
                }
                Task {
                    guard await permissionCenter.authorizeContextualAccess(.camera) else {
                        attachmentRecoveryKind = .camera
                        attachmentErrorMessage = "Camera access is unavailable. You can change it in iOS Settings."
                        return
                    }
                    reflectiveVisionCamera?.suspend()
                    isCameraPickerPresented = true
                }
            case .scanDocument:
                guard ChatDocumentScanner.isSupported, model.supportedAttachmentKinds.contains(.file),
                      model.draftAttachments.count < 10 else {
                    attachmentErrorMessage = "Document scanning requires a supported camera and space for a PDF attachment."
                    return
                }
                let members = model.memberIDs
                Task { @MainActor in
                    guard await permissionCenter.authorizeContextualAccess(.camera) else {
                        attachmentRecoveryKind = .camera
                        attachmentErrorMessage = "Camera access is unavailable. You can change it in iOS Settings."
                        return
                    }
                    guard appState.activeConversationID == model.conversationID,
                          model.memberIDs == members else { return }
                    documentScanMembers = members
                    documentScanResult = nil
                    reflectiveVisionCamera?.suspend()
                    isDocumentScannerPresented = true
                }
            case .photo:
                presentAttachmentPicker($isPhotoPickerPresented)
            case .file:
                presentAttachmentPicker($isFilePickerPresented)
            case .voice:
                attachmentFlow.isActionMenuPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    voicePresentation = featureStore.makeVoicePresentation(
                        for: model.conversationID,
                        mode: settings.voiceMode,
                        transcription: settings.voiceTranscription,
                        conversationMode: settings.voiceConversationMode,
                        liveProvider: settings.liveVoiceProvider,
                        liveVoice: settings.liveVoice(for: settings.liveVoiceProvider)
                    )
                }
            case .startSession:
                attachmentFlow.isActionMenuPresented = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    onStartSession()
                }
            case .chooseAgent, .skillsAndTools, .changeModel, .workspace:
                // These actions are owned by nested pages inside the drawer.
                break
            }
    }

    func finishDocumentScan() {
        defer {
            documentScanResult = nil
            Task { await reflectiveVisionCamera?.update(enabled: reflectiveVisionEnabled) }
        }
        guard let result = documentScanResult,
              appState.activeConversationID == model.conversationID,
              model.memberIDs == documentScanMembers else { return }
        do {
            try model.addDraftAttachment(result.get())
            attachmentFlow.completeSuccessfulImport()
        } catch is CancellationError {
            return
        } catch {
            attachmentErrorMessage = (error as? ChatScannedDocument.ScanError)?.localizedDescription
                ?? attachmentErrorDescription(error)
        }
    }

    func importCameraImage(_ image: UIImage) {
        do {
            guard let data = image.jpegData(compressionQuality: 1) else {
                throw ChatAttachmentError.invalidSize
            }
            let attachment = try ChatAttachmentPreparer().prepare(
                id: Self.attachmentID(),
                fileName: "camera-\(UUID().uuidString.lowercased()).jpg",
                mimeType: "image/jpeg",
                data: data
            )
            try model.addDraftAttachment(attachment)
            attachmentFlow.completeSuccessfulImport()
        } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
        }
    }

    func attachReference(to summary: SessionSummary) async {
        do {
            let record = try await catalog.hydrateSession(id: summary.id)
            let body = try ChatReferenceDocumentBuilder.markdown(for: record)
            let attachment = try ChatAttachment(
                id: Self.attachmentID(),
                fileName: ChatReferenceDocumentBuilder.fileName(for: record),
                mimeType: "text/markdown",
                data: Data(body.utf8)
            )
            try model.addDraftAttachment(attachment)
            attachmentFlow.completeSuccessfulImport()
        } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
        }
    }

    /// Photos come in one at a time; the tag above the message box shows "Adding 2 of 4…"
    /// and keeps any that didn't attach, with Try again.
    func importPhotos(_ selections: [PhotosPickerItem]) async {
        defer { photoSelections = [] }
        guard !selections.isEmpty else { return }
        attachmentFlow.completeSuccessfulImport()
        await model.importDraftAttachments(.photos, selections.map { selection in
            DraftAttachmentLoader(name: nil) {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw ChatAttachmentError.invalidSize
                }
                let type = selection.supportedContentTypes.first ?? .jpeg
                let extensionValue = type.preferredFilenameExtension ?? "jpg"
                return try ChatAttachmentPreparer().prepare(
                    id: Self.attachmentID(),
                    fileName: "image-\(UUID().uuidString.lowercased()).\(extensionValue)",
                    mimeType: type.preferredMIMEType ?? "image/jpeg",
                    data: data
                )
            }
        })
    }

    func importFiles(_ result: Result<[URL], any Error>) {
        let urls: [URL]
        do { urls = try result.get() } catch {
            attachmentErrorMessage = attachmentErrorDescription(error)
            return
        }
        guard !urls.isEmpty else { return }
        attachmentFlow.completeSuccessfulImport()
        let kind: DraftAttachmentImportKind = urls.allSatisfy {
            (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) == true
        } ? .photos : .files
        Task { @MainActor in
            await model.importDraftAttachments(kind, urls.map { url in
                DraftAttachmentLoader(name: url.lastPathComponent) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                        ?? UTType(filenameExtension: url.pathExtension)
                        ?? .data
                    return try ChatAttachmentPreparer().prepare(
                        id: Self.attachmentID(),
                        fileName: url.lastPathComponent,
                        mimeType: type.preferredMIMEType ?? "application/octet-stream",
                        data: data
                    )
                }
            })
        }
    }

    func attachmentErrorDescription(_ error: any Error) -> String {
        ChatAttachmentError.userMessage(for: error)
    }

    static func attachmentID() -> String {
        "attachment_\(UUID().uuidString.lowercased())"
    }

}
