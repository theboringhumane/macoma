import Foundation
import Darwin

struct TerminalPalette: Codable, Equatable {
    var id: String
    var name: String
    var background: String
    var foreground: String
    var accent: String
    var colors: [String]
    var selectionBackground: String? = nil
    var selectionForeground: String? = nil
    var cursor: String? = nil

    func validated() throws -> Self {
        let values = [background, foreground, accent] + colors + [selectionBackground, selectionForeground, cursor].compactMap { $0 }
        guard colors.count == 16, values.allSatisfy({ value in
            value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
        }) else { throw TerminalFailure("The terminal theme must contain sixteen valid RGB colors.") }
        return self
    }
}

struct TerminalFontSettings: Codable, Equatable {
    var family: String
    var size: Double

    func validate() throws {
        guard !family.isEmpty, family.count <= 120,
              family.allSatisfy({ $0.isLetter || $0.isNumber || " -_().+".contains($0) }),
              size.isFinite, (9...28).contains(size) else {
            throw TerminalFailure("Choose an installed font and a size from 9 to 28 points.")
        }
    }
}

struct TerminalProfileReceipt: Codable, Equatable {
    var generation: String
    var createdAt: Date
    var theme: TerminalPalette
    var font: TerminalFontSettings
    var ghosttyVersion: String
    var profileRevision: Int? = nil
}

struct TerminalProfileState: Codable {
    var version = 1
    var current: String
    var previous: String?
}

struct TerminalFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct TerminalCommandResult {
    let status: Int32
    let output: String
}

enum TerminalProcess {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 15, outputLimit: Int = 1_048_576) throws -> TerminalCommandResult {
        guard timeout > 0, timeout.isFinite, outputLimit > 0 else { throw TerminalFailure("Invalid command execution limits.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw TerminalFailure("Could not prepare command output capture.") }
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while true {
                // Nonblocking reads also handle a child that retains the pipe
                // after its parent exits. No unbounded read-to-EOF wait occurs.
                while true {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        guard data.count + count <= outputLimit else {
                            throw TerminalFailure("\(executable.lastPathComponent) exceeded the command output limit (\(outputLimit) bytes).")
                        }
                        data.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else if errno != EINTR {
                        throw TerminalFailure("Could not read \(executable.lastPathComponent) output.")
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw TerminalFailure("\(executable.lastPathComponent) timed out after \(timeout.formatted()) seconds.")
                    }
                }
                if !process.isRunning { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw TerminalFailure("\(executable.lastPathComponent) timed out after \(timeout.formatted()) seconds.")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            return TerminalCommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            stop(process)
            throw error
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

enum TerminalLaunch {
    static func validationArguments(profile: URL, work: Bool = false) -> [String] {
        // The 1.3.1 helper accepts only --config-file. With that flag it starts
        // from defaults and reads the explicit file, not normal user configs.
        ["+validate-config", "--config-file=\(profile.appendingPathComponent(work ? "ghostty-work.conf" : "ghostty.conf").path)"]
    }

    static func openArguments(app: URL, profile: URL, tmux: URL? = nil) -> [String] {
        var args = ["-na", app.path, "--args", "--config-default-files=false", "--config-file=\(profile.appendingPathComponent(tmux == nil ? "ghostty.conf" : "ghostty-work.conf").path)"]
        if let tmux {
            args += ["--env=MACARCHY_TMUX_BINARY=\(tmux.path)"]
            args += ["-e", "/bin/zsh", profile.appendingPathComponent("work-session.zsh").path, profile.path, tmux.path, "macarchy"]
        }
        return args
    }
}

enum TerminalTmuxProfile {
    // Approximate the cell aspect ratio: columns are about half a row's height.
    static let autoSplitCondition = "#{e|>|:#{pane_width},#{e|*|:#{pane_height},2}}"
    static let autoSplitHorizontal = "split-window -h -c '#{pane_current_path}'"
    static let autoSplitVertical = "split-window -v -c '#{pane_current_path}'"

    static func autoSplitArguments() -> [String] {
        // Like the keyboard binding, this operates on the active pane.
        ["if-shell", "-F", autoSplitCondition, autoSplitHorizontal, autoSplitVertical]
    }

    /// Refresh only the dedicated server. Changing tmux's environment affects
    /// future panes; running shells retain their existing process environment.
    static func apply(binary: URL, profile: URL, socket: String = "macarchy") throws -> Bool {
        guard !socket.isEmpty, socket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw TerminalFailure("Invalid managed tmux socket name.")
        }
        let prefix = ["-L", socket]
        let sessions = try TerminalProcess.run(binary, prefix + ["list-sessions", "-F", "#{session_id}"])
        guard sessions.status == 0 else { return false }
        func run(_ arguments: [String]) throws {
            let result = try TerminalProcess.run(binary, prefix + arguments)
            guard result.status == 0 else { throw TerminalFailure("tmux could not refresh its managed profile: \(result.output)") }
        }
        try run(["source-file", profile.appendingPathComponent("tmux.conf").path])
        let values = [
            ("MACARCHY_MANAGED", "1"),
            ("MACARCHY_TERMINAL_PROFILE", profile.path),
            ("ZDOTDIR", profile.appendingPathComponent("zsh").path),
            ("STARSHIP_CONFIG", profile.appendingPathComponent("starship.toml").path)
        ]
        for (key, value) in values { try run(["set-environment", "-g", key, value]) }
        for session in sessions.output.split(separator: "\n").map(String.init) {
            // Work has session overrides from new-session -e. Update those as
            // well as the global environment used by future managed sessions.
            for (key, value) in values { try run(["set-environment", "-t", session, key, value]) }
        }
        return true
    }
}

/// A complete profile is validated before state.json atomically activates it.
/// Prior generations remain available for restore and for running shells.
struct TerminalProfileStore {
    let root: URL
    private let fm = FileManager.default
    private var marker: URL { root.appendingPathComponent(".macarchy-terminal-owner") }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var profilesURL: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    private let markerText = "Macarchy managed terminal profiles v1\n"

    static var standard: Self {
        Self(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/macarchy/terminal", isDirectory: true))
    }

    func profileURL(_ generation: String) throws -> URL {
        guard UUID(uuidString: generation) != nil else { throw TerminalFailure("The saved terminal profile identifier is invalid.") }
        return profilesURL.appendingPathComponent(generation, isDirectory: true)
    }

    func state() throws -> TerminalProfileState? {
        guard fm.fileExists(atPath: root.path) else { return nil }
        try checkOwnership()
        guard fm.fileExists(atPath: stateURL.path) else { return nil }
        try rejectSymlink(stateURL)
        let state = try JSONDecoder().decode(TerminalProfileState.self, from: Data(contentsOf: stateURL))
        guard state.version == 1 else { throw TerminalFailure("This terminal profile was created by an unsupported Macoma version.") }
        _ = try receipt(state.current)
        return state
    }

    func currentReceipt() throws -> TerminalProfileReceipt? {
        guard let state = try state() else { return nil }
        return try receipt(state.current)
    }

    func receipt(_ generation: String) throws -> TerminalProfileReceipt {
        let directory = try profileURL(generation)
        try rejectSymlink(directory)
        let url = directory.appendingPathComponent("receipt.json")
        try rejectSymlink(url)
        let result = try JSONDecoder().decode(TerminalProfileReceipt.self, from: Data(contentsOf: url))
        guard result.generation == generation else { throw TerminalFailure("The terminal profile receipt does not match its directory.") }
        return result
    }

    func apply(theme: TerminalPalette, font: TerminalFontSettings, ghostty: URL, resources: URL,
               originalZDOTDIR: String? = nil) throws -> TerminalProfileReceipt {
        let theme = try theme.validated()
        try font.validate()
        try prepareRoot()
        let old = try state()
        let generation = UUID().uuidString
        let directory = try profileURL(generation)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var activated = false
        defer { if !activated { try? fm.removeItem(at: directory) } }

        // No external config is imported. All startup files are bundled static scripts.
        for name in ["work-session.zsh", "shell-enhancements.zsh", "zsh"] {
            let source = resources.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { throw TerminalFailure("The app is missing its Terminal/\(name) resource. Rebuild the app bundle.") }
            try fm.copyItem(at: source, to: directory.appendingPathComponent(name))
        }
        let config = try Self.ghosttyConfig(theme: theme, font: font, directory: directory, originalZDOTDIR: originalZDOTDIR)
        try write(config, to: directory.appendingPathComponent("ghostty.conf"))
        let workConfig = try Self.ghosttyConfig(theme: theme, font: font, directory: directory, originalZDOTDIR: originalZDOTDIR, work: true)
        try write(workConfig, to: directory.appendingPathComponent("ghostty-work.conf"))
        try write(Self.tmuxConfig(theme: theme), to: directory.appendingPathComponent("tmux.conf"))
        try write(Self.starshipConfig(theme: theme), to: directory.appendingPathComponent("starship.toml"))
        try validate(directory: directory, ghostty: ghostty)
        let version = try TerminalProcess.run(ghostty, ["--version"])
        guard version.status == 0 else { throw TerminalFailure("Ghostty could not report its version: \(version.output)") }
        let result = TerminalProfileReceipt(generation: generation, createdAt: Date(), theme: theme, font: font,
            ghosttyVersion: version.output.components(separatedBy: .newlines).first ?? "Ghostty", profileRevision: 2)
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        try saveState(TerminalProfileState(current: generation, previous: old?.current))
        activated = true
        return result
    }

    func restore(ghostty: URL) throws -> TerminalProfileReceipt {
        guard let state = try state(), let previous = state.previous else { throw TerminalFailure("There is no previous managed profile to restore.") }
        let result = try receipt(previous)
        try validate(directory: profileURL(previous), ghostty: ghostty)
        try saveState(TerminalProfileState(current: previous, previous: state.current))
        return result
    }

    func validate(directory: URL, ghostty: URL) throws {
        for work in [false, true] {
            let config = directory.appendingPathComponent(work ? "ghostty-work.conf" : "ghostty.conf")
            // Previous app versions had only the ordinary profile. Restore can
            // retain it, but the UI requests Apply before enabling new shortcuts.
            if work && !fm.fileExists(atPath: config.path) { continue }
            try rejectSymlink(config)
            let result = try TerminalProcess.run(ghostty, TerminalLaunch.validationArguments(profile: directory, work: work))
            guard result.status == 0 else { throw TerminalFailure("Ghostty rejected the managed profile:\n\(result.output)") }
        }
    }

    private func prepareRoot() throws {
        if fm.fileExists(atPath: root.path) {
            try checkOwnership()
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try write(markerText, to: marker)
        }
        try rejectSymlink(profilesURL)
        try fm.createDirectory(at: profilesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func checkOwnership() throws {
        try rejectSymlink(root)
        try rejectSymlink(marker)
        guard (try? String(contentsOf: marker, encoding: .utf8)) == markerText else {
            throw TerminalFailure("\(root.path) already exists and is not owned by Macoma. Its files were left unchanged.")
        }
        try rejectSymlink(profilesURL)
    }

    private func rejectSymlink(_ url: URL) throws {
        if let attributes = try? fm.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw TerminalFailure("Macoma will not replace the symbolic link at \(url.path).")
        }
    }

    private func saveState(_ state: TerminalProfileState) throws {
        try rejectSymlink(stateURL)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func ghosttyConfig(theme: TerminalPalette, font: TerminalFontSettings, directory: URL, originalZDOTDIR: String?, work: Bool = false) throws -> String {
        _ = try theme.validated()
        try font.validate()
        for value in [directory.path, originalZDOTDIR ?? ""] {
            guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { throw TerminalFailure("Terminal paths cannot contain line breaks.") }
        }
        let size = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), font.size)
        var lines = [
            "# Macoma managed profile. The ordinary Ghostty config is not changed.",
            "font-family = \(font.family)", "font-size = \(size)",
            "background = \(theme.background)", "foreground = \(theme.foreground)",
            "cursor-color = \(theme.cursor ?? theme.colors[15])", "cursor-text = \(theme.background)",
            "selection-background = \(theme.selectionBackground ?? theme.accent)", "selection-foreground = \(theme.selectionForeground ?? theme.colors[15])",
            "window-padding-x = 14", "window-padding-y = 12",
            "window-width = 150", "window-height = 44",
            "cursor-style = block", "cursor-style-blink = false",
            "macos-titlebar-style = native", "macos-option-as-alt = left",
            "command = direct:/bin/zsh -l", "shell-integration = none",
            "env = GHOSTTY_SHELL_FEATURES=title,path,ssh-env",
            "env = TMUX=", "env = MACARCHY_WORK=\(work ? "1" : "")",
            "env = MACARCHY_MANAGED=1", "env = MACARCHY_TERMINAL_PROFILE=\(directory.path)",
            "env = ZDOTDIR=\(directory.appendingPathComponent("zsh").path)",
            "env = STARSHIP_CONFIG=\(directory.appendingPathComponent("starship.toml").path)",
            "keybind = shift+enter=csi:13;2u", "keybind = alt+shift+enter=csi:13;4u",
            work ? "keybind = super+t=text:\\x02T" : "keybind = super+t=new_split:auto",
            "keybind = super+shift+t=new_tab"
        ]
        if let originalZDOTDIR, !originalZDOTDIR.isEmpty { lines += ["env = MACARCHY_ORIGINAL_ZDOTDIR=\(originalZDOTDIR)"] }
        lines += theme.colors.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func tmuxConfig(theme: TerminalPalette) -> String {
        """
        # Macoma's dedicated server only: tmux -L macarchy -f <this file>
        set -g prefix C-Space
        set -g prefix2 C-b
        bind C-Space send-prefix
        # Cmd-T in the Work Ghostty profile sends prefix2 (C-b), then T.
        bind T if-shell -F '\(TerminalTmuxProfile.autoSplitCondition)' "\(TerminalTmuxProfile.autoSplitHorizontal)" "\(TerminalTmuxProfile.autoSplitVertical)"
        set -g default-shell /bin/zsh
        set -g default-command '/bin/zsh -l'
        set -g default-terminal tmux-256color
        set -s terminal-features[100] 'xterm-ghostty:RGB'
        set -s terminal-features[101] 'tmux-256color:RGB'
        set -g mouse on
        set -g base-index 1
        setw -g pane-base-index 1
        set -g renumber-windows on
        set -g history-limit 50000
        set -sg escape-time 10
        set -g focus-events on
        set -g set-clipboard on
        set -g extended-keys on
        setw -g mode-keys vi
        bind -T copy-mode-vi v send-keys -X begin-selection
        bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
        bind h split-window -v -c '#{pane_current_path}'
        bind v split-window -h -c '#{pane_current_path}'
        bind x kill-pane
        bind c new-window -c '#{pane_current_path}'
        bind -n M-Enter split-window -v -c '#{pane_current_path}'
        bind -n M-S-Enter split-window -h -c '#{pane_current_path}'
        bind -n C-M-Left select-pane -L
        bind -n C-M-Right select-pane -R
        bind -n C-M-Up select-pane -U
        bind -n C-M-Down select-pane -D
        bind -n C-M-S-Left resize-pane -L 5
        bind -n C-M-S-Right resize-pane -R 5
        bind -n C-M-S-Up resize-pane -U 5
        bind -n C-M-S-Down resize-pane -D 5
        set -g status-position top
        set -g status-interval 5
        set -g status-left-length 30
        set -g status-right-length 50
        set -g status-justify left
        set -g window-status-separator ''
        setw -g automatic-rename on
        setw -g automatic-rename-format '#{b:pane_current_path}'
        set -g status-style 'bg=\(theme.background),fg=\(theme.foreground)'
        set -g status-left '#[fg=\(theme.background),bg=\(theme.colors[4]),bold] #S #[bg=default] '
        set -g status-right '#[fg=\(theme.colors[5])]#{?pane_in_mode,COPY ,}#{?client_prefix,PREFIX ,}#{?window_zoomed_flag,ZOOM ,}#[fg=\(theme.colors[8])] %a %H:%M '
        setw -g window-status-format '#[fg=\(theme.colors[8])] #I:#W '
        setw -g window-status-current-format '#[fg=\(theme.colors[4]),bold] #I:#W '
        set -g pane-border-style 'fg=\(theme.colors[5])'
        set -g pane-active-border-style 'fg=\(theme.colors[4])'
        set -g message-style 'bg=\(theme.background),fg=\(theme.accent)'
        setw -g mode-style 'bg=\(theme.accent),fg=\(theme.background)'
        """ + "\n"
    }

    static func starshipConfig(theme: TerminalPalette) -> String {
        """
        # Macoma prompt, active only inside managed sessions.
        add_newline = false
        format = "$directory$git_branch$git_status$character"
        [directory]
        style = "bold \(theme.colors[4])"
        truncation_length = 3
        truncate_to_repo = false
        [git_branch]
        format = "[$branch]($style) "
        style = "\(theme.colors[5])"
        [git_status]
        style = "\(theme.colors[3])"
        [character]
        success_symbol = "[❯](\(theme.colors[5]))"
        error_symbol = "[❯](\(theme.colors[1]))"
        """ + "\n"
    }
}
