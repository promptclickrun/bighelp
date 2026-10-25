import SwiftUI
import UIKit
#if canImport(ContactsUI)
@preconcurrency import ContactsUI
#endif

/// The review of one draft: the photo beside every field, what to check, where it goes, anything
/// already on the phone that looks like it, and Save or Discard. Nothing is written before Save;
/// closing keeps the draft and the person's changes.
@MainActor
struct ImageDraftReviewSheet: View {
    let draft: ImageDraft
    let key: ImageDraftKey

    @State private var store = ImageDraftStore.shared
    @State private var review: ImageDraftReview
    @State private var options: ImageDraftDestinationOptions?
    @State private var duplicates: ImageDraftDuplicateCheck?
    @State private var isWorking = false
    @State private var note: String?
    @State private var editor: ImageDraftApproval?
    @State private var isDiscardConfirmationPresented = false
    @State private var showsPhoto = false
    @State private var browsesContacts = false
    /// Times filled in by Add: a starting point for the picker, not a value. Save waits until the
    /// person changes it or says it's right.
    @State private var suggested = Set<String>()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @BighelpThemeReader private var theme

    init(draft: ImageDraft, key: ImageDraftKey) {
        self.draft = draft
        self.key = key
        _review = State(initialValue: ImageDraftReview(draft: draft, edits: ImageDraftStore.shared.edits(key)))
    }

    private var status: ImageDraftStatus { store.status(key) }
    private var isContact: Bool { draft.preset == .businessCard }

    /// The fields take edits only while the draft waits for a decision.
    private var isEditable: Bool {
        switch status {
        case .unknown, .awaitingReview, .failed: !isWorking
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                header
                if isContact { contactSections } else { eventSections }
                destinationSection
                duplicateSection
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .dismissesKeyboardOnScroll(true)
            .navigationTitle(isContact ? String(localized: "New contact") : String(localized: "New event"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(theme.primaryText)
                            .bighelpToolbarIcon()
                    }
                    .bighelpIconLabel(String(localized: "Close"))
                    .accessibilityHint(Text("Keeps the draft and your changes"))
                    .accessibilityIdentifier("image-draft.review.close")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .task { await loadDestinations() }
        .task(id: review.fields) { await checkDuplicates() }
        .onChange(of: review.edits) { _, edits in store.keepEdits(edits, for: key) }
        .confirmationDialog(isContact ? "Discard this contact?" : "Discard this event?",
                            isPresented: $isDiscardConfirmationPresented, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { Task { await discard() } }
                .accessibilityIdentifier("image-draft.review.discard.confirm")
        } message: {
            Text("Nothing is saved, and the agent hears that you discarded it.")
        }
        .bighelpFullScreenCover(isPresented: $showsPhoto) {
            if let photo = store.photo(key) { ImageDraftPhotoViewer(image: photo) }
        }
        .bighelpSheet(item: $editor) { approval in
            appleEditor(approval)
                .ignoresSafeArea()
                .bighelpSheetSize(.standard)
                .interactiveDismissDisabled()
        }
        #if canImport(ContactsUI)
        .bighelpSheet(isPresented: $browsesContacts) {
            ImageDraftContactBrowser()
                .ignoresSafeArea()
                .bighelpSheetSize(.standard)
        }
        #endif
        .accessibilityIdentifier("image-draft.review")
    }

    // MARK: Header: the agent's note, the photo, what to check

    @ViewBuilder
    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                statusBanner
                if isEditable { ImageDraftReviewNote(text: review.message(.review)) }
                photo
                let checks = review.checkList
                if isEditable, !checks.isEmpty {
                    ImageDraftCheckBox(lines: checks.map(\.text), note: review.missingFieldsMessage)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var photo: some View {
        Button { showsPhoto = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = store.photo(key) ?? store.thumbnail(key) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        Image(systemName: isContact ? "person.text.rectangle" : "calendar")
                            .font(.bighelp(.largeTitle))
                            .foregroundStyle(theme.tertiaryText)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 170)
                .background(theme.raisedSurface)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.45), in: .circle)
                    .padding(BighelpTokens.space8)
                    .accessibilityHidden(true)
            }
            .clipShape(.rect(cornerRadius: BighelpTokens.radius16, style: .continuous))
            .contentShape(.rect(cornerRadius: BighelpTokens.radius16))
        }
        .bighelpPlainButtonStyle()
        .disabled(store.photo(key) == nil)
        .accessibilityLabel(Text("The photo you sent"))
        .accessibilityHint(Text("Opens it full screen"))
        .accessibilityIdentifier("image-draft.review.photo")
        .task { await store.loadImages(key, source: draft.source) }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch status {
        case .applying:
            banner(String(localized: "Saving…"), systemImage: nil, color: theme.secondaryText, working: true)
        case .saved(_, let recordID, let verified):
            banner(review.message(.saved) + (verified || recordID != nil ? ""
                   : (isContact ? String(localized: " Contacts reported it saved.") : String(localized: " Calendar reported it saved."))),
                   systemImage: "checkmark.circle.fill", color: theme.success)
        case .failed(let reason):
            banner(review.message(.failed, reason: reason), systemImage: "xmark.circle.fill", color: theme.danger)
        case .outcomeUnknown:
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                banner(review.message(.outcomeUnknown), systemImage: "questionmark.circle.fill", color: theme.warning)
                checkButtons
            }
        case .discarded:
            banner(String(localized: "You discarded this draft. Nothing was saved."), systemImage: nil, color: theme.secondaryText)
        case .replaced:
            banner(String(localized: "A newer draft replaced this one. Review that one instead."), systemImage: nil,
                   color: theme.secondaryText)
        case .mismatched:
            banner(String(localized: "This card doesn't match the draft the agent made, so it can't be saved. Ask for it again."),
                   systemImage: "exclamationmark.triangle.fill", color: theme.warning)
        case .unknown, .awaitingReview:
            EmptyView()
        }
        if let note {
            banner(note, systemImage: "exclamationmark.circle", color: theme.danger)
        }
    }

    private func banner(_ text: String, systemImage: String?, color: Color, working: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            if working { ProgressView().controlSize(.small) }
            if let systemImage { Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true) }
            Text(text)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: .rect(cornerRadius: BighelpTokens.radius12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("image-draft.review.status")
    }

    /// After an interrupted Save: look first, then say what's there. bighelp never saves again by itself.
    private var checkButtons: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Button(isContact ? String(localized: "Look in Contacts") : String(localized: "Look in Calendar")) {
                if isContact { browsesContacts = true }
                else if case .event(let event) = review.fields, let url = ImageDraftEventSummary.calendarURL(event) { openURL(url) }
            }
            .accessibilityIdentifier("image-draft.review.look")
            HStack(spacing: BighelpTokens.space12) {
                Button(isContact ? String(localized: "It's in Contacts") : String(localized: "It's in Calendar")) {
                    Task { await run { await store.confirmSaved(key) } }
                }
                .accessibilityIdentifier("image-draft.review.confirm-saved")
                Button(String(localized: "It's not there")) {
                    Task { await run { await store.reopen(key) } }
                }
                .accessibilityIdentifier("image-draft.review.reopen")
            }
        }
        .font(.bighelp(.subheadline, weight: .semibold))
        .foregroundStyle(theme.action)
        .buttonStyle(.borderless)
        .disabled(isWorking)
    }

    // MARK: Contact

    @ViewBuilder
    private var contactSections: some View {
        Section {
            textRow("First name", path: "given_name", text: contactText(\.givenName))
            textRow("Last name", path: "family_name", text: contactText(\.familyName))
        } header: { AgentStudioCaption("Name") }
            .listRowBackground(theme.surface)
        Section {
            textRow("Company", path: "organization", text: contactText(\.organization))
            textRow("Job title", path: "job_title", text: contactText(\.jobTitle))
        } header: { AgentStudioCaption("Work") }
            .listRowBackground(theme.surface)
        Section {
            entries(\.phones, root: "phones", placeholder: "Phone", keyboard: .phonePad,
                    labels: ["mobile", "work", "home", "main", "other"])
            entries(\.emails, root: "emails", placeholder: "Email", keyboard: .emailAddress,
                    labels: ["work", "home", "other"])
        } header: { AgentStudioCaption("Phone and email") }
            .listRowBackground(theme.surface)
        addressSection
    }

    private func contactText(_ field: WritableKeyPath<ContactDraftFields, String?>) -> Binding<String> {
        Binding(get: { review.contact?[keyPath: field] ?? "" },
                set: { value in review.contact?[keyPath: field] = value.isEmpty ? nil : value })
    }

    @ViewBuilder
    private func entries(_ list: WritableKeyPath<ContactDraftFields, [ImageDraftLabeledValue]>, root: String,
                         placeholder: LocalizedStringKey, keyboard: UIKeyboardType, labels: [String]) -> some View {
        let values = review.contact?[keyPath: list] ?? []
        ForEach(values.indices, id: \.self) { index in
            HStack(spacing: BighelpTokens.space8) {
                Menu {
                    ForEach(labels, id: \.self) { label in
                        Button(label) { review.contact?[keyPath: list][index].label = label }
                    }
                } label: {
                    Text(values[index].label ?? labels[0])
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.action)
                        .frame(width: 64, alignment: .leading)
                }
                .disabled(!isEditable)
                fieldRow(placeholder, path: "\(root).\(index)", text: Binding(
                    get: { review.contact?[keyPath: list][safe: index]?.value ?? "" },
                    set: { value in
                        guard (review.contact?[keyPath: list].count ?? 0) > index else { return }
                        review.contact?[keyPath: list][index].value = value
                    }), keyboard: keyboard)
            }
        }
        .onDelete(perform: isEditable ? { offsets in review.contact?[keyPath: list].remove(atOffsets: offsets) } : nil)
        if isEditable, values.count < ImageDraftWire.maximumEntries {
            Button {
                review.contact?[keyPath: list].append(ImageDraftLabeledValue(label: labels[0], value: ""))
            } label: {
                Label(root == "phones" ? String(localized: "Add phone") : String(localized: "Add email"),
                      systemImage: "plus.circle.fill")
                    .foregroundStyle(theme.action)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
        }
    }

    @ViewBuilder
    private var addressSection: some View {
        if review.contact?.postalAddress != nil {
            Section {
                textRow("Street", path: "postal_address.street", text: addressText(\.street))
                textRow("City", path: "postal_address.city", text: addressText(\.city))
                textRow("State or region", path: "postal_address.region", text: addressText(\.region))
                textRow("Postal code", path: "postal_address.postal_code", text: addressText(\.postalCode))
                textRow("Country", path: "postal_address.country", text: addressText(\.country))
            } header: { AgentStudioCaption("Address") }
                .listRowBackground(theme.surface)
        } else if isEditable {
            Section {
                Button {
                    review.contact?.postalAddress = ImageDraftPostalAddress()
                } label: {
                    Label("Add address", systemImage: "plus.circle.fill").foregroundStyle(theme.action)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
            }
            .listRowBackground(theme.surface)
        }
    }

    private func addressText(_ part: WritableKeyPath<ImageDraftPostalAddress, String?>) -> Binding<String> {
        Binding(get: { review.contact?.postalAddress?[keyPath: part] ?? "" },
                set: { value in review.contact?.postalAddress?[keyPath: part] = value.isEmpty ? nil : value })
    }

    // MARK: Event

    @ViewBuilder
    private var eventSections: some View {
        Section {
            textRow("Title", path: "title", text: eventText(\.title))
            textRow("Place", path: "location", text: eventText(\.location))
        } header: { AgentStudioCaption("Event") }
            .listRowBackground(theme.surface)
        Section {
            Toggle("All day", isOn: Binding(get: { review.event?.isAllDay ?? false },
                                            set: { review.setAllDay($0) }))
                .tint(theme.action)
                .disabled(!isEditable)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("image-draft.review.all-day")
            if review.event?.isAllDay == true { allDayRows } else { timedRows }
        } header: { AgentStudioCaption("When") }
            .listRowBackground(theme.surface)
        Section {
            TextField("Notes", text: eventText(\.notes), axis: .vertical)
                .lineLimit(2...6)
                .disabled(!isEditable)
                .bighelpMacField()
                .accessibilityIdentifier("image-draft.field.notes")
        } header: { AgentStudioCaption("Notes") }
            .listRowBackground(theme.surface)
    }

    private func eventText(_ field: WritableKeyPath<EventDraftFields, String?>) -> Binding<String> {
        Binding(get: { review.event?[keyPath: field] ?? "" },
                set: { value in review.event?[keyPath: field] = value.isEmpty ? nil : value })
    }

    private var timed: EventDraftFields.Timed? {
        guard case .timed(let timed)? = review.event?.timing else { return nil }
        return timed
    }

    private var eventZone: TimeZone {
        timed?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private func setTimed(_ change: (inout EventDraftFields.Timed) -> Void) {
        guard var timed else { return }
        change(&timed)
        review.event?.timing = .timed(timed)
    }

    @ViewBuilder
    private var timedRows: some View {
        let zone = eventZone
        dateRow("Starts", path: "start", value: timed?.start.flatMap(ImageDraftEventTime.date), zone: zone,
                components: [.date, .hourAndMinute]) { date in
            setTimed { $0.start = ImageDraftEventTime.string(date, in: zone) }
        } add: {
            setTimed { $0.start = ImageDraftEventTime.string(Date(), in: zone) }
            suggested.insert("start")
        }
        dateRow("Ends", path: "end", value: timed?.end.flatMap(ImageDraftEventTime.date), zone: zone,
                components: [.date, .hourAndMinute]) { date in
            setTimed { $0.end = ImageDraftEventTime.string(date, in: zone) }
        } add: {
            // The person picks an end; the hour after the start is only where the picker opens.
            let start = timed?.start.flatMap(ImageDraftEventTime.date) ?? Date()
            setTimed { $0.end = ImageDraftEventTime.string(start.addingTimeInterval(3_600), in: zone) }
            suggested.insert("end")
        }
        NavigationLink {
            ImageDraftTimeZonePicker(selection: Binding(
                get: { timed?.timeZone }, set: { id in setTimed { Self.change(&$0, toZone: id) } }),
                suggested: [timed?.timeZone, TimeZone.current.identifier].compactMap { $0 })
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text("Time zone").foregroundStyle(theme.secondaryText).frame(width: 96, alignment: .leading)
                Text(timed?.timeZone.flatMap(Self.zoneName) ?? String(localized: "Choose"))
                    .foregroundStyle(timed?.timeZone == nil ? theme.tertiaryText : theme.primaryText)
                Spacer(minLength: 0)
                badges("time_zone")
            }
            .frame(minHeight: BighelpTokens.hitTarget)
        }
        .disabled(!isEditable)
        .accessibilityIdentifier("image-draft.field.time_zone")
    }

    /// A poster's time is the time where the event is: fixing a wrongly guessed zone keeps 7 PM at
    /// 7 PM in the new zone, instead of moving the same instant to another clock time.
    static func change(_ timed: inout EventDraftFields.Timed, toZone id: String?) {
        let old = timed.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        if let id, let new = TimeZone(identifier: id) {
            timed.start = timed.start.flatMap { rezone($0, from: old, to: new) } ?? timed.start
            timed.end = timed.end.flatMap { rezone($0, from: old, to: new) } ?? timed.end
        }
        timed.timeZone = id
    }

    private static func rezone(_ text: String, from old: TimeZone, to new: TimeZone) -> String? {
        guard let date = ImageDraftEventTime.date(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = old
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        parts.timeZone = new
        calendar.timeZone = new
        return calendar.date(from: parts).map { ImageDraftEventTime.string($0, in: new) }
    }

    private static func zoneName(_ id: String) -> String? {
        guard let zone = TimeZone(identifier: id) else { return nil }
        return zone.localizedName(for: .generic, locale: .current) ?? id
    }

    @ViewBuilder
    private var allDayRows: some View {
        let days: EventDraftFields.AllDay? = {
            guard case .allDay(let days)? = review.event?.timing else { return nil }
            return days
        }()
        let local = TimeZone.current
        dateRow("Date", path: "start_date", value: days?.startDate.flatMap { ImageDraftEventTime.startOfDay($0, in: local) },
                zone: local, components: [.date]) { date in
            setDays { $0.startDate = ImageDraftEventTime.dayString(date, in: local) }
        } add: {
            setDays { $0.startDate = ImageDraftEventTime.dayString(Date(), in: local) }
            suggested.insert("start_date")
        }
        if let end = days?.endDate.flatMap({ ImageDraftEventTime.startOfDay($0, in: local) }) {
            // The draft's end date is the day after; people pick the last day.
            dateRow("Last day", path: "end_date", value: end.addingTimeInterval(-86_400), zone: local,
                    components: [.date]) { date in
                setDays { $0.endDate = ImageDraftEventTime.dayString(date.addingTimeInterval(86_400), in: local) }
            } add: {}
        } else if isEditable {
            Button("Add a last day") {
                let start = days?.startDate.flatMap { ImageDraftEventTime.startOfDay($0, in: local) } ?? Date()
                setDays { $0.endDate = ImageDraftEventTime.dayString(start.addingTimeInterval(2 * 86_400), in: local) }
            }
            .foregroundStyle(theme.action)
            .frame(minHeight: BighelpTokens.hitTarget)
        }
    }

    private func setDays(_ change: (inout EventDraftFields.AllDay) -> Void) {
        guard case .allDay(var days)? = review.event?.timing else { return }
        change(&days)
        review.event?.timing = .allDay(days)
    }

    @ViewBuilder
    private func dateRow(_ title: LocalizedStringKey, path: String, value: Date?, zone: TimeZone,
                         components: DatePickerComponents, set: @escaping (Date) -> Void,
                         add: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            HStack(spacing: BighelpTokens.space8) {
                Text(title).foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                if suggested.contains(path) {
                    ImageDraftBadgeView(badge: .guess)
                    Button { suggested.remove(path) } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.action)
                            .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .bighelpIconLabel(String(localized: "Looks right"))
                    .accessibilityIdentifier("image-draft.confirm.\(path)")
                } else {
                    badges(path)
                }
            }
            if let value {
                DatePicker(title, selection: Binding(get: { value }, set: { set($0); suggested.remove(path) }),
                           displayedComponents: components)
                    .labelsHidden()
                    .environment(\.timeZone, zone)
                    .disabled(!isEditable)
            } else {
                Button(String(localized: "Add")) { add() }
                    .foregroundStyle(theme.action)
                    .disabled(!isEditable)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
        }
        .padding(.vertical, BighelpTokens.space4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image-draft.field.\(path)")
    }

    // MARK: Fields

    private func textRow(_ title: LocalizedStringKey, path: String, text: Binding<String>) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(title).foregroundStyle(theme.secondaryText).frame(width: 96, alignment: .leading)
            fieldRow(title, path: path, text: text, keyboard: .default)
        }
    }

    private func fieldRow(_ placeholder: LocalizedStringKey, path: String, text: Binding<String>,
                          keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            TextField(placeholder, text: text, prompt: Text(placeholder).bighelpFieldHint(theme))
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .autocorrectionDisabled(keyboard != .default)
                .disabled(!isEditable)
                .bighelpMacField()
                .accessibilityIdentifier("image-draft.field.\(path)")
            // Under the value, so a long one keeps the whole row.
            if !review.badges(at: ImageDraftFieldPath(known: path)).isEmpty {
                HStack(spacing: BighelpTokens.space8) { badges(path) }
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget)
    }

    /// A field's marks, and Looks right for a marked value the person checked and keeps.
    @ViewBuilder
    private func badges(_ rawPath: String) -> some View {
        let path = ImageDraftFieldPath(known: rawPath)
        let badges = review.badges(at: path)
        ForEach(badges, id: \.self) { badge in ImageDraftBadgeView(badge: badge) }
        if isEditable, badges.contains(where: { $0 == .check || $0 == .guess }) {
            Button {
                review.confirm(path)
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.action)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .bighelpIconLabel(String(localized: "Looks right"))
            .accessibilityIdentifier("image-draft.confirm.\(rawPath)")
        }
    }

    // MARK: Destination and duplicates

    @ViewBuilder
    private var destinationSection: some View {
        Section {
            if let options, options.access == .granted, !options.choices.isEmpty {
                Picker(isContact ? String(localized: "Account") : String(localized: "Calendar"),
                       selection: Binding(get: { review.destination ?? options.suggested },
                                          set: { review.destination = $0 })) {
                    ForEach(groups(options.choices), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.choices) { choice in
                                destinationLabel(choice).tag(choice.destination)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.action)
                .disabled(!isEditable)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("image-draft.review.destination")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isContact ? "Default account" : "Default calendar")
                        .foregroundStyle(theme.primaryText)
                    Text(isContact ? "The one set in iOS Settings › Contacts" : "The one set in iOS Settings › Calendar")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("image-draft.review.destination")
                if options?.access == .notDetermined, isEditable {
                    Button(isContact ? "Choose another account…" : "Choose another calendar…") {
                        Task { await requestAccess() }
                    }
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("image-draft.review.choose-destination")
                }
            }
        } header: {
            AgentStudioCaption(isContact ? "Save to" : "Add to")
        } footer: {
            if let options, options.access != .granted {
                Text(options.access == .notDetermined
                     ? (isContact ? "To list your accounts, bighelp asks iOS for Contacts access once. You don't need it to save."
                                  : "To list your calendars, bighelp asks iOS for Calendar access once. You don't need it to save.")
                     : (isContact ? "Save opens Contacts' own New Contact screen, filled in. Its Done saves it."
                                  : "Save opens Calendar's own New Event screen, filled in, with its own calendar choice. Its Add saves it."))
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .listRowBackground(theme.surface)
    }

    private func destinationLabel(_ choice: ImageDraftDestinationChoice) -> some View {
        Label {
            Text(choice.isDefault ? String(localized: "\(choice.destination.label) (default)") : choice.destination.label)
        } icon: {
            Image(systemName: "circle.fill")
                .foregroundStyle(choice.colorHex.map { Color(hex: $0) } ?? theme.secondaryText)
        }
    }

    private func groups(_ choices: [ImageDraftDestinationChoice]) -> [(title: String, choices: [ImageDraftDestinationChoice])] {
        var order: [String] = []
        var byGroup: [String: [ImageDraftDestinationChoice]] = [:]
        for choice in choices {
            let title = choice.group ?? ""
            if byGroup[title] == nil { order.append(title) }
            byGroup[title, default: []].append(choice)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    @ViewBuilder
    private var duplicateSection: some View {
        switch duplicates {
        case .found(let found)?:
            Section {
                ForEach(found) { duplicate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(duplicate.title).foregroundStyle(theme.primaryText)
                        if let detail = duplicate.detail {
                            Text(detail).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                        }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                AgentStudioCaption(isContact ? "Already in Contacts?" : "Already in Calendar?")
            } footer: {
                Text(isContact ? "Save adds a new contact. bighelp never changes or merges the one you have."
                               : "Save adds a new event. bighelp never changes the one you have.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
            .listRowBackground(theme.surface)
            .accessibilityIdentifier("image-draft.review.duplicates")
        case .cannotCheck?:
            Section {
            } footer: {
                Text(isContact ? "Without Contacts access, bighelp can't check whether this person is already saved."
                               : "Without Calendar access, bighelp can't check whether this event is already saved.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
            }
        case .none?, nil:
            EmptyView()
        }
    }

    // MARK: Save and Discard

    private var bottomBar: some View {
        VStack(spacing: BighelpTokens.space8) {
            if isEditable, let message = review.saveBlockers.first(where: { $0 != .needsDestination })?.message
                ?? (suggested.isEmpty ? nil : String(localized: "Pick the time you want, or tap Looks right.")) {
                Text(message)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("image-draft.review.blocker")
            }
            if isEditable || isWorking {
                HStack(spacing: BighelpTokens.space12) {
                    barButton(String(localized: "Discard"), prominent: false, identifier: "image-draft.review.discard") {
                        isDiscardConfirmationPresented = true
                    }
                    .disabled(isWorking)
                    barButton(isContact ? String(localized: "Save to Contacts") : String(localized: "Add to Calendar"),
                              prominent: true, identifier: "image-draft.review.save") {
                        Task { await save() }
                    }
                    // No Return shortcut: a write to Contacts or Calendar is always a deliberate tap.
                    .disabled(isWorking || !canSave)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space12)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: .infinity)
        .background {
            theme.canvas
                .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The destination is filled in when the options load, so only the fields can hold Save back.
    private var canSave: Bool {
        var review = review
        if review.destination == nil { review.destination = options?.suggested }
        return options != nil && review.canSave && suggested.isEmpty
    }

    private func barButton(_ title: String, prominent: Bool, identifier: String,
                           run: @escaping () -> Void) -> some View {
        ImageDraftBarButton(title: title, prominent: prominent, identifier: identifier, isWorking: isWorking, run: run)
    }

    // MARK: Actions

    private func loadDestinations() async {
        let loaded = await store.options(for: draft.preset)
        options = loaded
        if review.destination == nil || !(loaded.choices.contains { $0.destination == review.destination }
                                           || review.destination == loaded.suggested) {
            review.destination = loaded.suggested
        }
    }

    private func requestAccess() async {
        let loaded = await store.requestAccess(for: draft.preset)
        options = loaded
        review.destination = loaded.suggested
        await checkDuplicates()
    }

    private func checkDuplicates() async {
        // Typing settles before the check runs, so a long edit doesn't read Contacts per letter.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        duplicates = await store.duplicates(of: review.fields)
    }

    private func save() async {
        guard let options else { return }
        if review.destination == nil { review.destination = options.suggested }
        note = nil
        isWorking = true
        defer { isWorking = false }
        if case .failed = status {
            // A failed Save is tried again from a reopened draft, never over the old decision.
            _ = await store.reopen(key)
        }
        if options.savesThroughAppleEditor {
            if let approval = await store.beginEditorSave(review, key: key) {
                editor = approval
            } else {
                note = store.lastError[key]
            }
            return
        }
        let result = await store.save(review, key: key)
        finish(result)
    }

    private func finishEditor(_ approval: ImageDraftApproval, _ result: ImageDraftEditorResult) {
        editor = nil
        Task {
            isWorking = true
            defer { isWorking = false }
            finish(await store.finishEditorSave(approval, result: result))
        }
    }

    private func finish(_ result: ImageDraftStatus) {
        switch result {
        case .saved: dismiss()
        case .awaitingReview, .unknown: note = store.lastError[key]
        default: break
        }
    }

    private func discard() async {
        isWorking = true
        defer { isWorking = false }
        if case .discarded = await store.discard(key) { dismiss() } else { note = store.lastError[key] }
    }

    private func run(_ action: () async -> ImageDraftStatus) async {
        isWorking = true
        defer { isWorking = false }
        _ = await action()
        note = store.lastError[key]
    }

    @ViewBuilder
    private func appleEditor(_ approval: ImageDraftApproval) -> some View {
        switch approval.fields {
        case .contact(let fields):
            #if canImport(ContactsUI)
            ImageDraftContactEditor(fields: fields) { finishEditor(approval, $0) }
            #else
            Color.clear.onAppear { finishEditor(approval, .cancelled) }
            #endif
        case .event(let fields):
            #if canImport(EventKitUI)
            if let plan = try? ImageDraftEventPlan(fields) {
                ImageDraftEventEditor(plan: plan) { finishEditor(approval, $0) }
            } else {
                Color.clear.onAppear { finishEditor(approval, .cancelled) }
            }
            #else
            Color.clear.onAppear { finishEditor(approval, .cancelled) }
            #endif
        }
    }
}

/// Discard and Save. Off is drawn in solid colors: the form under the bar never shows through.
private struct ImageDraftBarButton: View {
    let title: String
    let prominent: Bool
    let identifier: String
    let isWorking: Bool
    let run: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @BighelpThemeReader private var theme

    var body: some View {
        Button(action: run) {
            HStack(spacing: BighelpTokens.space8) {
                if prominent, isWorking { ProgressView().controlSize(.small).tint(theme.actionForeground) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.bighelp(.body, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(background, in: .capsule)
            .overlay { if !prominent { Capsule().stroke(theme.border, lineWidth: 1) } }
            .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(identifier)
    }

    private var foreground: Color {
        guard isEnabled || isWorking else { return theme.tertiaryText }
        return prominent ? theme.actionForeground : theme.primaryText
    }

    private var background: Color {
        guard prominent else { return theme.raisedSurface }
        return isEnabled || isWorking ? theme.action : theme.separator
    }
}

extension ImageDraftApproval: Identifiable {
    var id: String { decisionID }
}

/// Every time zone, searchable, with the draft's and this phone's first.
private struct ImageDraftTimeZonePicker: View {
    @Binding var selection: String?
    let suggested: [String]
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    private var matches: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { id in
            id.localizedCaseInsensitiveContains(query)
                || (TimeZone(identifier: id)?.localizedName(for: .generic, locale: .current) ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section { BighelpSearchField(text: $query, prompt: String(localized: "Search time zones")) }
                .listRowBackground(Color.clear)
            if query.isEmpty {
                Section("Suggested") {
                    ForEach(Array(Set(suggested)).sorted(), id: \.self) { row($0) }
                }
                .listRowBackground(theme.surface)
            }
            Section {
                ForEach(matches, id: \.self) { row($0) }
            }
            .listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Time zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ id: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimeZone(identifier: id)?.localizedName(for: .generic, locale: .current) ?? id)
                        .foregroundStyle(theme.primaryText)
                    Text(id).font(.bighelp(.footnote)).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if selection == id { Image(systemName: "checkmark").foregroundStyle(theme.action) }
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#if canImport(ContactsUI)
/// Contacts' own picker, to look through the address book after an interrupted Save. It runs
/// outside bighelp, needs no access, and nothing picked is read.
private struct ImageDraftContactBrowser: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactPickerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { dismiss() }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { dismiss() }
    }
}
#endif

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
