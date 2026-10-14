import Foundation

/// True when a run points `GRANNY_HOSTS_FILE` at something other than the real
/// hosts file: a sandboxed run, which must write *that* file as the user and
/// must never escalate.
///
/// The escalation paths exist to write `/etc/hosts` - the very thing the
/// override is there to prevent - and sudo does not pass the override
/// through, so a sandboxed run that went through the installed root helper
/// wrote the real file while believing it was sandboxed.
public func isSandboxedHostsRun(
    override: String?,
    realHostsPath: String = "/etc/hosts"
) -> Bool {
    guard let override, !override.isEmpty else { return false }
    return override != realHostsPath
}
