import Foundation
import os

/// Parallel EXIF / XMP / video-date enrichment for photos that lack
/// `enrichedFileDate`. Pure detached-task work over a `[PhotoFile]`
/// snapshot — the Store handles the gate, observed-state assignment,
/// folder-tree merge, and cache write.
enum EnrichmentService {
    /// Per-photo enrichment payload. The detached task collects these in
    /// parallel via a TaskGroup and the orchestrator merges them back into
    /// the photo array.
    struct EnrichedResult: Sendable {
        let index: Int
        let dateTaken: Date?
        let dateFromMetadata: Bool
        let hierarchicalTags: [HierarchicalTag]
        let countryCode: String?
        let gpsLatitude: Double?
        let gpsLongitude: Double?
        let enrichedFileDate: Date?
        let faceRegions: [FaceRegion]
    }

    /// Enrich every photo whose `enrichedFileDate` is nil. Returns the same
    /// array with stale entries replaced; entries already enriched are
    /// passed through unchanged. Cooperative — checks `Task.isCancelled`
    /// per photo so a foreground rescan can short-circuit.
    ///
    /// `onProgress` is invoked from the detached task as each photo finishes
    /// (in TaskGroup completion order, not necessarily input order). The first
    /// argument is the cumulative completed count, the second is the total
    /// stale count discovered up-front. Use it to drive a progress bar; hop
    /// to the main actor inside the closure if you need to publish state.
    static func enrich(
        photos: [PhotoFile],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [PhotoFile] {
        let startTime = CFAbsoluteTimeGetCurrent()

        return await Task.detached(priority: .background) {
            var result = photos
            let staleIndices = result.indices.filter { result[$0].enrichedFileDate == nil }
            let staleTotal = staleIndices.count
            onProgress?(0, staleTotal)

            // Enrich stale photos in parallel via TaskGroup. Pre-extract
            // `photo` outside the addTask closure so the closure captures
            // only `let` values — Swift 6's sending check rejects captures
            // of the surrounding mutable `result` var. `FileManager.default`
            // is referenced inline inside the closure for the same reason.
            let batchResults: [EnrichedResult] = await withTaskGroup(of: EnrichedResult?.self) { group in
                for idx in staleIndices {
                    let photo = result[idx]
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let modDate = (try? FileManager.default.attributesOfItem(atPath: photo.url.path)[.modificationDate]) as? Date

                        if photo.isVideo {
                            // Videos: prefer AVAsset.creationDate (embedded
                            // capture date) over filesystem dates, which often
                            // reflect the download/AirDrop time rather than
                            // when the video was actually recorded.
                            var dateTaken = photo.dateTaken
                            var dateFromMetadata = false
                            if let avDate = await MetadataReader.readVideoDate(url: photo.url) {
                                dateTaken = avDate
                                dateFromMetadata = true
                            } else if dateTaken == nil {
                                let attrs = try? photo.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                                dateTaken = MetadataReader.earliestFilesystemDate(
                                    creation: attrs?.creationDate,
                                    modification: attrs?.contentModificationDate
                                )
                            }
                            return EnrichedResult(
                                index: idx,
                                dateTaken: dateTaken,
                                dateFromMetadata: dateFromMetadata,
                                hierarchicalTags: photo.hierarchicalTags,
                                countryCode: photo.countryCode,
                                gpsLatitude: photo.gpsLatitude,
                                gpsLongitude: photo.gpsLongitude,
                                enrichedFileDate: modDate ?? Date(),
                                faceRegions: photo.faceRegions
                            )
                        }

                        let metadata = MetadataReader.readImageMetadata(url: photo.url)

                        var dateTaken = photo.dateTaken
                        var dateFromMetadata = false
                        if let date = metadata.date {
                            dateTaken = date
                            dateFromMetadata = true
                        } else if dateTaken == nil {
                            let attrs = try? photo.url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                            dateTaken = MetadataReader.earliestFilesystemDate(
                                creation: attrs?.creationDate,
                                modification: attrs?.contentModificationDate
                            )
                        }

                        return EnrichedResult(
                            index: idx,
                            dateTaken: dateTaken,
                            dateFromMetadata: dateFromMetadata,
                            hierarchicalTags: metadata.hierarchicalTags.isEmpty ? photo.hierarchicalTags : metadata.hierarchicalTags,
                            countryCode: metadata.countryCode ?? photo.countryCode,
                            gpsLatitude: metadata.gpsLatitude ?? photo.gpsLatitude,
                            gpsLongitude: metadata.gpsLongitude ?? photo.gpsLongitude,
                            enrichedFileDate: modDate ?? Date(),
                            faceRegions: metadata.faceRegions.isEmpty ? photo.faceRegions : metadata.faceRegions
                        )
                    }
                }
                var collected: [EnrichedResult] = []
                for await item in group {
                    if let item { collected.append(item) }
                    onProgress?(collected.count, staleTotal)
                    if collected.count % 5000 == 0 {
                        Log.enrich.info("Processed \(collected.count)/\(staleIndices.count)…")
                    }
                }
                return collected
            }

            var dateCount = 0
            var tagCount = 0
            var uniquePaths = Set<String>()
            var regionPhotoCount = 0
            var regionCount = 0
            var namedRegionCount = 0
            var regionNamesSeen = Set<String>()
            for enriched in batchResults {
                result[enriched.index].dateTaken = enriched.dateTaken
                result[enriched.index].dateFromMetadata = enriched.dateFromMetadata
                result[enriched.index].hierarchicalTags = enriched.hierarchicalTags
                result[enriched.index].countryCode = enriched.countryCode
                result[enriched.index].gpsLatitude = enriched.gpsLatitude
                result[enriched.index].gpsLongitude = enriched.gpsLongitude
                result[enriched.index].enrichedFileDate = enriched.enrichedFileDate
                result[enriched.index].faceRegions = enriched.faceRegions
                if enriched.dateTaken != nil { dateCount += 1 }
                if !enriched.hierarchicalTags.isEmpty {
                    tagCount += 1
                    for tag in enriched.hierarchicalTags { uniquePaths.insert(tag.fullPath.lowercased()) }
                }
                if !enriched.faceRegions.isEmpty {
                    regionPhotoCount += 1
                    regionCount += enriched.faceRegions.count
                    for region in enriched.faceRegions {
                        if let name = region.name, !name.isEmpty {
                            namedRegionCount += 1
                            regionNamesSeen.insert(name)
                        }
                    }
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            Log.enrich.info("Done in \(String(format: "%.1f", elapsed))s: \(dateCount) EXIF dates, \(tagCount) photos with tags, \(uniquePaths.count) unique tag paths")
            Log.enrich.info("Face regions: \(regionCount) on \(regionPhotoCount) photos (\(namedRegionCount) named, \(regionNamesSeen.count) unique names)")
            if regionCount == 0 {
                Log.enrich.warning("No MWG regions found — Person rail will fall back to center-crop. Check that your XMP has <mwg-rs:RegionInfo> blocks.")
            } else {
                let sampleNames = regionNamesSeen.prefix(8).joined(separator: ", ")
                Log.enrich.debug("Sample region names: \(sampleNames)")
            }
            let sampleTags = result.flatMap(\.hierarchicalTags).prefix(20)
            if !sampleTags.isEmpty {
                let tagDetails = sampleTags.map { "\($0.fullPath) → ns:\($0.namespace ?? "nil") name:\($0.displayName)" }
                Log.enrich.debug("Sample hierarchical tags:\n  \(tagDetails.joined(separator: "\n  "))")
            }
            return result
        }.value
    }
}
