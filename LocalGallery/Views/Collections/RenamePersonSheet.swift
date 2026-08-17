import SwiftUI

/// Rename a person everywhere: every face group carrying the name, every `.xmp`
/// sidecar those groups reach, and the five things the app itself keys by the
/// person's tag path.
///
/// ## Renaming onto somebody who already exists
///
/// It is a merge at the *name* level — every group carrying the old name is
/// relabelled, and both sets then answer to the new one. That is coherent, and
/// it is what somebody renaming "Anna" to "Anna Schmidt" (already present)
/// means. What it must not be is silent, so the confirmation names the photo
/// counts on both sides and the user presses Combine rather than Rename.
struct RenamePersonSheet: View {
    let person: TagSuggestion

    @Environment(GalleryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false
    @State private var showCollisionAlert = false
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The person this rename would fold into, if there is one. Case-insensitive
    /// because the library treats "anna" and "Anna" as one person everywhere it
    /// shows people, even though the core preserves the casing as typed.
    private var collision: TagSuggestion? {
        guard !trimmed.isEmpty, trimmed != person.displayName else { return nil }
        return store.people.peopleTags.first {
            $0.fullPath != person.fullPath
                && $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// A name with a `/` in it would be a different tag path and therefore a
    /// different person to every consumer; the core refuses it, and saying so
    /// next to the field beats an error banner after the fact.
    private var nameProblem: String? {
        guard !trimmed.isEmpty else { return nil }
        return trimmed.contains("/") ? "A name can’t contain “/”." : nil
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != person.displayName && nameProblem == nil
            && !isSaving && !store.faces.isCoreBusy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { attemptSave() }

                    if let problem = nameProblem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(Design.destructive)
                    } else if let collision {
                        Text("“\(collision.displayName)” already exists. Renaming will combine both (\(photoCountLabel(person.count + collision.count))).")
                            .font(.footnote)
                            .foregroundStyle(Design.ink2)
                    }
                } header: {
                    Text("Rename \(person.displayName)")
                } footer: {
                    if store.faces.isCoreBusy {
                        Text("A scan is running — renaming is paused until it finishes.")
                    } else {
                        Text("Rewrites the `People/` keyword and face regions in every affected photo’s `.xmp` sidecar. The photos themselves are never modified.")
                    }
                }

                if let error = store.faces.lastError, error != .cancelled {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Design.destructive)
                    }
                }
            }
            .navigationTitle("Rename Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(collision == nil ? "Rename" : "Combine…") { attemptSave() }
                        .disabled(!canSave)
                }
            }
            .alert("Combine with \(collision?.displayName ?? "")?", isPresented: $showCollisionAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Combine") { save() }
            } message: {
                if let collision {
                    Text("“\(collision.displayName)” already exists. Both people become one, with \(photoCountLabel(person.count + collision.count)).")
                }
            }
            .task {
                name = person.displayName
                focused = true
            }
        }
    }

    private func attemptSave() {
        guard canSave else { return }
        if collision != nil {
            showCollisionAlert = true
        } else {
            save()
        }
    }

    private func save() {
        focused = false
        let old = person.displayName
        let new = trimmed
        isSaving = true
        Task {
            let ok = await store.faces.rename(person: old, to: new)
            isSaving = false
            // Stay put on failure so the error line is readable and the typed
            // name is not lost.
            if ok { dismiss() }
        }
    }
}
