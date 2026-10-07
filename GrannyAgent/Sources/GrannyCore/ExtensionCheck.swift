import Foundation

/// Whether granny's browser extensions are installed. The hosts block
/// cannot see what a tab holds, so the extension is what turns "closed"
/// into "watched"; when neither browser carries it, the app says so.
public enum ExtensionCheck {
    /// The install guide the app links to; screenshots per browser.
    public static let guideURL = URL(string: "https://granny.happyvoxel.com/blog/install-extension/")!

    /// Safari web extensions register with the system; `pluginkit` lists
    /// them. The runner is injected so tests never call the real tool.
    public static func safari(run: (String, [String]) -> String?) -> Bool {
        let output = run("/usr/bin/pluginkit", ["-m", "-p", "com.apple.Safari.web-extension"]) ?? ""
        return output.contains(safariExtensionID)
    }

    public static let safariExtensionID = "io.github.happyvoxel.granny.safari"

    /// Chromium-family browsers keep their extension list in the profile's
    /// preferences. Our unpacked folder's name in there is the proof; the
    /// path may be JSON-escaped, so only the folder name is searched.
    ///
    /// nil means "cannot tell": macOS can deny reading another browser's
    /// profile (TCC), and a wrong "not installed" would nag a user who
    /// already loaded the extension. Unknown is treated as installed.
    public static func chromium(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        browserDirs: [String] = defaultBrowserDirs,
        folderNames: [String] = unpackedFolderNames
    ) -> Bool? {
        var sawBrowser = false
        for dir in browserDirs {
            let root = home.appendingPathComponent("Library/Application Support/\(dir)")
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            sawBrowser = true
            guard let profiles = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return nil }
            for profile in profiles {
                for file in ["Preferences", "Secure Preferences"] {
                    let url = profile.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: url),
                          let text = String(data: data, encoding: .utf8)
                    else { continue }
                    if folderNames.contains(where: { text.contains($0) }) { return true }
                }
            }
        }
        // No browser at all: nothing to install into, and nothing to nag.
        return sawBrowser ? false : nil
    }

    /// The folders the extension can be loaded from: the one the installer
    /// script prints, and the in-app copy.
    public static let unpackedFolderNames = ["granny-extension", "granny-chrome"]

    public static let defaultBrowserDirs = [
        "Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge",
        "Arc", "Chromium", "Vivaldi", "com.operasoftware.Opera",
    ]
}
