import Darwin
import Foundation
import GrannyCore

func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func usage() -> Never {
    print("""
    usage: granny-helper <command> [args]
      render [domains.json]   print the hosts file with the block applied
      strip                   print the hosts file with the block removed
      apply <domains.json>    apply the block (needs root)
      clear                   remove the block (needs root)
      status                  print blocked or clear
    """)
    exit(2)
}

let hostsPath = ProcessInfo.processInfo.environment[GrannyEnv.hostsFile] ?? "/etc/hosts"
let allowNonRoot = ProcessInfo.processInfo.environment[GrannyEnv.allowNonRoot] == "1"

func currentHosts() -> String {
    (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? "127.0.0.1 localhost\n"
}

func domains(from path: String?) -> [String] {
    guard let path,
          let data = FileManager.default.contents(atPath: path),
          let list = JSON.decode([String].self, from: data)
    else { return [] }
    return list
}

func requireRoot() {
    if !allowNonRoot, geteuid() != 0 {
        stderr("granny-helper: this command needs root; run it through sudo.")
        exit(3)
    }
}

func writeHosts(_ content: String) {
    let tmpPath = hostsPath + ".granny.tmp"
    do {
        try Data(content.utf8).write(to: URL(fileURLWithPath: tmpPath))
    } catch {
        stderr("granny-helper: write failed: \(error.localizedDescription)")
        exit(1)
    }
    if chmod(tmpPath, 0o644) != 0 {
        stderr("granny-helper: chmod failed (errno \(errno)); aborting before rename")
        exit(1)
    }
    // Only the root install must end up root:wheel; the non-root e2e sandbox
    // cannot chown and keeps the user's ownership.
    if geteuid() == 0, chown(tmpPath, 0, 0) != 0 {
        stderr("granny-helper: chown failed (errno \(errno)); aborting before rename")
        exit(1)
    }
    if rename(tmpPath, hostsPath) != 0 {
        stderr("granny-helper: rename failed (errno \(errno))")
        exit(1)
    }
}

func flushDNS() {
    // The e2e suites point the helper at a sandbox hosts file; flushing the
    // real resolver cache there is pointless and slow.
    guard ProcessInfo.processInfo.environment[GrannyEnv.skipDNSFlush] != "1" else { return }
    let tools: [(String, [String])] = [
        ("/usr/bin/dscacheutil", ["-flushcache"]),
        ("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
    ]
    for (tool, arguments) in tools {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "render":
    let list = arguments.count > 1
        ? domains(from: arguments[1])
        : GrannyConfig.default.blockedDomains + GrannyConfig.default.dohDomains
    print(HostsFile.render(current: currentHosts(), domains: list), terminator: "")
case "strip":
    print(HostsFile.strip(current: currentHosts()), terminator: "")
case "apply":
    guard arguments.count > 1 else { usage() }
    requireRoot()
    let list = domains(from: arguments[1])
    guard !list.isEmpty else {
        stderr("granny-helper: empty domain list, refusing to write")
        exit(1)
    }
    writeHosts(HostsFile.render(current: currentHosts(), domains: list))
    flushDNS()
    print("block applied")
case "clear":
    requireRoot()
    writeHosts(HostsFile.strip(current: currentHosts()))
    flushDNS()
    print("block cleared")
case "status":
    print(HostsFile.isBlocked(current: currentHosts()) ? "blocked" : "clear")
default:
    usage()
}
