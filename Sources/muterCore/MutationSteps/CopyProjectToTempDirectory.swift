import Foundation

class CopyProjectToTempDirectory: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.process)
    private var process: ProcessFactory

    private let moduleCacheDirectoryName = "ModuleCache"

    /// Directory names that must NOT be carried into the mutated copy:
    ///   - `.build`, `build`, `DerivedData`: build outputs whose
    ///     precompiled module caches embed absolute paths from the
    ///     original project root and break compilation in the copy.
    ///   - `.swiftpm`: per-workspace SwiftPM state that points at the
    ///     original project; SwiftPM regenerates it inside the copy.
    ///   - `.git`: muter does not need the working-tree's git metadata,
    ///     and pulling it along increases copy cost noticeably on
    ///     long-lived repos.
    /// `Package.resolved` is preserved at the top level so the copy
    /// resolves to identical dependency versions without going to the
    /// network.
    private static let excludedDirectoryNames: Set<String> = [
        ".build",
        ".swiftpm",
        "build",
        "DerivedData",
        ".git",
    ]

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        do {
            notificationCenter.post(
                name: .projectCopyStarted,
                object: nil
            )

            // The project is live while it is copied: build tools create and
            // delete lock and temporary files at any moment, and one vanishing
            // mid-copy used to abort the whole run. The filtered copy skips
            // build artifacts, and the tolerance covers any file that still
            // vanishes. The shared file manager's delegate is restored afterwards.
            var manager = fileManager
            let previousDelegate = manager.delegate
            let tolerance = VanishedFileTolerance()
            manager.delegate = tolerance
            defer { manager.delegate = previousDelegate }

            // `delegate` is weak, and `tolerance` isn't used after this, so its lifetime
            // is extended explicitly to cover the copy.
            try withExtendedLifetime(tolerance) {
                try copyProjectFiltered(
                    from: state.projectDirectoryURL,
                    to: state.mutatedProjectDirectoryURL
                )
            }

            if !tolerance.skippedPaths.isEmpty {
                notificationCenter.post(
                    name: .projectCopySkippedVanishedFiles,
                    object: tolerance.skippedPaths
                )
            }

            discardModuleCaches(in: state.mutatedProjectDirectoryURL)

            notificationCenter.post(
                name: .projectCopyFinished,
                object: state.mutatedProjectDirectoryURL.path
            )

            return []
        } catch {
            throw MuterError.projectCopyFailed(
                reason: error.localizedDescription
            )
        }
    }

    /// Clang module caches record the absolute path they were built under. Copied into the sandbox they
    /// no longer match where they now live, and every compile in the copy fails with
    /// `precompiled file … was compiled with module cache path …` followed by
    /// `missing required module 'SwiftShims'`. The filtered copy already skips the usual build
    /// directories (`excludedDirectoryNames`); this removes any cache that still came along inside a
    /// build directory with another name, such as a custom SwiftPM `--scratch-path`. The compiler
    /// rebuilds the caches in place on the next compile.
    private func discardModuleCaches(in directory: URL) {
        let caches = process()
            .find(atPath: directory.path, byName: moduleCacheDirectoryName)?
            .split(separator: "\n")
            .map(String.init) ?? []

        for cache in caches {
            try? fileManager.removeItem(atPath: cache)
        }
    }

    /// Walks `source` and reproduces it under `destination`, omitting
    /// the well-known build-artifact directories listed in
    /// `excludedDirectoryNames`. Equivalent to
    /// `FileManager.copyItem(atPath:toPath:)` on the relevant payload
    /// but a) avoids the stale-path / re-extraction failure modes of
    /// copying `.build`, b) skips git/swiftpm bookkeeping that the
    /// sandbox doesn't need.
    ///
    /// Uses `FileManager.default.enumerator` directly because the
    /// `FileSystemManager` protocol does not surface enumerator-based
    /// traversal; the actual create / copy operations still go through
    /// the injected `fileManager` so they remain mockable in tests.
    private func copyProjectFiltered(
        from source: URL,
        to destination: URL
    ) throws {
        try fileManager.createDirectory(
            atPath: destination.path,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let raw = FileManager.default
        guard let enumerator = raw.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else {
            throw NSError(
                domain: "Muter.CopyProjectToTempDirectory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not enumerate source: \(source.path)"]
            )
        }

        let sourceRoot = source.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            // Drop the entire subtree rooted at any excluded directory.
            if Self.excludedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            let isDirectory: Bool = {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
                    return false
                }
                return values.isDirectory ?? false
            }()

            // Build the destination path by replacing the source-root
            // prefix; this preserves the relative tree under `destination`.
            let absolute = url.standardizedFileURL.path
            guard absolute.hasPrefix(sourceRoot + "/") else { continue }
            let relative = String(absolute.dropFirst(sourceRoot.count + 1))
            let target = destination.appendingPathComponent(relative).path

            if isDirectory {
                try fileManager.createDirectory(
                    atPath: target,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } else {
                try fileManager.copyItem(
                    atPath: url.path,
                    toPath: target
                )
            }
        }
    }
}

/// Lets a recursive copy continue past files that disappear after the copy has
/// enumerated them. Every other error, a permission failure included, still
/// stops the copy.
final class VanishedFileTolerance: NSObject, FileManagerDelegate {
    private(set) var skippedPaths: [String] = []

    func fileManager(
        _ fileManager: FileManager,
        shouldProceedAfterError error: Error,
        copyingItemAtPath srcPath: String,
        toPath dstPath: String
    ) -> Bool {
        guard Self.isNoSuchFile(error) else {
            return false
        }

        skippedPaths.append(srcPath)
        return true
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError

        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return true
        default:
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return isNoSuchFile(underlying)
            }
            return false
        }
    }
}
