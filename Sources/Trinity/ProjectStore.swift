import Foundation

final class ProjectStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let projectsFile: URL

    init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.projectsFile = home.appendingPathComponent(".trinity/projects.json")
    }

    func listProjects() -> [String] {
        guard let data = try? Data(contentsOf: projectsFile),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return paths
    }

    func addProject(_ rawPath: String) throws -> [String] {
        let url = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Trinity.ProjectStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "not a directory: \(url.path)"
            ])
        }
        var projects = listProjects()
        if !projects.contains(url.path) {
            projects.append(url.path)
            try save(projects)
        }
        return projects
    }

    func removeProject(_ rawPath: String) throws -> [String] {
        let url = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL
        let projects = listProjects().filter { $0 != url.path }
        try save(projects)
        return projects
    }

    private func save(_ projects: [String]) throws {
        let dir = projectsFile.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(projects)
        try data.write(to: projectsFile)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
