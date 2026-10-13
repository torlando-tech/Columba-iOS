import Foundation

/// Both process hosts read one immutable Python payload from the containing app.
/// Native frameworks belong at the top app level, outside the extension bundle.
enum NodePythonBundleLayout {
    enum LayoutError: Error { case missingContainingApp }

    static func resourceBundleURL(for processBundleURL: URL) throws -> URL {
        let process = processBundleURL.standardizedFileURL
        if process.pathExtension == "app" { return process }
        let plugins = process.deletingLastPathComponent()
        let app = plugins.deletingLastPathComponent()
        guard process.pathExtension == "appex", plugins.lastPathComponent == "PlugIns",
              app.pathExtension == "app" else { throw LayoutError.missingContainingApp }
        return app
    }
}
