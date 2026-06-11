import Foundation

/// Birthday memories: "Happy birthday, <name>" for every person whose linked
/// contact has a birthday on the target day.
extension MemoryEngine {
    // MARK: Birthday Detection

    /// Build "Happy birthday, <name>" memories for every person whose linked
    /// (manual or auto-matched) contact has a birthday equal to today's
    /// month/day. Photo set = every photo carrying the People/* tag for that
    /// person, sorted oldest → newest so the slideshow tells a story.
    static func generateBirthdayMemories(
        from allPhotos: [PhotoFile],
        contacts: [ContactInfo],
        links: [String: PersonLink],
        lowerNameIndex: [String: ContactInfo],
        calendar: Calendar,
        todayComponents: DateComponents,
        hiddenPeople: Set<String> = []
    ) -> [Memory] {
        guard let todayMonth = todayComponents.month,
              let todayDay = todayComponents.day else { return [] }

        // Group photos by person tag fullPath, retaining the original casing.
        struct PersonBundle { let fullPath: String; let displayName: String; var photos: [PhotoFile] }
        var byPath: [String: PersonBundle] = [:]
        for photo in allPhotos {
            for tag in photo.hierarchicalTags where tag.namespace?.lowercased() == "people" {
                if var existing = byPath[tag.fullPath] {
                    existing.photos.append(photo)
                    byPath[tag.fullPath] = existing
                } else {
                    byPath[tag.fullPath] = PersonBundle(
                        fullPath: tag.fullPath,
                        displayName: tag.displayName,
                        photos: [photo]
                    )
                }
            }
        }

        let contactByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })

        var out: [Memory] = []
        for (path, bundle) in byPath {
            if hiddenPeople.contains(path) { continue }
            // Resolve effective contact: explicit `.disabled` skips this tag,
            // a `.manual` link wins over name-based auto-match, and absence
            // means "auto-match by displayName".
            let contact: ContactInfo?
            switch links[path] {
            case .disabled:
                continue
            case .manual(let id):
                contact = contactByID[id]
            case nil:
                contact = lowerNameIndex[bundle.displayName.lowercased()]
            }
            guard let contact,
                  let bMonth = contact.birthday?.month,
                  let bDay = contact.birthday?.day,
                  bMonth == todayMonth, bDay == todayDay else { continue }

            // Sort dated photos ascending; undated sort to the *front*
            // (`distantPast`), so `ids.last` — the cover — is the most
            // recent dated photo whenever one exists.
            let sortedRaw = bundle.photos.sorted { a, b in
                (a.dateTaken ?? .distantPast) < (b.dateTaken ?? .distantPast)
            }
            let sorted = dedupByTimeWindow(sortedRaw)
            let ids = sorted.map(\.id)
            guard let coverID = ids.last else { continue }

            // Range over dated photos only — a single undated photo must not
            // collapse the range (and the subtitle with it) to nil.
            let datedTimes = sorted.compactMap(\.dateTaken)
            let dateRange: ClosedRange<Date>?
            if let first = datedTimes.first, let last = datedTimes.last {
                dateRange = first...last
            } else {
                dateRange = nil
            }

            // Score sits well above on-this-day / years-ago so birthdays float
            // to the front of the rail on the matching day.
            out.append(Memory(
                id: "birthday-\(path)",
                type: .birthday,
                title: "Happy birthday, \(bundle.displayName)",
                subtitle: nil,
                photoIDs: ids,
                coverPhotoID: coverID,
                dateRange: dateRange,
                score: 100.0,
                yearsAgo: nil,
                personName: bundle.displayName
            ))
        }
        return out
    }
}
