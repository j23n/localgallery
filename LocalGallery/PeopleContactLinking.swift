import SwiftUI
import Contacts

// MARK: - Contact Link Sheet

/// Sheet that lets the user pick which address-book entry corresponds to a
/// People/* tag. Three actions:
///   - Reset to auto-match (forget any manual override)
///   - Disable (no birthday memories for this person)
///   - Pick a specific contact
struct ContactLinkSheet: View {
    let person: TagSuggestion
    @Environment(GalleryStore.self) private var manager
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var requestingAccess = false
    @State private var showDeniedAlert = false

    private var manualLink: PersonLink? { manager.personContactLinks[person.fullPath] }

    private var filteredContacts: [ContactInfo] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = manager.contacts.sorted {
            $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter { $0.fullName.lowercased().contains(trimmed) }
    }

    private var status: CNAuthorizationStatus { ContactsService.authorizationStatus() }

    var body: some View {
        NavigationStack {
            Group {
                if ContactsService.isAuthorized(status) {
                    contactsList
                } else if status == .notDetermined {
                    permissionPrompt
                } else {
                    permissionDenied
                }
            }
            .navigationTitle("Link \(person.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .alert("Contacts access denied", isPresented: $showDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enable Contacts access in iOS Settings to link \(person.displayName) to an address-book entry.")
            }
        }
    }

    // MARK: Empty/permission states

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Design.accentColor)
            Text("Link to a contact")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Design.ink)
            Text("Allow Contacts access so LocalGallery can surface birthday memories for the people in your photos.")
                .font(.subheadline)
                .foregroundStyle(Design.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                requestingAccess = true
                Task {
                    let granted = await manager.requestContactsAccess()
                    requestingAccess = false
                    if !granted { showDeniedAlert = true }
                }
            } label: {
                Text("Allow Contacts")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Design.accentColor, in: Capsule())
            }
            .disabled(requestingAccess)
            .opacity(requestingAccess ? 0.6 : 1)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private var permissionDenied: some View {
        ContentUnavailableView {
            Label("Contacts access denied", systemImage: "person.crop.circle.badge.xmark")
        } description: {
            Text("Enable Contacts access in iOS Settings to link people to address-book entries.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    // MARK: Contacts list

    private var contactsList: some View {
        List {
            Section {
                // Auto-match status row — explains what the app would do absent
                // any manual override.
                statusRow
            } header: {
                Text("Status")
            }

            Section {
                Button {
                    manager.resetPersonLink(person.fullPath)
                    dismiss()
                } label: {
                    Label("Reset to auto-match", systemImage: "arrow.counterclockwise")
                }
                .disabled(manualLink == nil)

                Button(role: .destructive) {
                    manager.unlinkPerson(person.fullPath)
                    dismiss()
                } label: {
                    Label("No contact (skip birthdays)", systemImage: "xmark.circle")
                }
            } header: {
                Text("Actions")
            }

            Section("Choose a contact (\(filteredContacts.count))") {
                if filteredContacts.isEmpty {
                    Text("No contacts match your search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredContacts) { contact in
                        contactRow(contact)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search contacts")
        .task { await manager.loadContacts() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch manager.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
        case .disabled:
            Label {
                Text("Skipped — no birthday memories")
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Design.destructive)
            }
            .font(.subheadline)
        case .manual(let c):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Manually linked: \(c.fullName)")
                    if let line = birthdayLine(for: c) {
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "link.circle.fill").foregroundStyle(Design.accentColor)
            }
            .font(.subheadline)
        case .auto(let c):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-matched: \(c.fullName)")
                    if let line = birthdayLine(for: c) {
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "wand.and.stars").foregroundStyle(Design.accentColor)
            }
            .font(.subheadline)
        case .unlinked:
            Label("No matching contact", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func contactRow(_ contact: ContactInfo) -> some View {
        let isSelected: Bool = {
            if case .manual(let id) = manualLink { return id == contact.id }
            return false
        }()
        return Button {
            manager.linkPerson(person.fullPath, toContactID: contact.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Design.ink3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.fullName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Design.ink)
                    if let line = birthdayLine(for: contact) {
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink3)
                    } else {
                        Text("No birthday on file")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink3)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Design.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func birthdayLine(for contact: ContactInfo) -> String? {
        guard let m = contact.birthday?.month, let d = contact.birthday?.day else { return nil }
        var comps = DateComponents(); comps.month = m; comps.day = d
        if let y = contact.birthday?.year { comps.year = y }
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return nil }
        let fmt = DateFormatter()
        if contact.birthday?.year != nil {
            fmt.dateFormat = "MMMM d, yyyy"
        } else {
            fmt.dateFormat = "MMMM d"
        }
        return "Birthday: \(fmt.string(from: date))"
    }
}

// MARK: - Contacts Permission Primer

/// First-launch sheet shown the first time the user opens the Collections tab.
/// Soft-asks for Contacts access so birthday memories can light up. Skipping
/// records the choice in `hasShownContactsPrimer` so we don't nag again — the
/// user can grant access later from Settings → People → Linked Contacts.
struct ContactsPermissionPrimer: View {
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Design.accentSoft)
                    .frame(width: 84, height: 84)
                Image(systemName: "birthday.cake")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Design.accentColor)
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Birthday memories")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Design.ink)
                Text("Allow Contacts access so LocalGallery can surface a memory for the people in your photos on their birthday. Names are matched only against your photo tags — nothing leaves the device.")
                    .font(.subheadline)
                    .foregroundStyle(Design.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text("Allow Contacts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Design.accentColor, in: Capsule())
                }
                Button(action: onSkip) {
                    Text("Not now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Design.ink2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Design.bg)
    }
}

// MARK: - Linked Contacts (Settings sub-screen)

/// Lists every person tag that currently has a manual contact link or an
/// auto-match, so the user can review and change them in one place.
struct LinkedContactsList: View {
    @Environment(GalleryStore.self) private var manager
    @State private var picker: TagSuggestion?

    private struct Row: Identifiable {
        let person: TagSuggestion
        let contact: ContactInfo?
        let isManual: Bool
        let isExplicitlyDisabled: Bool
        var id: String { person.fullPath }
    }

    private var rows: [Row] {
        // Resolve every person tag through the manager's index-backed
        // `linkState` accessor so this is O(people) rather than
        // O(people × contacts).
        manager.peopleTags.map { person in
            switch manager.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
            case .unlinked:
                return Row(person: person, contact: nil, isManual: false, isExplicitlyDisabled: false)
            case .disabled:
                return Row(person: person, contact: nil, isManual: true, isExplicitlyDisabled: true)
            case .manual(let c):
                return Row(person: person, contact: c, isManual: true, isExplicitlyDisabled: false)
            case .auto(let c):
                return Row(person: person, contact: c, isManual: false, isExplicitlyDisabled: false)
            }
        }
        .sorted { lhs, rhs in
            // Linked-with-birthday-today first, then linked, then auto-matched, then unlinked
            func sortKey(_ r: Row) -> Int {
                if r.isExplicitlyDisabled { return 4 }
                guard let c = r.contact else { return 3 }
                if isBirthdayToday(c) { return 0 }
                return r.isManual ? 1 : 2
            }
            let lk = sortKey(lhs), rk = sortKey(rhs)
            if lk != rk { return lk < rk }
            return lhs.person.displayName.localizedCaseInsensitiveCompare(rhs.person.displayName) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if manager.peopleTags.isEmpty {
                ContentUnavailableView {
                    Label("No people yet", systemImage: "person.fill")
                } description: {
                    Text("Tagged people from your photo library appear here once metadata enrichment finishes.")
                }
            } else {
                List {
                    Section {
                        statusFooter
                    } header: {
                        Text("Contacts access")
                    }
                    Section {
                        ForEach(rows) { row in
                            rowView(row)
                                .contentShape(Rectangle())
                                .onTapGesture { picker = row.person }
                        }
                    } header: {
                        Text("\(rows.count) People")
                    } footer: {
                        Text("Tap a person to change which contact they're linked to. Birthday memories appear automatically on the contact's birthday.")
                    }
                }
            }
        }
        .navigationTitle("Linked Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picker) { person in
            ContactLinkSheet(person: person)
        }
        .task { await manager.loadContacts() }
    }

    @ViewBuilder
    private var statusFooter: some View {
        let status = ContactsService.authorizationStatus()
        if ContactsService.isAuthorized(status) {
            HStack {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text("\(manager.contacts.count) contacts loaded")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        } else if status == .notDetermined {
            Button {
                Task { await manager.requestContactsAccess() }
            } label: {
                Label("Allow Contacts access", systemImage: "person.crop.circle.badge.plus")
            }
        } else {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open iOS Settings", systemImage: "gear")
            }
            .foregroundStyle(Design.destructive)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 12) {
            personThumb(row.person)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.person.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Design.ink)
                statusLine(row)
            }
            Spacer()
            if let c = row.contact, isBirthdayToday(c) {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Design.accentColor, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Design.ink3)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func personThumb(_ person: TagSuggestion) -> some View {
        if let photo = manager.featuredPhoto(for: person) {
            ThumbnailView(url: photo.url, size: 40, cornerRadius: 20)
                .frame(width: 40, height: 40)
        } else {
            Circle()
                .fill(Design.bgGrouped)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Design.ink3)
                }
        }
    }

    @ViewBuilder
    private func statusLine(_ row: Row) -> some View {
        if row.isExplicitlyDisabled {
            Label("Skipped", systemImage: "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Design.ink3)
        } else if let c = row.contact {
            HStack(spacing: 4) {
                Image(systemName: row.isManual ? "link.circle.fill" : "wand.and.stars")
                    .font(.system(size: 10))
                Text(row.isManual ? "Linked: \(c.fullName)" : "Auto: \(c.fullName)")
                    .lineLimit(1)
                if let line = birthdayShort(c) {
                    Text("· \(line)").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Design.ink2)
        } else {
            Text("No matching contact")
                .font(.system(size: 12))
                .foregroundStyle(Design.ink3)
        }
    }

    private func birthdayShort(_ contact: ContactInfo) -> String? {
        guard let m = contact.birthday?.month, let d = contact.birthday?.day else { return nil }
        var comps = DateComponents(); comps.month = m; comps.day = d
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    /// `nonisolated` so the synchronous `.sorted` closure (which doesn't
    /// inherit View's MainActor isolation) can call this. Pure function over
    /// Sendable inputs — no MainActor state read.
    private nonisolated func isBirthdayToday(_ contact: ContactInfo) -> Bool {
        guard let m = contact.birthday?.month, let d = contact.birthday?.day else { return false }
        let today = Calendar.current.dateComponents([.month, .day], from: Date())
        return today.month == m && today.day == d
    }
}
