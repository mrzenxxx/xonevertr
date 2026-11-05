import Foundation

public struct PlannedConversion: Sendable {
    public let source: URL
    public let destination: URL
    public init(source: URL, destination: URL) { self.source = source; self.destination = destination }
}

public enum QueuePlanner {
    /// Plans without creating directories or changing any input. Existing destinations are never reused.
    public static func discover(_ inputs: [URL], output: URL?, reserved: Set<URL> = [], isCancelled: @Sendable () -> Bool = { false }) throws -> [PlannedConversion] {
        let fm = FileManager.default
        var seen = Set<String>()
        var taken = Set(reserved.map { key($0) })
        var jobs: [PlannedConversion] = []
        var directoryNames: [String: Set<String>] = [:]
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        func append(_ source: URL, directory: URL) throws {
            try checkCancellation()
            guard source.pathExtension.lowercased() == "flac", !source.lastPathComponent.hasPrefix("."),
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return }
            guard seen.insert(source.resolvingSymlinksInPath().path).inserted else { return }
            let stem = source.deletingPathExtension().lastPathComponent
            var index = 1
            var destination = directory.appendingPathComponent(stem + ".wav")
            let existingNames: Set<String>
            if let cached = directoryNames[key(directory)] { existingNames = cached }
            else {
                existingNames = fm.fileExists(atPath: directory.path)
                    ? Set(try fm.contentsOfDirectory(atPath: directory.path).map { $0.precomposedStringWithCanonicalMapping.lowercased() }) : []
                directoryNames[key(directory)] = existingNames
            }
            while taken.contains(key(destination)) || existingNames.contains(destination.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()) {
                index += 1
                destination = directory.appendingPathComponent("\(stem) (\(index)).wav")
            }
            taken.insert(key(destination))
            jobs.append(PlannedConversion(source: source, destination: destination))
        }
        // Process ancestors first so overlap keeps the chosen directory structure.
        let sortedInputs = inputs.enumerated().sorted { a, b in
            let depthA = a.element.resolvingSymlinksInPath().pathComponents.count
            let depthB = b.element.resolvingSymlinksInPath().pathComponents.count
            return depthA == depthB ? a.offset < b.offset : depthA < depthB
        }.map(\.element)
        for input in sortedInputs {
            try checkCancellation()
            let input = input.standardizedFileURL
            let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                var enumerationError: (any Error)?
                guard let enumerator = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw CocoaError(.fileReadUnknown) }
                var files: [URL] = []
                for case let file as URL in enumerator { try checkCancellation(); files.append(file) }
                files.sort { $0.path < $1.path }
                if let enumerationError { throw enumerationError }
                for source in files {
                    let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    let relative = source.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.dropFirst(input.resolvingSymlinksInPath().pathComponents.count)
                    let base = output ?? input.deletingLastPathComponent().appendingPathComponent(input.lastPathComponent + " WAV")
                    let directory = output != nil ? base : relative.reduce(base) { $0.appendingPathComponent($1) }
                    try append(source, directory: directory)
                }
            } else {
                let parent = input.deletingLastPathComponent()
                let directory = output ?? parent.deletingLastPathComponent().appendingPathComponent(parent.lastPathComponent + " WAV")
                try append(input, directory: directory)
            }
        }
        return jobs
    }
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
