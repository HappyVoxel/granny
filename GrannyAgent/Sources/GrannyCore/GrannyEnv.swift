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
    /// The tool that kills the Private Relay proxy when the block returns
    /// after a break. A separate seam from the e2e suites' `GRANNY_PKILL`
    /// (install-app.sh's shell override), and the one the suites point at a
    /// sentinel so no run can ever signal the real proxy.
    public static let killall = "GRANNY_KILLALL"
    /// Path to the `granny-engine` executable the app spawns as a sidecar.
    /// The e2e engine suite points this at its Node stub.
    public static let enginePath = "GRANNY_ENGINE_PATH"
    /// Path to `<state dir>/engine.sock` passed to the spawned engine child.
    public static let engineSocket = "GRANNY_ENGINE_SOCKET"
    /// Directory override for bundled `Resources/` when resolving
    /// `engine/granny-engine` in tests without building a full `.app` bundle.
    public static let engineResourcesDir = "GRANNY_ENGINE_RESOURCES_DIR"
    /// Directory override for the Pi Durable SQLite store inside `granny-engine`.
    public static let engineStorageDir = "GRANNY_ENGINE_STORAGE_DIR"
    /// Explicit Node.js (>=22.19) executable override forwarded to `granny-engine`.
    public static let node = "GRANNY_NODE"
    /// Endpoint override for OpenRouter chat completions so the e2e engine
    /// suite can stream against a local SSE stub without hitting the network.
    public static let openRouterURL = "GRANNY_OPENROUTER_URL"
    /// Path to a JSON file supplying a canned `device.context` snapshot for
    /// e2e tests so no suite touches the developer's browsers or Calendar.
    public static let deviceContext = "GRANNY_DEVICE_CONTEXT"
}
