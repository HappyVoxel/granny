import Foundation

/// Every environment seam in one place: the e2e suites set these to sandbox
/// a system interaction, and code reads the constant instead of a literal.
public enum GrannyEnv {
    public static let configFile = "GRANNY_CONFIG_FILE"
    public static let stateDir = "GRANNY_STATE_DIR"
    public static let hostsFile = "GRANNY_HOSTS_FILE"
    public static let allowNonRoot = "GRANNY_ALLOW_NONROOT"
    public static let skipDNSFlush = "GRANNY_SKIP_DNS_FLUSH"
    public static let traceDebug = "GRANNY_TRACE_DEBUG"
    public static let osaCmd = "GRANNY_OSA_CMD"
    public static let sudo = "GRANNY_SUDO"
    public static let launchctl = "GRANNY_LAUNCHCTL"
    public static let launchAgent = "GRANNY_LAUNCH_AGENT"
    public static let user = "GRANNY_USER"
    public static let showWindow = "GRANNY_SHOW_WINDOW"
}
