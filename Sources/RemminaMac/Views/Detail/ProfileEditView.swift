import SwiftUI

/// Sheet view for creating or editing a connection profile.
struct ProfileEditView: View {
    enum Mode {
        case create
        case edit(ConnectionProfile)
    }

    let mode: Mode
    let onSave: (ConnectionProfile, String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var protocolType: ProtocolType = .ssh
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var passwordDirty = false  // Track if user actually modified password
    @State private var domain = ""
    @State private var notes = ""
    @State private var tagsText = ""
    @State private var isFavorite = false
    @State private var connectOnOpen = false
    @State private var sshKeyPath = ""
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var title: String {
        isEditing ? "Edit Profile" : "New Profile"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(20)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic info
                    GroupBox("Connection") {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Name")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                TextField("My Server", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Profile Name")
                            }

                            HStack {
                                Text("Protocol")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Picker("Protocol", selection: $protocolType) {
                                    ForEach(ProtocolType.allCases) { proto in
                                        Label(proto.displayName, systemImage: proto.iconName)
                                            .tag(proto)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: protocolType) { oldValue, newValue in
                                    // Update the port when it is empty, invalid,
                                    // or still the *previous* protocol's default
                                    // (so SSH→VNC moves 22→5900). A custom port
                                    // the user typed is left untouched.
                                    if port.isEmpty || Int(port) == nil || Int(port) == oldValue.defaultPort {
                                        port = "\(newValue.defaultPort)"
                                    }
                                }
                            }

                            HStack {
                                Text("Host")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                TextField("192.168.1.100 or hostname", text: $host)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Host Address")
                            }

                            HStack {
                                Text("Port")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                TextField("\(protocolType.defaultPort)", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Port")
                                    .frame(width: 100)
                                Spacer()
                            }
                        }
                        .padding(8)
                    }

                    // Authentication
                    GroupBox("Authentication") {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Username")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                TextField("user", text: $username)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Username")
                            }

                            HStack {
                                Text("Password")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                SecureField(isEditing ? "Leave blank to keep current" : "Optional", text: $password)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Password")
                                    .onChange(of: password) { _, _ in
                                        passwordDirty = true
                                    }
                            }

                            if protocolType == .rdp {
                                HStack {
                                    Text("Domain")
                                        .frame(width: 80, alignment: .trailing)
                                        .accessibilityHidden(true)
                                    TextField("Optional", text: $domain)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Domain")
                                }
                            }

                            if protocolType == .ssh {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("SSH Key")
                                            .frame(width: 80, alignment: .trailing)

                                        if sshKeyPath.isEmpty {
                                            Text("Using SSH agent (default)")
                                                .foregroundStyle(.tertiary)
                                                .font(.caption)
                                        } else {
                                            Text(shortenedPath(sshKeyPath))
                                                .font(.system(.caption, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(sshKeyPath)
                                        }

                                        Spacer()

                                        Button("Browse…") {
                                            browseSSHKey()
                                        }
                                        .controlSize(.small)

                                        if !sshKeyPath.isEmpty {
                                            Button(action: { sshKeyPath = "" }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Clear key and use SSH agent")
                                            .accessibilityLabel("Clear SSH Key")
                                        }
                                    }

                                    HStack {
                                        Spacer().frame(width: 80)
                                        Text("Common locations: ~/.ssh/id_rsa, ~/.ssh/id_ed25519")
                                            .font(.caption2)
                                            .foregroundStyle(.quaternary)
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }

                    // Organization
                    GroupBox("Organization") {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Tags")
                                    .frame(width: 80, alignment: .trailing)
                                    .accessibilityHidden(true)
                                TextField("web, production, staging (comma-separated)", text: $tagsText)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Tags")
                            }

                            HStack {
                                Spacer().frame(width: 80)
                                Toggle("Favorite", isOn: $isFavorite)
                                Spacer()
                            }

                            HStack {
                                Spacer().frame(width: 80)
                                Toggle("Connect on open", isOn: $connectOnOpen)
                                Spacer()
                            }
                        }
                        .padding(8)
                    }

                    // Notes
                    GroupBox("Notes") {
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 60, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .accessibilityLabel("Notes")
                    }
                }
                .padding(20)
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { saveProfile() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || host.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .onAppear { loadProfile() }
        .alert("Invalid Profile", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Helpers

    private func loadProfile() {
        if case .edit(let profile) = mode {
            name = profile.name
            protocolType = profile.protocolType
            host = profile.host
            port = "\(profile.port)"
            username = profile.username
            domain = profile.domain
            notes = profile.notes
            tagsText = profile.tags.joined(separator: ", ")
            isFavorite = profile.isFavorite
            connectOnOpen = profile.connectOnOpen
            sshKeyPath = profile.sshKeyPath
            passwordDirty = false  // Reset dirty flag for edit mode
        } else {
            port = "\(protocolType.defaultPort)"
        }
    }

    private func saveProfile() {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let draft = ProfileDraft(
            name: name,
            protocolType: protocolType,
            host: host,
            portText: port,
            username: username,
            domain: domain,
            notes: notes,
            tags: tags,
            isFavorite: isFavorite,
            connectOnOpen: connectOnOpen,
            sshKeyPath: sshKeyPath
        )

        do {
            let valid = try draft.validated()
            let passwordToSave: String? = passwordDirty ? password : nil

            switch mode {
            case .create:
                onSave(valid.makeProfile(), password.isEmpty ? nil : password)
            case .edit(let profile):
                valid.apply(to: profile)
                onSave(profile, passwordToSave)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingErrorAlert = true
        }
    }

    private func browseSSHKey() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.message = "Choose your SSH private key file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true  // SSH keys are often in hidden .ssh dir
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.treatsFilePackagesAsDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The user just chose this file from an NSOpenPanel, so it's
        // explicitly user-selected. Validate with `isUserSelected: true` so
        // the key can live anywhere (not just ~/.ssh) but still gets the
        // dangerous-prefix check on any symlink chain.
        do {
            let validated = try SSHKeyValidator.validate(url.path, isUserSelected: true)
            sshKeyPath = validated
        } catch {
            let alert = NSAlert()
            alert.messageText = "Invalid SSH key"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
