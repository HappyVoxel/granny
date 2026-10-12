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
    public static let openTool = "GRANNY_OPEN"
    public static let sudo = "GRANNY_SUDO"
    public static let launchctl = "GRANNY_LAUNCHCTL"
    public static let launchAgent = "GRANNY_LAUNCH_AGENT"
    public static let user = "GRANNY_USER"
    public static let showWindow = "GRANNY_SHOW_WINDOW"
    /// Start a pomodoro round at launch, so a run can watch a whole stage -
    /// the dial draining, the bell, the banner - without a click.
    public static let pomodoroAutostart = "GRANNY_POMODORO_AUTOSTART"
    /// A command to run instead of playing a system sound (it gets the sound
    /// name as its argument), the way `osaCmd` replaces osascript.
    public static let chime = "GRANNY_CHIME"
}
