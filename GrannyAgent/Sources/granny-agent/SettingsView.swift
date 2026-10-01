import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GrannyCore

/// BYOK settings: the grandchild pastes their own keys here. Everything is
/// stored in ~/.config/granny/config.json (mode 600), nothing leaves the Mac
/// except the calls the app itself makes.
struct SettingsView: View {
    let config: GrannyConfig
    var onSave: (GrannyConfig) -> Void
    var onCancel: () -> Void

    @State private var openRouterKey: String
    @State private var model: String
    @State private var layaURL: String
    @State private var layaKey: String
    @State private var jevURL: String
    @State private var jevKey: String
    @State private var jevModel: String
    @State private var langfuseHost: String
    @State private var langfusePublic: String
    @State private var langfuseSecret: String
    @State private var speechEnabled: Bool
    @State private var wakeHour: Int
    @State private var bedtimeHour: Int
    @State private var language: String
    @State private var appearance: String
    @State private var entertainmentApps: [String]
    @State private var blockedDomains: [String]
    @State private var allowedSites: [String]
    @State private var newBlockedSite = ""
    @State private var newAllowedSite = ""
    @State private var appsExpanded = false
    @State private var blockedExpanded = false
    @State private var allowedExpanded = false

    init(config: GrannyConfig, onSave: @escaping (GrannyConfig) -> Void, onCancel: @escaping () -> Void) {
        self.config = config
        self.onSave = onSave
        self.onCancel = onCancel
        _openRouterKey = State(initialValue: config.openRouterKey ?? "")
        _model = State(initialValue: config.model)
        _layaURL = State(initialValue: config.layaURL ?? "")
        _layaKey = State(initialValue: config.layaKey ?? "")
        _jevURL = State(initialValue: config.jevURL ?? "")
        _jevKey = State(initialValue: config.jevKey ?? "")
        _jevModel = State(initialValue: config.jevModel)
        _langfuseHost = State(initialValue: config.langfuse?.baseURL ?? "")
        _langfusePublic = State(initialValue: config.langfuse?.publicKey ?? "")
        _langfuseSecret = State(initialValue: config.langfuse?.secretKey ?? "")
        _speechEnabled = State(initialValue: config.speechEnabled)
        _wakeHour = State(initialValue: config.wakeHour)
        _bedtimeHour = State(initialValue: config.bedtimeHour)
        _language = State(initialValue: (GrannyLanguage(code: config.language) ?? .en).rawValue)
        _appearance = State(initialValue: GrannyAppearance.resolve(config.appearance).rawValue)
        _entertainmentApps = State(initialValue: config.entertainmentApps)
        _blockedDomains = State(initialValue: config.blockedDomains)
        _allowedSites = State(initialValue: config.alwaysAllowedURLPrefixes)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    card(GrannyLines.settingsAIGroup, caption: GrannyLines.settingsAICaption) {
                        secretField(
                            GrannyLines.settingsOpenRouterKey,
                            $openRouterKey,
                            validate: { key in await KeyCheck.openRouter(key: key) })
                        labeledField(GrannyLines.settingsModel, $model)
                    }

                    card(GrannyLines.settingsClassifierGroup, caption: GrannyLines.settingsClassifierCaption) {
                        labeledField(GrannyLines.settingsLayaURL, $layaURL)
                        secretField(
                            GrannyLines.settingsLayaKey,
                            $layaKey,
                            validate: { key in await KeyCheck.systemOne(baseURL: layaURL, key: key) })
                        labeledField(GrannyLines.settingsJevModel, $jevModel)
                        labeledField(GrannyLines.settingsJevURL, $jevURL)
                        secretField(
                            GrannyLines.settingsJevKey,
                            $jevKey,
                            validate: jevURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : { key in await KeyCheck.systemOne(baseURL: jevURL, key: key) })
                    }

                    card(GrannyLines.settingsTracingGroup) {
                        labeledField(GrannyLines.settingsHost, $langfuseHost)
                        secretField(GrannyLines.settingsPublicKey, $langfusePublic)
                        secretField(GrannyLines.settingsSecretKey, $langfuseSecret)
                    }

                    card(GrannyLines.settingsLanguageGroup, caption: GrannyLines.settingsLanguageCaption) {
                        Picker(GrannyLines.settingsSpeaksLabel, selection: $language) {
                            ForEach(GrannyLanguage.allCases, id: \.rawValue) { lang in
                                Text(lang.displayName).tag(lang.rawValue)
                            }
                        }
                        .pointingHandOnHover()
                    }

                    card(GrannyLines.settingsAppearanceGroup, caption: GrannyLines.appearanceHint) {
                        Picker(GrannyLines.settingsThemeLabel, selection: $appearance) {
                            Text(GrannyLines.settingsThemeSystem).tag(GrannyAppearance.system.rawValue)
                            Text(GrannyLines.settingsThemeDark).tag(GrannyAppearance.dark.rawValue)
                            Text(GrannyLines.settingsThemeLight).tag(GrannyAppearance.light.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .pointingHandOnHover()
                    }

                    card(GrannyLines.settingsDayGroup) {
                        Stepper(
                            "\(GrannyLines.settingsWakeHour): \(wakeHour)",
                            value: $wakeHour,
                            in: 0...max(0, min(22, bedtimeHour - 1)))
                            .pointingHandOnHover()
                        Stepper(
                            "\(GrannyLines.settingsBedtime): \(bedtimeHour)",
                            value: $bedtimeHour,
                            in: min(23, wakeHour + 1)...23)
                            .pointingHandOnHover()
                        Toggle(GrannyLines.settingsSpeechToggle, isOn: $speechEnabled)
                            .pointingHandOnHover()
                    }

                    card(GrannyLines.settingsListsGroup) {
                        watchlistSection(
                            GrannyLines.settingsAppsLabel,
                            count: entertainmentApps.count,
                            expanded: $appsExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(GrannyLines.settingsAppsCaption)
                                    .font(.caption2).foregroundStyle(captionStyle)
                                ForEach(entertainmentApps, id: \.self) { bundleID in
                                    listRow(title: appName(for: bundleID), detail: bundleID) {
                                        entertainmentApps.removeAll { $0 == bundleID }
                                    }
                                }
                                Button(GrannyLines.settingsAppsAdd) { pickApp() }
                                    .buttonStyle(GrannySecondaryButtonStyle())
                            }
                        }

                        hairline

                        watchlistSection(
                            GrannyLines.settingsBlockedSitesLabel,
                            count: HostList.displayHosts(blockedDomains).count,
                            expanded: $blockedExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(HostList.displayHosts(blockedDomains), id: \.self) { host in
                                    listRow(title: host, detail: nil) {
                                        blockedDomains = HostList.removing(host: host, from: blockedDomains)
                                    }
                                }
                                addSiteRow(text: $newBlockedSite) {
                                    addSite($0, to: &blockedDomains, prefix: "")
                                }
                            }
                        }

                        hairline

                        watchlistSection(
                            GrannyLines.settingsAllowedSitesLabel,
                            count: HostList.displayHosts(allowedSites).count,
                            expanded: $allowedExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(GrannyLines.settingsAllowedSitesCaption)
                                    .font(.caption2).foregroundStyle(captionStyle)
                                ForEach(HostList.displayHosts(allowedSites), id: \.self) { host in
                                    listRow(title: host, detail: nil) {
                                        allowedSites = HostList.removing(host: host, from: allowedSites)
                                    }
                                }
                                addSiteRow(text: $newAllowedSite) {
                                    addSite($0, to: &allowedSites, prefix: "https://")
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Rectangle().fill(GrannyTheme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button(GrannyLines.cancelButton) { onCancel() }
                    .buttonStyle(GrannySecondaryButtonStyle())
                Button(GrannyLines.settingsSave) { onSave(build()) }
                    .buttonStyle(GrannyPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .grannyWindowBackdrop()
        .foregroundStyle(GrannyTheme.text)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 460, idealHeight: 660)
    }

    private var captionStyle: Color { GrannyTheme.text.opacity(0.55) }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text("granny")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(GrannyTheme.gold)
                Text(GrannyLines.settingsSubtitle)
                    .font(.caption).foregroundStyle(captionStyle)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var hairline: some View {
        Rectangle().fill(GrannyTheme.hairline).frame(height: 1)
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(GrannyTheme.gold)
            VStack(alignment: .leading, spacing: 8) { content() }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(captionStyle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .grannyCard(cornerRadius: 12)
    }

    /// Hand-rolled disclosure header: the whole row (chevron included) is one
    /// button, so the pointing hand covers exactly what a click toggles.
    @ViewBuilder
    private func watchlistSection<Content: View>(
        _ title: String,
        count: Int,
        expanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GrannyTheme.gold)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                    Spacer()
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(captionStyle)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(GrannyTheme.background))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            if expanded.wrappedValue {
                content()
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(captionStyle)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func secretField(
        _ label: String,
        _ text: Binding<String>,
        validate: ((String) async -> KeyCheckResult)? = nil
    ) -> some View {
        SecretField(label: label, text: text, validate: validate)
    }

    @ViewBuilder
    private func listRow(title: String, detail: String?, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail, detail != title {
                    Text(detail).font(.caption2).foregroundStyle(captionStyle)
                }
            }
            Spacer()
            RemoveButton(action: onRemove)
        }
    }

    @ViewBuilder
    private func addSiteRow(text: Binding<String>, onAdd: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(GrannyLines.settingsSitePlaceholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitSite(text, onAdd: onAdd) }
            Button(GrannyLines.settingsAddSite) { submitSite(text, onAdd: onAdd) }
                .buttonStyle(GrannySecondaryButtonStyle())
        }
    }

    private func submitSite(_ text: Binding<String>, onAdd: (String) -> Void) {
        let input = text.wrappedValue
        text.wrappedValue = ""
        onAdd(input)
    }

    private func addSite(_ input: String, to entries: inout [String], prefix: String) {
        guard let host = HostList.normalize(input) else { return }
        for entry in HostList.entries(forHost: host, prefix: prefix) where !entries.contains(entry) {
            entries.append(entry)
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        if !entertainmentApps.contains(bundleID) {
            entertainmentApps.append(bundleID)
        }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundleID
        }
        return GrannyConfig.defaultEntertainmentAppNames[bundleID] ?? bundleID
    }

    private func build() -> GrannyConfig {
        var updated = config

        let key = openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.openRouterKey = key.isEmpty ? nil : key
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = modelName.isEmpty ? GrannyConfig.default.model : modelName

        let laya = layaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let layaSecret = layaKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.layaURL = laya.isEmpty ? nil : laya
        updated.layaKey = layaSecret.isEmpty ? nil : layaSecret

        let jev = jevURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let jevSecret = jevKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.jevURL = jev.isEmpty ? nil : jev
        updated.jevKey = jevSecret.isEmpty ? nil : jevSecret
        let jevModelName = jevModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.jevModel = jevModelName.isEmpty ? GrannyConfig.default.jevModel : jevModelName

        let host = langfuseHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = langfusePublic.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = langfuseSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !publicKey.isEmpty, !secretKey.isEmpty {
            updated.langfuse = LangfuseConfig(
                baseURL: host.isEmpty ? GrannyConfig.defaultLangfuseBaseURL : host,
                publicKey: publicKey,
                secretKey: secretKey)
        } else {
            updated.langfuse = nil
        }

        updated.speechEnabled = speechEnabled
        updated.wakeHour = wakeHour
        updated.bedtimeHour = bedtimeHour
        updated.language = language
        updated.appearance = appearance
        updated.entertainmentApps = entertainmentApps
        updated.blockedDomains = blockedDomains
        updated.alwaysAllowedURLPrefixes = allowedSites
        return updated
    }
}

/// One secret row: label, reveal eye, and - when the provider gives a
/// `validate` closure - a live verdict once the paste settles: green check,
/// red cross, gray question for unreachable. New providers reuse this row
/// unchanged; only the closure differs.
private struct SecretField: View {
    let label: String
    @Binding var text: String
    var validate: ((String) async -> KeyCheckResult)?

    @State private var revealed = false
    @State private var eyeHovering = false
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case checking
        case verdict(KeyCheckResult)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 130, alignment: .trailing)
                .foregroundStyle(GrannyTheme.text.opacity(0.55))

            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .foregroundStyle(GrannyTheme.text)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(eyeHovering ? GrannyTheme.gold : GrannyTheme.text.opacity(0.45))
                        .padding(4)
                        .background(Circle().fill(GrannyTheme.gold.opacity(eyeHovering ? 0.14 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(revealed ? GrannyLines.secretHide : GrannyLines.secretShow)
                .onHover { eyeHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: eyeHovering)
                .pointingHandOnHover()

                statusBadge
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(GrannyTheme.background.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(GrannyTheme.hairline))
        }
        .task(id: text) { await runCheck() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Group {
            switch status {
            case .idle:
                Color.clear
            case .checking:
                ProgressView().controlSize(.mini)
            case .verdict(.valid):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(GrannyLines.keyCheckValid)
            case .verdict(.invalid):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(GrannyLines.keyCheckInvalid)
            case .verdict(.unreachable):
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(GrannyTheme.text.opacity(0.45))
                    .help(GrannyLines.keyCheckUnreachable)
            }
        }
        .frame(width: 14)
    }

    /// Runs on appear and after every edit: a stored key earns its tick as
    /// soon as Settings opens, and a paste is checked once typing settles.
    private func runCheck() async {
        guard let validate else { status = .idle; return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = .idle; return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        status = .checking
        let result = await validate(value)
        guard !Task.isCancelled else { return }
        status = .verdict(result)
    }
}

/// Trash icon that wakes up on hover: gold, pointing hand, a soft pad - a
/// watchlist row's remove control should not look decorative.
private struct RemoveButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(hovering ? GrannyTheme.gold : GrannyTheme.text.opacity(0.45))
                .padding(4)
                .background(Circle().fill(GrannyTheme.gold.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help(GrannyLines.settingsRemoveEntry)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .background(PointingHandCursor())
        .onHover { hovering = $0 }
    }
}
