import SwiftUI
import Observation
import Testing
import UIKit
@testable import Bighelp

@Suite(.serialized) @MainActor
struct ReferenceNativeEditorAcceptanceTests {
    @Test func surfaceTransferDoesNotRemoveAResponderInsideTheRepresentableUpdate() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let oldContainer = try #require(view.superview as? ReferenceComposerContainer)
        let coordinator = try #require(view.delegate as? ReferenceComposerTextView.Coordinator)
        let caret = view.selectedRange
        let source = Data(view.text.utf8)
        let undo = view.undoManager
        #expect(view.isFirstResponder)
        let destination = ReferenceComposerContainer(frame: CGRect(x: 20, y: 100, width: 360, height: 360))
        destination.coordinator = coordinator
        mounted.window.rootViewController?.view.addSubview(destination)
        let expanded = ReferenceComposerTextView(
            text: Binding(get: { fixture.source }, set: { fixture.source = $0 }),
            hub: fixture.hub, session: fixture.session,
            focus: Binding(get: { fixture.focusRequested }, set: { fixture.focusRequested = $0 }),
            isEnabled: true, expanded: true
        )

        fixture.surfaceActive = false
        coordinator.updateSurface(expanded, in: destination)

        #expect(view.superview === oldContainer, "Moving a responder during SwiftUI update can reenter keyboard layout and deadlock AttributeGraph.")
        #expect(view.isFirstResponder)
        await settleWindowAttachment(destination)
        #expect(view.superview === destination)
        #expect(view.selectedRange == caret)
        #expect(Data(view.text.utf8) == source)
        #expect(view.undoManager === undo)
        #expect(view.isFirstResponder)
        ReferenceComposerTextView.dismantleUIView(destination, coordinator: coordinator)
    }

    @Test(arguments: [false, true])
    func queuedSurfaceHandoffIgnoresRetiredAndSupersededDestinations(retireLatest: Bool) async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let original = try #require(view.superview as? ReferenceComposerContainer)
        let coordinator = try #require(view.delegate as? ReferenceComposerTextView.Coordinator)
        let source = Data(fixture.source.utf8)
        let first = ReferenceComposerContainer(frame: CGRect(x: 20, y: 100, width: 360, height: 360))
        let latest = ReferenceComposerContainer(frame: CGRect(x: 20, y: 100, width: 360, height: 360))
        for destination in [first, latest] {
            destination.coordinator = coordinator
            mounted.window.rootViewController?.view.addSubview(destination)
        }
        let expanded = ReferenceComposerTextView(
            text: Binding(get: { fixture.source }, set: { fixture.source = $0 }),
            hub: fixture.hub, session: fixture.session,
            focus: Binding(get: { fixture.focusRequested }, set: { fixture.focusRequested = $0 }),
            isEnabled: true, expanded: true
        )
        fixture.surfaceActive = false
        coordinator.updateSurface(expanded, in: first)
        coordinator.updateSurface(expanded, in: latest)
        ReferenceComposerTextView.dismantleUIView(first, coordinator: coordinator)
        if retireLatest { ReferenceComposerTextView.dismantleUIView(latest, coordinator: coordinator) }
        #expect(view.superview === original)
        await settleWindowAttachment(mounted.window)
        #expect(view.superview !== first)
        #expect(Data(fixture.source.utf8) == source)
        if retireLatest {
            #expect(view.superview !== latest)
            #expect(!coordinator.isSurfaceActive)
        } else {
            #expect(view.superview === latest)
            #expect(view.isFirstResponder)
        }
        ReferenceComposerTextView.dismantleUIView(latest, coordinator: coordinator)
    }

    @Test func nativeComposerUsesSystemFontAcrossThemeChanges() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let selection = view.selectedRange
        let source = view.text
        let undo = view.undoManager
        let bighelp = BighelpTheme.resolve(
            appearance: .system,
            colorScheme: .light,
            contrast: .standard
        )
        #expect(view.font?.fontName == bighelp.uiFont(.body, compatibleWith: view.traitCollection).fontName)

        fixture.bubbleColor = .ocean
        await mounted.settle()
        let ocean = BighelpTheme.resolve(
            appearance: BighelpAppearanceContext(appearance: .system, bubbleColor: .ocean),
            colorScheme: .light,
            contrast: .standard
        )
        #expect(view.font?.fontName == ocean.uiFont(.body, compatibleWith: view.traitCollection).fontName)
        #expect(view === mounted.textView())
        #expect(view.selectedRange == selection)
        #expect(view.text == source)
        #expect(view.undoManager === undo)

        fixture.bubbleColor = nil
        fixture.expanded = true
        await mounted.settle()
        #expect(view.font?.fontName == bighelp.uiFont(.body, compatibleWith: view.traitCollection).fontName)
        #expect(view === mounted.textView())
        #expect(view.selectedRange == selection)
        #expect(view.isFirstResponder)
    }

    @Test func wrappedDraftKeepsTheExpandButtonWhileTyping() async throws {
        let fixture = try EditorFixture()
        fixture.source += String(repeating: " and a few more words", count: 8)
        let reports = ExpansionReports()
        let mounted = try await MountedEditor(root: ComposerRowSurface(fixture: fixture, reports: reports))
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        for word in ["one", "two", "three", "four", "five"] {
            view.insertText(" " + word)
            await mounted.settle()
        }

        let typed = reports.values
        #expect(typed.last == true)
        #expect(typed.drop(while: { !$0 }).allSatisfy { $0 },
            "SwiftUI also measures at infinite width, where any draft fits one line; reporting that hides the button and the box shakes.")

        // The button still goes away once the draft fits one line again.
        view.selectedRange = NSRange(location: 0, length: view.text.utf16.count)
        view.insertText("Short")
        await mounted.settle()
        #expect(reports.values.last == false)

        view.selectedRange = NSRange(location: 0, length: view.text.utf16.count)
        view.deleteBackward()
        await mounted.settle()
        #expect(view.text.isEmpty)
        #expect(reports.values.last == false)
    }

    @Test func proseKeyboardTraitsReturnAfterLiteralSlashTokenWithoutReplacingNativeState() async throws {
        let fixture = try EditorFixture()
        fixture.source = "Please summarize "
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let manager = try #require(view.undoManager)
        #expect(view.autocorrectionType == .default)
        #expect(view.autocapitalizationType == .sentences)
        view.insertText("/note")
        view.delegate?.textViewDidChange?(view)
        #expect(view.autocorrectionType == .no)
        #expect(view.autocapitalizationType == .none)
        #expect(fixture.hub.insertCatalogToken(name: "note"))
        #expect(view.text == "Please summarize /note ")
        #expect(view.autocorrectionType == .default)
        #expect(view.autocapitalizationType == .sentences)
        let caret = view.selectedRange
        fixture.renderRevision += 1
        await mounted.settle()
        #expect(view.selectedRange == caret)
        #expect(view.undoManager === manager)
        #expect(view.isFirstResponder)
        #expect(!fixture.hub.isPresented)
        view.insertText("then explain")
        #expect(view.text == "Please summarize /note then explain")
    }

    @Test func editingReferenceSourceKeepsLiteralTraitsWithoutMovingSelection() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let source = Data(view.text.utf8)
        let anchor = (view.text as NSString).range(of: fixture.snapshot.anchor)
        let caret = NSRange(location: anchor.location + 2, length: 0)
        view.selectedRange = caret
        view.delegate?.textViewDidChangeSelection?(view)
        #expect(view.autocorrectionType == .no)
        #expect(view.autocapitalizationType == .none)
        #expect(view.spellCheckingType == .no)
        #expect(view.selectedRange == caret)
        #expect(Data(view.text.utf8) == source)
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        #expect(view.autocorrectionType == .default)
        #expect(view.autocapitalizationType == .sentences)
        #expect(fixture.hub.selected.map(\.snapshot) == [fixture.snapshot])
    }

    enum WindowAttachmentDisposition: CaseIterable, Equatable, Sendable {
        case requested, dismissed, deactivated, retired
    }

    @Test(arguments: WindowAttachmentDisposition.allCases)
    func delayedWindowAttachmentRespectsCurrentFocusAndSurfaceOwnership(
        disposition: WindowAttachmentDisposition
    ) async throws {
        let fixture = try EditorFixture()
        fixture.source = "/note"
        fixture.hub.resetDraft(source: fixture.source)
        let editor = ReferenceComposerTextView(
            text: Binding(get: { fixture.source }, set: { fixture.source = $0 }),
            hub: fixture.hub, session: fixture.session,
            focus: Binding(get: { fixture.focusRequested }, set: { fixture.focusRequested = $0 }),
            isEnabled: true, expanded: true
        )
        let coordinator = editor.makeCoordinator()
        let container = ReferenceComposerContainer(frame: CGRect(x: 0, y: 80, width: 300, height: 180))
        let view = ClipboardPasteTextView(frame: container.bounds)
        view.text = fixture.source
        let originalSelection = NSRange(location: fixture.source.utf16.count, length: 0)
        view.selectedRange = originalSelection
        view.delegate = coordinator
        container.coordinator = coordinator
        container.addSubview(view)
        coordinator.view = view
        coordinator.host = container
        coordinator.isSurfaceActive = true

        // Consume the initial focus request while genuinely outside a window.
        // Do not use MountedEditor: its manual becomeFirstResponder masks this path.
        coordinator.scheduleSynchronization(in: container)
        await settleWindowAttachment(container)
        #expect(view.window == nil)
        #expect(fixture.focusRequested)
        #expect(!view.isFirstResponder)
        #expect(!fixture.hub.isEditorActive)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            ReferenceComposerTextView.dismantleUIView(container, coordinator: coordinator)
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }

        switch disposition {
        case .requested: break
        case .dismissed: fixture.focusRequested = false
        case .deactivated: coordinator.scheduleDeactivation(in: container)
        case .retired: ReferenceComposerTextView.dismantleUIView(container, coordinator: coordinator)
        }
        // Attach before queued deactivation can execute, with no representable
        // update or direct responder call to repair a stale focus request.
        controller.view.addSubview(container)
        #expect(container.window === window)
        await settleWindowAttachment(window)

        let shouldFocus = disposition == .requested
        #expect(view.isFirstResponder == shouldFocus)
        #expect(fixture.hub.isEditorActive == shouldFocus)
        #expect(fixture.hub.isPresented == shouldFocus)
        if shouldFocus {
            #expect(view.window === window)
            #expect(fixture.hub.query?.query == "note")
            #expect(fixture.hub.selection == originalSelection)
        }
        #expect(view.selectedRange == originalSelection)
        #expect(view.text == "/note")
        #expect(fixture.source == "/note")
    }

    private func settleWindowAttachment(_ view: UIView) async {
        for _ in 0..<5 {
            view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    @Test func retiringNativeSurfaceRejectsEditsBeforeDeferredHubPublication() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let container = try #require(view.superview as? ReferenceComposerContainer)
        let coordinator = try #require(view.delegate as? ReferenceComposerTextView.Coordinator)
        let selection = try #require(fixture.hub.selected.first)
        let source = fixture.source
        #expect(fixture.hub.isEditorActive)
        let published = ReferenceAdapterLease()
        withObservationTracking { _ = fixture.hub.isEditorActive } onChange: { published.invalidate() }

        ReferenceComposerTextView.dismantleUIView(container, coordinator: coordinator)

        #expect(published.isValid, "Retirement must not publish from SwiftUI teardown")
        fixture.hub.remove(selection)
        #expect(Data(fixture.source.utf8) == Data(source.utf8))
        #expect(fixture.hub.selected == [selection])
        #expect(view.isFirstResponder, "SwiftUI teardown revokes ownership immediately but defers UIKit responder changes.")
        mounted.close()
        await mounted.settle()
        #expect(!view.isFirstResponder)
        #expect(!fixture.hub.isEditorActive)
    }

    @Test func consumedFocusRequestIsNotReplayedAfterNativeResponderLoss() async throws {
        let fixture = try EditorFixture()
        fixture.source = "/note"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        #expect(view.isFirstResponder)
        // Isolate the interval where UIKit lost its responder but the binding
        // still contains the already-consumed true request.
        let delegate = view.delegate
        view.delegate = nil
        #expect(view.resignFirstResponder())
        view.delegate = delegate
        #expect(fixture.focusRequested)
        for _ in 0..<3 {
            fixture.renderRevision += 1
            await mounted.settle()
            #expect(!view.isFirstResponder)
        }
        #expect(fixture.source == "/note")
        fixture.focusRequested = false
        await mounted.settle()
        fixture.focusRequested = true
        await mounted.settle()
        #expect(view.isFirstResponder)
        #expect(fixture.source == "/note")
    }

    @Test func explicitFocusDismissalStaysDismissedAcrossStreamingUpdates() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        #expect(view.isFirstResponder)
        fixture.focusRequested = false
        await mounted.settle()
        #expect(!view.isFirstResponder)
        for _ in 0..<5 {
            fixture.renderRevision += 1
            await mounted.settle()
            #expect(!view.isFirstResponder)
        }
    }

    @Test func disablingThenReenablingEditorClosesDiscoveryAndKeepsKeyboardDismissed() async throws {
        let fixture = try EditorFixture()
        fixture.source = "/note"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        #expect(view.isFirstResponder)
        #expect(fixture.hub.isPresented)

        fixture.isEnabled = false
        await mounted.settle()
        #expect(!view.isFirstResponder)
        #expect(!fixture.hub.isEditorActive)
        #expect(!fixture.hub.isPresented)
        #expect(!fixture.hub.isLoading)

        fixture.isEnabled = true
        await mounted.settle()
        #expect(view.isEditable)
        #expect(!view.isFirstResponder)
        #expect(!fixture.hub.isEditorActive)
        #expect(!fixture.hub.isPresented)
        #expect(fixture.source == "/note")
    }

    @Test func unrelatedViewUpdatesDoNotRepublishTheDraft() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let publications = fixture.publications
        let revision = fixture.hub.revision
        for _ in 0..<5 {
            fixture.renderRevision += 1
            await mounted.settle()
        }
        #expect(mounted.textView()?.isFirstResponder == true)
        #expect(fixture.publications == publications)
        #expect(fixture.hub.revision == revision)
    }

    @Test func retiringEditorWithReferencesOpenCancelsDiscovery() async throws {
        let fixture = try EditorFixture()
        fixture.source = "/note"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        view.selectedRange = NSRange(location: 5, length: 0)
        view.delegate?.textViewDidChange?(view)
        #expect(fixture.hub.isPresented)
        fixture.surfaceActive = false
        await mounted.settle()
        #expect(!view.isFirstResponder)
        #expect(!fixture.hub.isPresented)
        #expect(!fixture.hub.isLoading)
        #expect(fixture.source == "/note")
    }

    @Test(arguments: [false, true])
    func previewInsertionPreservesMiddleCaretAndRegistersOneNativeUndo(quickInsert: Bool) async throws {
        let fixture = try EditorFixture()
        fixture.source = "Before 👩‍💻 /note after e\u{0301}"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let range = (fixture.source as NSString).range(of: "/note")
        view.selectedRange = NSRange(location: range.location + range.length, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        for _ in 0..<20 where fixture.hub.results.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        let result = try #require(fixture.hub.results.first)
        let before = fixture.source
        let manager = try #require(view.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        if quickInsert {
            fixture.hub.select(result)
            for _ in 0..<20 where fixture.hub.isResolving { try await Task.sleep(for: .milliseconds(20)) }
        } else {
            fixture.hub.inspect(result)
            for _ in 0..<20 where fixture.hub.isResolving { try await Task.sleep(for: .milliseconds(20)) }
            #expect(fixture.source == before, "Inspect must not insert or send")
            #expect(fixture.hub.insert(try #require(fixture.hub.preview?.options.first)))
        }
        manager.endUndoGrouping()
        #expect(!fixture.hub.isPresented)
        #expect(fixture.hub.preview == nil)
        #expect(fixture.hub.frozenSubmission == nil)
        #expect(fixture.source == "Before 👩‍💻 " + fixture.snapshot.anchor + " after e\u{0301}")
        #expect(view.selectedRange.location == range.location + fixture.snapshot.anchor.utf16.count)
        #expect(view.isFirstResponder)
        #expect(fixture.hub.selected.map(\.snapshot) == [fixture.snapshot])
        manager.undo()
        #expect(Data(fixture.source.utf8) == Data(before.utf8))
        #expect(fixture.hub.selected.isEmpty)
        #expect(!manager.canUndo)
        manager.redo()
        #expect(fixture.hub.selected.map(\.snapshot) == [fixture.snapshot])
    }

    @Test(arguments: [false, true])
    func quickSelectionCannotInsertAfterCaretMovementOrIMEStarts(markedText: Bool) async throws {
        let fixture = try EditorFixture(resolveDelay: .milliseconds(150))
        fixture.source = "Before /note after"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        view.selectedRange = NSRange(location: 12, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        for _ in 0..<20 where fixture.hub.results.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        fixture.hub.select(try #require(fixture.hub.results.first))
        // Let the provider start, then invalidate the exact selection it owns.
        await Task.yield()
        if markedText {
            view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            view.delegate?.textViewDidChange?(view)
        } else {
            view.selectedRange = NSRange(location: 0, length: 0)
            view.delegate?.textViewDidChangeSelection?(view)
        }
        let source = Data(view.text.utf8)
        let caret = view.selectedRange
        try await Task.sleep(for: .milliseconds(200))
        #expect(Data(view.text.utf8) == source)
        #expect(view.selectedRange == caret)
        #expect(fixture.hub.selected.isEmpty)
        #expect(fixture.hub.preview == nil)
        #expect(view.isFirstResponder)
        #expect((view.markedTextRange != nil) == markedText)
    }

    @Test func delayedQuickSelectionCannotEditDuringDeferredSurfaceDeactivation() async throws {
        var retireBeforeReturning: @MainActor () -> Void = {}
        let fixture = try EditorFixture(resolveDelay: .milliseconds(50),
            beforeResolveReturn: { retireBeforeReturning() })
        fixture.source = "Before /note after"
        fixture.hub.resetDraft(source: fixture.source)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let container = try #require(view.superview as? ReferenceComposerContainer)
        let coordinator = try #require(view.delegate as? ReferenceComposerTextView.Coordinator)
        view.selectedRange = NSRange(location: 12, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        for _ in 0..<20 where fixture.hub.results.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        let source = fixture.source
        let caret = view.selectedRange
        let draftID = fixture.hub.draftID
        let revision = fixture.hub.revision
        let manager = try #require(view.undoManager)
        manager.removeAllActions()
        var retired = false
        retireBeforeReturning = {
            coordinator.scheduleDeactivation(in: container)
            retired = true
            // The async resolver now returns on this actor without another suspension;
            // quick insertion runs before the queued hub detach can revoke its lease.
            #expect(coordinator.host === container)
            #expect(fixture.hub.isEditorActive && fixture.hub.isResolving)
            #expect(!coordinator.isSurfaceActive)
        }
        fixture.hub.select(try #require(fixture.hub.results.first))
        for _ in 0..<20 where !retired || fixture.hub.isResolving {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(retired)
        #expect(fixture.source == source && view.text == source)
        #expect(view.selectedRange == caret)
        #expect(fixture.hub.draftID == draftID && fixture.hub.revision == revision)
        #expect(fixture.hub.selected.isEmpty)
        #expect(!manager.canUndo)
    }

    @Test func githubPublicationWaitsForWikiAndPreviewWithoutChangingNativeDraft() async throws {
        var fresh = false
        var wikiCompletion: CheckedContinuation<Void, Never>?
        var holdWiki = true
        var searches = 0
        var pendingResolve: CheckedContinuation<Void, Never>?
        var holdResolve = false
        let snapshot = try ReferenceSnapshot(kind: .repository,
            identity: .github(GitHubReferenceIdentity(repositoryID: "1",
                owner: "example", repository: "app")), title: "App",
            selectedContent: "Metadata", sourceRevision: "revision-a", fetchedAt: Date(timeIntervalSince1970: 1))
        let providers = [ReferenceHubProvider(id: "github", label: "GitHub", categories: [.repos],
            search: { _, _, _ in
                searches += 1
                return ReferenceHubSearchPage(results: [ReferenceHubResult(resourceID: "app", providerID: "github",
                    category: .repos, title: fresh ? "Fresh" : "Stale", subtitle: "example/app", state: nil, isCached: true)],
                    isPartial: false)
            }, resolve: { _, result in
                if holdResolve { await withCheckedContinuation { pendingResolve = $0 } }
                return ReferenceHubPreview(result: result, sourceKindLabel: "GitHub", options: [
                    ReferenceContentOption(id: "metadata", label: "Metadata", snapshot: snapshot)])
            }, revalidate: { _, snapshot in snapshot }),
            ReferenceHubProvider(id: "wiki", label: "Wiki", categories: [.wiki], search: { _, _, _ in
                if holdWiki {
                    holdWiki = false
                    await withCheckedContinuation { wikiCompletion = $0 }
                }
                return ReferenceHubSearchPage(results: [], isPartial: false)
            }, resolve: { _, _ in throw GitHubError.networkUnavailable }, revalidate: { _, snapshot in snapshot })]
        let fixture = try EditorFixture(providers: providers)
        fixture.source += " /app after"
        fixture.hub.resetDraft(source: fixture.source, selections: fixture.hub.selected)
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close(); wikiCompletion?.resume(); pendingResolve?.resume() }
        let view = try #require(mounted.textView())
        let range = (fixture.source as NSString).range(of: "/app after")
        view.selectedRange = NSRange(location: range.location + 4, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        for _ in 0..<30 where wikiCompletion == nil || fixture.hub.results.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.hub.results.first?.title == "Stale" && fixture.hub.isLoading)
        let source = fixture.source
        let caret = view.selectedRange
        let draftID = fixture.hub.draftID
        let revision = fixture.hub.revision
        let selections = fixture.hub.selected
        fresh = true
        fixture.discoveryRevision += 1
        await mounted.settle()
        #expect(fixture.hub.results.first?.title == "Stale")
        #expect(searches == 1)
        try #require(wikiCompletion).resume()
        wikiCompletion = nil
        for _ in 0..<40 where fixture.hub.results.first?.title != "Fresh" || fixture.hub.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.hub.results.first?.title == "Fresh")
        #expect(searches == 2)

        holdResolve = true
        fixture.hub.inspect(try #require(fixture.hub.results.first))
        for _ in 0..<20 where pendingResolve == nil { try await Task.sleep(for: .milliseconds(20)) }
        fixture.discoveryRevision += 1
        await mounted.settle()
        #expect(searches == 2 && fixture.hub.isResolving)
        try #require(pendingResolve).resume()
        pendingResolve = nil
        await mounted.settle()
        let preview = try #require(fixture.hub.preview)
        #expect(searches == 2)
        fixture.discoveryRevision += 1
        await mounted.settle()
        #expect(fixture.hub.preview == preview && searches == 2)
        fixture.hub.closePreview()
        for _ in 0..<40 where searches != 3 || fixture.hub.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        await mounted.settle()
        #expect(searches == 3, "Coalesce revisions and consume them before starting another search")
        #expect(fixture.source == source && view.text == source && view.selectedRange == caret)
        #expect(fixture.hub.draftID == draftID && fixture.hub.revision == revision)
        #expect(fixture.hub.selected == selections)
        #expect(view.isFirstResponder && fixture.hub.isEditorActive)
    }

    @Test func chipRemovalUndoRedoAndExpandedTransferUseTheSameNativeEditor() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let manager = try #require(view.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let caret = (fixture.source as NSString).range(of: fixture.snapshot.anchor)
        view.selectedRange = NSRange(location: caret.location + caret.length, length: 0)
        view.delegate?.textViewDidChangeSelection?(view)
        let original = fixture.source
        let originalCaret = view.selectedRange
        manager.beginUndoGrouping()
        fixture.hub.remove(try #require(fixture.hub.selected.first))
        manager.endUndoGrouping()
        #expect(fixture.source == "Before 👩‍💻  after e\u{0301}")
        #expect(fixture.hub.selected.isEmpty)
        #expect(view.isFirstResponder)
        #expect(manager.canUndo)
        manager.undo()
        #expect(Data(fixture.source.utf8) == Data(original.utf8))
        #expect(fixture.hub.selected.map(\.snapshot) == [fixture.snapshot])
        #expect(view.selectedRange == originalCaret)
        manager.redo()
        #expect(fixture.hub.selected.isEmpty)
        manager.undo()
        fixture.expanded = true
        await mounted.settle()
        #expect(mounted.textView() === view)
        #expect(view.undoManager === manager)
        #expect(view.selectedRange == originalCaret)
        #expect(view.isFirstResponder)
        #expect(view.accessibilityLabel == "Expanded message")
        #expect(view.accessibilityHint?.contains("references") == true)
        #expect(view.accessibilityIdentifier == "chat.composer.expanded.text")
        #expect(view.bounds.height > 0 && view.bounds.width > 0)
    }

    @Test func markedTextPreventsReferenceMutationAndCommitsExactNativeText() async throws {
        let fixture = try EditorFixture()
        let mounted = try await MountedEditor(fixture)
        defer { mounted.close() }
        let view = try #require(mounted.textView())
        let selection = try #require(fixture.hub.selected.first)
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        view.delegate?.textViewDidChange?(view)
        #expect(view.markedTextRange != nil)
        #expect(fixture.hub.hasMarkedText)
        #expect(view.autocorrectionType == .default)
        #expect(view.autocapitalizationType == .sentences)
        let composing = Data(view.text.utf8)
        fixture.hub.remove(selection)
        #expect(Data(view.text.utf8) == composing)
        #expect(fixture.hub.selected == [selection])
        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        view.unmarkText()
        view.delegate?.textViewDidChange?(view)
        #expect(!fixture.hub.hasMarkedText)
        #expect(fixture.source.hasSuffix("日本"))
        #expect(Data(fixture.source.utf8) == Data(view.text.utf8))
        #expect(fixture.hub.selected == [selection])
    }

    @Test func directOnlyNoticeIsQuietUntilAnOptionalFilterIsSelected() {
        let hub = ReferenceHubStore(owner: EditorFixture.owner, providers: [], onConnect: { _ in })
        hub.setOptionalProviderUnavailableReason("References are available in direct chats.")
        #expect(hub.message == nil && hub.providerNotices.isEmpty)
        hub.setEditorActive(true)
        hub.receive(source: "/notes", selection: NSRange(location: 6, length: 0), hasMarkedText: false)
        hub.selectCategory(.wiki)
        #expect(!hub.canConnectCategory)
        #expect(hub.providerNotices["reference-mode"] == "References are available in direct chats.")
        hub.selectCategory(.commands)
        #expect(hub.providerNotices.isEmpty)
        #expect(!hub.isLoading)
    }
}

@MainActor @Observable private final class EditorFixture {
    static let owner = ReferenceHubOwner(accountID: "editor_account", hostID: "editor_host",
        deviceID: "editor_device", authorizationEpoch: "1", sessionID: "editor_session",
        agentID: "default", recipientIDs: ["default"])
    let hub: ReferenceHubStore
    let session = ReferenceComposerEditorSession()
    let snapshot: ReferenceSnapshot
    var source: String
    var expanded = false
    var focusRequested = true
    var isEnabled = true
    var surfaceActive = true
    var renderRevision = 0
    var discoveryRevision = 0
    var bubbleColor: BighelpBubbleColor?
    @ObservationIgnored var publications = 0

    init(resolveDelay: Duration = .zero, beforeResolveReturn: @escaping @MainActor () -> Void = {},
         providers: [ReferenceHubProvider]? = nil) throws {
        snapshot = try ReferenceSnapshot(kind: .wiki,
            identity: .wiki(WikiReferenceIdentity(namespace: "editor-notes", relativePath: "note.md")),
            title: "Note", selectedContent: "Exact fixture bytes", sourceRevision: "revision-1",
            fetchedAt: Date(timeIntervalSince1970: 1))
        source = "Before 👩‍💻 " + snapshot.anchor + " after e\u{0301}"
        let frozen = snapshot
        let result = ReferenceHubResult(resourceID: "note", providerID: "wiki", category: .wiki,
            title: "Note", subtitle: "Fixture", state: nil, isCached: false)
        hub = ReferenceHubStore(owner: Self.owner, providers: providers ?? [ReferenceHubProvider(id: "wiki",
            label: "Wiki", categories: [.wiki],
            search: { _, _, _ in ReferenceHubSearchPage(results: [result], isPartial: false) },
            resolve: { _, _ in
                // Intentionally return even after cancellation to exercise ownership guards.
                try? await Task.sleep(for: resolveDelay)
                beforeResolveReturn()
                return ReferenceHubPreview(result: result, sourceKindLabel: "Wiki",
                    options: [ReferenceContentOption(id: "page", label: "Page", snapshot: frozen)])
            },
            revalidate: { _, _ in frozen })])
        hub.resetDraft(source: source, selections: [ReferenceDraftSelection(providerID: "wiki",
            sourceKindLabel: "Wiki", snapshot: snapshot)])
    }
}

@MainActor private struct EditorAcceptanceSurface: View {
    @Bindable var fixture: EditorFixture
    @State private var focused = false
    var body: some View {
        Group {
            if fixture.expanded {
                editor(expanded: true).frame(height: 360)
            } else {
                editor(expanded: false).frame(height: 180)
            }
        }
        .padding()
        .environment(\.appAppearance, BighelpAppearanceContext(appearance: .light, bubbleColor: fixture.bubbleColor))
        .environment(\.colorScheme, .light)
        .modifier(ReferenceDiscoveryRefresh(hub: fixture.hub, revision: fixture.discoveryRevision))
        .onAppear { focused = fixture.focusRequested }
        .onChange(of: fixture.focusRequested) { _, value in focused = value }
    }
    private func editor(expanded: Bool) -> some View {
        ReferenceComposerTextView(text: $fixture.source, hub: fixture.hub, session: fixture.session,
            focus: $focused, isEnabled: fixture.isEnabled, isSurfaceActive: fixture.surfaceActive, expanded: expanded,
            onSelectionChange: { _ in fixture.publications += 1 })
            .accessibilityValue("Render \(fixture.renderRevision)")
    }
}

@MainActor private final class ExpansionReports {
    var values: [Bool] = []
}

/// The chat composer's row: the editor shares a bottom-aligned HStack with Send,
/// and the expand button beside the box narrows it once the draft wraps.
@MainActor private struct ComposerRowSurface: View {
    @Bindable var fixture: EditorFixture
    let reports: ExpansionReports
    @State private var focused = true
    @State private var showsExpandButton = false
    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ReferenceComposerTextView(text: $fixture.source, hub: fixture.hub, session: fixture.session,
                    focus: $focused, isEnabled: true,
                    onExpansionAvailabilityChange: { value in
                        reports.values.append(value)
                        showsExpandButton = value
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .overlay(alignment: .topLeading) { if fixture.source.isEmpty { Text("Message") } }
                Color.clear.frame(width: 44, height: 44)
            }
            if showsExpandButton { Color.clear.frame(width: 44, height: 44) }
        }
        .padding()
        .environment(\.appAppearance, BighelpAppearanceContext(appearance: .light, bubbleColor: nil))
        .environment(\.colorScheme, .light)
    }
}

@MainActor private final class MountedEditor {
    let window: UIWindow
    convenience init(_ fixture: EditorFixture) async throws {
        try await self.init(root: EditorAcceptanceSurface(fixture: fixture))
    }
    init(root: some View) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        await settle()
        _ = textView()?.becomeFirstResponder()
        await settle()
    }
    func textView() -> ClipboardPasteTextView? {
        func walk(_ view: UIView) -> ClipboardPasteTextView? {
            if let text = view as? ClipboardPasteTextView { return text }
            for child in view.subviews { if let result = walk(child) { return result } }
            return nil
        }
        return walk(window)
    }
    func settle() async {
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }
}
