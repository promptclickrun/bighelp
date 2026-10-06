import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SkillsAndToolsCatalogView: View {
    let store: SkillsAndToolsStore
    let agentID: String

    @State private var isPresentingEditor = false
    @State private var isPresentingWizard = false
    @State private var isPresentingImporter = false
    @State private var selectedCapability: CapabilitySelection?

    var body: some View {
        ScrollView {
            SkillsAndToolsCatalogContent(
                store: store,
                onRetry: { Task { await store.load(agentID: agentID) } },
                onSkillSelected: { skillID in
                    Task {
                        guard await store.loadSkill(id: skillID, agentID: agentID) != nil else {
                            return
                        }
                        isPresentingEditor = true
                    }
                },
                onCapabilitySelected: { kind, id, title in
                    selectedCapability = CapabilitySelection(agentID: agentID, kind: kind, itemID: id, title: title)
                }
            )
            .padding(.horizontal, BighelpTokens.space20)
            .padding(.vertical, BighelpTokens.space16)
        }
        .scrollIndicators(.hidden)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .navigationTitle("Skills & Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Create with wizard", systemImage: "wand.and.stars") {
                        guard store.catalog?.management?.canCreate == true else {
                            store.reportError(HermesCapabilityCompatibilityError.updateRequired.localizedDescription)
                            return
                        }
                        isPresentingWizard = true
                    }
                    Button("Import SKILL.md or ZIP", systemImage: "square.and.arrow.down") {
                        guard store.catalog?.management?.canImport == true else {
                            store.reportError(HermesCapabilityCompatibilityError.updateRequired.localizedDescription)
                            return
                        }
                        isPresentingImporter = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create or import skill")
                .accessibilityIdentifier("skills-tools.add")
            }
        }
        .bighelpSheet(isPresented: $isPresentingEditor, onDismiss: store.clearDocument) {
            if let document = store.document {
                SkillEditorSheet(store: store, agentID: agentID, document: document)
                    .bighelpSheetSize(.standard)
            }
        }
        .bighelpSheet(isPresented: $isPresentingWizard) {
            SkillCreationWizard(store: store, agentID: agentID)
                .bighelpSheetSize(.standard)
        }
        .bighelpSheet(item: $selectedCapability, onDismiss: store.clearControl) { selection in
            CapabilityControlSheet(store: store, selection: selection)
                .bighelpSheetSize(.standard)
        }
        .onChange(of: store.catalog?.agentID) { _, selectedAgent in
            if selectedAgent != agentID {
                isPresentingEditor = false
                isPresentingWizard = false
                isPresentingImporter = false
                selectedCapability = nil
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [.plainText, .zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    store.reportError("No skill file was selected.")
                    return
                }
                Task { await importSkill(from: url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    store.reportError("The file picker could not open this skill. Try selecting it again.")
                }
            }
        }
        .task(id: agentID) { await store.load(agentID: agentID) }
        .alert("Skills & Tools", isPresented: Binding(
            get: { store.errorMessage != nil && !isPresentingEditor && !isPresentingWizard
                && !isPresentingImporter && selectedCapability == nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("OK") { store.clearError() }
        } message: {
            Text(store.errorMessage ?? "The host could not complete this action.")
        }
        .accessibilityIdentifier("skills-tools.screen")
    }

    private func importSkill(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_500_001) ?? Data()
            guard !data.isEmpty, data.count <= 1_500_000 else {
                store.reportError("Choose a nonempty SKILL.md or ZIP no larger than 1.5 MB.")
                return
            }
            let kind = url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame
                ? "zip"
                : "skillMd"
            if await store.importSkill(data: data, kind: kind, agentID: agentID) != nil {
                isPresentingEditor = true
            }
        } catch {
            store.reportError("The selected skill file could not be read.")
        }
    }

    @BighelpThemeReader private var theme: BighelpTheme

}
