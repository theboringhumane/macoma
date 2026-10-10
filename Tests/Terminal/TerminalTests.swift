import Foundation

@main
struct TerminalTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TerminalFailure("FAIL: \(message)") }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw TerminalFailure("FAIL: \(message)")
    }

    static func main() {
        do { try run() }
        catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let fm = FileManager.default
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ghostty = URL(fileURLWithPath: CommandLine.arguments[2])
        let tmux = URL(fileURLWithPath: CommandLine.arguments[3])
        let temp = fm.temporaryDirectory.appendingPathComponent("macarchy-terminal-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let theme = TerminalPalette(id: "tokyo-night", name: "Tokyo Night", background: "#1a1b26", foreground: "#a9b1d6", accent: "#7aa2f7",
            colors: ["#1a1b26", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#ad8ee6", "#449dab", "#a9b1d6", "#414868", "#ff7a93", "#b9f27c", "#ff9e64", "#7da6ff", "#bb9af7", "#0db9d7", "#c0caf5"],
            selectionBackground: "#292e42", selectionForeground: "#c0caf5", cursor: "#c0caf5")
        let font = TerminalFontSettings(family: "Menlo", size: 13)
        var badTheme = theme
        badTheme.colors[4] = "#000000\ncommand = touch /tmp/never"
        try rejects("unsafe palette accepted") { _ = try badTheme.validated() }
        try rejects("unsafe font accepted") { try TerminalFontSettings(family: "Menlo\ncommand=x", size: 13).validate() }
        try rejects("invalid font size accepted") { try TerminalFontSettings(family: "Menlo", size: .nan).validate() }
        let timeoutStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try TerminalProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.1)
            throw TerminalFailure("FAIL: a stalled command did not time out")
        } catch {
            try require(error.localizedDescription.contains("timed out"), "stalled command returned the wrong error")
        }
        try require(ProcessInfo.processInfo.systemUptime - timeoutStarted < 2, "timeout did not bound execution")
        do {
            _ = try TerminalProcess.run(URL(fileURLWithPath: "/usr/bin/yes"), [], timeout: 2, outputLimit: 1024)
            throw TerminalFailure("FAIL: unlimited output was accepted")
        } catch {
            try require(error.localizedDescription.contains("output limit"), "excess output returned the wrong error")
        }
        try rejects("unsafe path accepted") {
            _ = try TerminalProfileStore.ghosttyConfig(theme: theme, font: font, directory: URL(fileURLWithPath: "/tmp/config\ncommand=x"), originalZDOTDIR: nil)
        }

        let home = temp.appendingPathComponent("Home with spaces and 'quote' $(literal)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let store = TerminalProfileStore(root: home.appendingPathComponent(".config/macarchy/terminal"))
        let ordinaryGhostty = home.appendingPathComponent(".config/ghostty/config")
        try fm.createDirectory(at: ordinaryGhostty.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("# ordinary user config\nfont-size = 99\n".utf8)
        try sentinel.write(to: ordinaryGhostty)
        let first = try store.apply(theme: theme, font: font, ghostty: ghostty, resources: resources)
        let profile = try store.profileURL(first.generation)
        let ghosttyText = try String(contentsOf: profile.appendingPathComponent("ghostty.conf"), encoding: .utf8)
        try require(ghosttyText.contains("selection-background = #292e42"), "selection background lost")
        try require(ghosttyText.contains("cursor-color = #c0caf5"), "cursor semantic color lost")
        try require(ghosttyText.components(separatedBy: "palette = ").count - 1 == 16, "not all ANSI colors were generated")
        // +show-config has no config-file flag in Ghostty 1.3.1. Isolate its
        // default lookup using a temporary HOME and XDG_CONFIG_HOME instead.
        let inspectHome = temp.appendingPathComponent("inspect", isDirectory: true)
        let inspectConfig = inspectHome.appendingPathComponent(".config/ghostty", isDirectory: true)
        try fm.createDirectory(at: inspectConfig, withIntermediateDirectories: true)
        try fm.copyItem(at: profile.appendingPathComponent("ghostty.conf"), to: inspectConfig.appendingPathComponent("config"))
        var inspectEnv = ProcessInfo.processInfo.environment
        inspectEnv["HOME"] = inspectHome.path
        inspectEnv["XDG_CONFIG_HOME"] = inspectHome.appendingPathComponent(".config").path
        let shown = try TerminalProcess.run(ghostty, ["+show-config", "--changes-only=false"], environment: inspectEnv)
        try require(shown.status == 0, "installed Ghostty failed to parse profile")
        try require(shown.output.contains("font-size = 13"), "ordinary Ghostty config leaked into managed profile")
        try require(shown.output.contains("env = ZDOTDIR=\(profile.path)/zsh"), "Ghostty changed spaces or shell characters in ZDOTDIR")
        try require(shown.output.contains("super+t=new_split:auto"), "ordinary managed Cmd-T does not create a native Ghostty pane")
        try require(shown.output.contains("super+shift+t=new_tab"), "explicit new-tab shortcut is missing")
        try fm.removeItem(at: inspectConfig.appendingPathComponent("config"))
        try fm.copyItem(at: profile.appendingPathComponent("ghostty-work.conf"), to: inspectConfig.appendingPathComponent("config"))
        let shownWork = try TerminalProcess.run(ghostty, ["+show-config", "--changes-only=false"], environment: inspectEnv)
        // Ghostty's formatter escapes the stored Zig text escape once more.
        let normalizedWork = shownWork.output.replacingOccurrences(of: "\\\\", with: "\\")
        try require(shownWork.status == 0 && normalizedWork.contains("super+t=text:\\x02T"), "Work Cmd-T does not send tmux prefix + T")
        try require(!shownWork.output.contains("super+t=new_split"), "Work Cmd-T nests a native Ghostty split")
        try require(shownWork.output.contains("env = MACARCHY_WORK=1"), "new native tabs do not retain Work context")
        let args = TerminalLaunch.openArguments(app: URL(fileURLWithPath: "/Applications/Ghostty.app"), profile: profile, tmux: tmux)
        try require(args[0] == "-na" && args[2] == "--args", "macOS launch does not use a fresh app instance")
        try require(args.contains("--config-file=\(profile.path)/ghostty-work.conf") && args.contains("--env=MACARCHY_TMUX_BINARY=\(tmux.path)"), "Work launch did not select its context-specific profile")
        let ordinaryArgs = TerminalLaunch.openArguments(app: URL(fileURLWithPath: "/Applications/Ghostty.app"), profile: profile)
        try require(ordinaryArgs.contains("--config-file=\(profile.path)/ghostty.conf"), "ordinary terminal accidentally uses Work shortcuts")
        let execute = args.firstIndex(of: "-e")!
        try require(Array(args[(execute + 1)...]) == ["/bin/zsh", profile.appendingPathComponent("work-session.zsh").path, profile.path, tmux.path, "macarchy"], "launch collapsed arguments into a shell string")
        try require(try store.currentReceipt() == first, "first apply was not persisted")
        let second = try store.apply(theme: theme, font: TerminalFontSettings(family: "Menlo", size: 14), ghostty: ghostty, resources: resources)
        try require(try store.state()?.previous == first.generation, "previous profile was not retained")
        try rejects("validation failure unexpectedly succeeded") {
            _ = try store.apply(theme: theme, font: font, ghostty: URL(fileURLWithPath: "/usr/bin/false"), resources: resources)
        }
        try require(try store.currentReceipt() == second, "failed validation replaced active profile")
        try require(try fm.contentsOfDirectory(atPath: store.root.appendingPathComponent("profiles").path).count == 2, "failed generation was not cleaned up")
        try require(try store.restore(ghostty: ghostty) == first, "restore did not select retained generation")
        try require(try Data(contentsOf: ordinaryGhostty) == sentinel, "ordinary Ghostty config was modified")

        let foreign = temp.appendingPathComponent("foreign")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
        try rejects("unowned directory was adopted") {
            _ = try TerminalProfileStore(root: foreign).apply(theme: theme, font: font, ghostty: ghostty, resources: resources)
        }
        let symlink = temp.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: store.root)
        try rejects("symlink root was followed") { _ = try TerminalProfileStore(root: symlink).currentReceipt() }
        print("PASS: installed Ghostty validation, palette semantics, argument boundaries, atomic activation and restore")

        // Exercise normal login-shell startup with a user-selected ZDOTDIR.
        let userDotdir = home.appendingPathComponent("my zsh files", isDirectory: true)
        try fm.createDirectory(at: userDotdir, withIntermediateDirectories: true)
        try Data("print env >> \"$HOME/startup.log\"\nexport ZDOTDIR=\"$HOME/my zsh files\"\n".utf8).write(to: home.appendingPathComponent(".zshenv"))
        for file in [".zprofile", ".zshrc", ".zlogin"] {
            try Data("print \(file) >> \"$HOME/startup.log\"\n".utf8).write(to: userDotdir.appendingPathComponent(file))
        }
        let rcBefore = try Data(contentsOf: userDotdir.appendingPathComponent(".zshrc"))
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["MACARCHY_MANAGED"] = "1"
        environment["MACARCHY_TERMINAL_PROFILE"] = profile.path
        environment["MACARCHY_ORIGINAL_ZDOTDIR"] = home.path
        environment["ZDOTDIR"] = profile.appendingPathComponent("zsh").path
        environment["GHOSTTY_RESOURCES_DIR"] = nil
        environment["MACARCHY_WORK"] = nil
        environment["MACARCHY_TMUX_BINARY"] = nil
        let shell = try TerminalProcess.run(URL(fileURLWithPath: "/bin/zsh"), ["-lic", "print -r -- MANAGED:$MACARCHY_MANAGED; alias ls"], environment: environment)
        try require(shell.status == 0 && shell.output.contains("MANAGED:1"), "managed shell did not start")
        let startup = try String(contentsOf: home.appendingPathComponent("startup.log"), encoding: .utf8)
        try require(startup == "env\n.zprofile\n.zshrc\n.zlogin\n", "normal zsh startup order or custom ZDOTDIR was lost: \(startup)")
        try require(shell.output.contains("ls=") && (shell.output.contains("eza") || shell.output.contains("ls -G")), "managed color listings were not enabled")
        try require(try Data(contentsOf: userDotdir.appendingPathComponent(".zshrc")) == rcBefore, "user .zshrc changed")
        print("PASS: normal zsh startup order and custom ZDOTDIR preserved; managed enhancements loaded")

        // All tmux mutations target a unique throwaway socket, never macarchy/default.
        let socket = "macarchy-test-\(UUID().uuidString)"
        defer { _ = try? TerminalProcess.run(tmux, ["-L", socket, "kill-server"]) }
        let scriptArgs = [profile.appendingPathComponent("work-session.zsh").path, profile.path, tmux.path, socket, "prepare"]
        let created = try TerminalProcess.run(URL(fileURLWithPath: "/bin/zsh"), scriptArgs, environment: environment)
        try require(created.status == 0, "Work session creation failed: \(created.output)")
        let format = "#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}"
        let firstPanes = try TerminalProcess.run(tmux, ["-L", socket, "list-panes", "-t", "=Work", "-F", format])
        let panes = firstPanes.output.split(separator: "\n").map { $0.split(separator: "|").map(String.init) }
        try require(panes.count == 3 && panes.allSatisfy { $0.count == 5 }, "Work did not create three panes: \(firstPanes.output)")
        let ordered = panes.sorted { Int($0[2])! < Int($1[2])! }
        let upper = ordered[0]
        let lower = Array(ordered.dropFirst()).sorted { Int($0[1])! < Int($1[1])! }
        try require(upper[1] == "0" && Int(upper[3])! == 160, "upper pane is not full width")
        try require(lower[0][2] == lower[1][2] && Int(lower[0][2])! > Int(upper[2])!, "lower panes do not share a row below the upper pane")
        try require(Int(lower[0][3])! + Int(lower[1][3])! + 1 == Int(upper[3])!, "lower panes do not span the window")
        let options = try TerminalProcess.run(tmux, ["-L", socket, "show-options", "-g"])
        try require(options.output.contains("status-position top"), "status bar is not at the top")
        try require(options.output.contains("#ad8ee6") && options.output.contains("#7aa2f7"), "pane colors were not loaded")
        let repeated = try TerminalProcess.run(URL(fileURLWithPath: "/bin/zsh"), scriptArgs, environment: environment)
        try require(repeated.status == 0, "reconnect preparation failed: \(repeated.output)")
        let secondPanes = try TerminalProcess.run(tmux, ["-L", socket, "list-panes", "-t", "=Work", "-F", format])
        try require(firstPanes.output == secondPanes.output, "reconnect changed pane IDs or layout")
        // User-created additional windows and commands survive a subsequent Work launch.
        let extra = try TerminalProcess.run(tmux, ["-L", socket, "new-window", "-d", "-t", "Work:", "-n", "Preserve", "/bin/sleep", "60"])
        try require(extra.status == 0, "could not create preservation fixture: \(extra.output)")
        _ = try TerminalProcess.run(URL(fileURLWithPath: "/bin/zsh"), scriptArgs, environment: environment)
        let windows = try TerminalProcess.run(tmux, ["-L", socket, "list-windows", "-t", "Work", "-F", "#{window_name}:#{pane_current_command}"])
        try require(windows.output.contains("Preserve:sleep"), "existing window or running command was reset")
        print("PASS: isolated tmux three-pane geometry, top status, palette borders and idempotent reconnection")

        // A -> B updates only future-pane environment, including Work's local
        // overrides. Existing panes keep their process identities and commands.
        let originalProcesses = try TerminalProcess.run(tmux, ["-L", socket, "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}:#{pane_current_command}"])
        var themeB = theme
        themeB.id = "test-lavender"
        themeB.name = "Test Lavender"
        themeB.colors[5] = "#d787ff"
        let receiptB = try store.apply(theme: themeB, font: font, ghostty: ghostty, resources: resources)
        let profileB = try store.profileURL(receiptB.generation)
        try require(try TerminalTmuxProfile.apply(binary: tmux, profile: profileB, socket: socket), "live tmux profile was not refreshed")
        let afterRefresh = try TerminalProcess.run(tmux, ["-L", socket, "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}:#{pane_current_command}"])
        try require(originalProcesses.output == afterRefresh.output, "profile refresh changed an existing process")

        let probe = home.appendingPathComponent("probe.zsh")
        try Data("""
        printf '%s\\n' "$MACARCHY_TERMINAL_PROFILE" "$ZDOTDIR" "$STARSHIP_CONFIG" > "$HOME/probe-values"
        exec /bin/sleep 30
        """.utf8).write(to: probe)
        func checkNewPane(_ expectedProfile: URL) throws {
            let output = home.appendingPathComponent("probe-values")
            try? fm.removeItem(at: output)
            let pane = try TerminalProcess.run(tmux, ["-L", socket, "split-window", "-d", "-P", "-F", "#{pane_id}", "-t", upper[0], "/bin/zsh", "-li", probe.path])
            try require(pane.status == 0, "future pane could not launch: \(pane.output)")
            defer { _ = try? TerminalProcess.run(tmux, ["-L", socket, "kill-pane", "-t", pane.output]) }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !fm.fileExists(atPath: output.path) && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            let values = try String(contentsOf: output, encoding: .utf8)
            let expected = "\(expectedProfile.path)\n\(expectedProfile.path)/zsh\n\(expectedProfile.path)/starship.toml\n"
            try require(values == expected, "future pane inherited an old profile: \(values)")
            let global = try TerminalProcess.run(tmux, ["-L", socket, "show-environment", "-g", "MACARCHY_TERMINAL_PROFILE"])
            try require(global.output == "MACARCHY_TERMINAL_PROFILE=\(expectedProfile.path)", "future sessions retain the old global profile")
        }
        try checkNewPane(profileB)
        let promptB = try String(contentsOf: profileB.appendingPathComponent("starship.toml"), encoding: .utf8)
        try require(promptB.contains("#d787ff"), "new profile did not contain the changed prompt theme")
        let restored = try store.restore(ghostty: ghostty)
        let restoredProfile = try store.profileURL(restored.generation)
        try require(restoredProfile == profile, "profile A was not restored")
        _ = try TerminalTmuxProfile.apply(binary: tmux, profile: restoredProfile, socket: socket)
        try checkNewPane(restoredProfile)
        print("PASS: A -> B -> new pane and restore -> new pane use the correct profile; running processes preserved")

        let binding = try TerminalProcess.run(tmux, ["-L", socket, "list-keys", "-T", "prefix", "T"])
        try require(binding.status == 0 && binding.output.contains(TerminalTmuxProfile.autoSplitCondition), "tmux T binding does not use the tested direction rule")
        func checkAutomaticSplit(width: Int, height: Int, horizontal: Bool) throws {
            let createdWindow = try TerminalProcess.run(tmux, ["-L", socket, "new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "Work:", "-n", "AutoSplit", "/bin/sleep", "30"])
            try require(createdWindow.status == 0, "auto-split fixture failed: \(createdWindow.output)")
            let target = createdWindow.output
            defer { _ = try? TerminalProcess.run(tmux, ["-L", socket, "kill-window", "-t", target]) }
            let sized = try TerminalProcess.run(tmux, ["-L", socket, "resize-window", "-t", target, "-x", String(width), "-y", String(height)])
            try require(sized.status == 0, "auto-split fixture could not resize: \(sized.output)")
            // A key binding runs in the focused pane's context. Select the
            // fixture before invoking the same command through the CLI.
            _ = try TerminalProcess.run(tmux, ["-L", socket, "select-window", "-t", target])
            _ = try TerminalProcess.run(tmux, ["-L", socket, "select-pane", "-t", target])
            let before = try TerminalProcess.run(tmux, ["-L", socket, "display-message", "-p", "-t", target, "#{pane_pid}:#{pane_current_command}"])
            let split = try TerminalProcess.run(tmux, ["-L", socket] + TerminalTmuxProfile.autoSplitArguments())
            try require(split.status == 0, "exact tmux auto-split command failed: \(split.output)")
            let dimensions = try TerminalProcess.run(tmux, ["-L", socket, "list-panes", "-t", target, "-F", "#{pane_left}:#{pane_top}"])
            let coordinates = dimensions.output.split(separator: "\n").map { $0.split(separator: ":").map(String.init) }
            try require(coordinates.count == 2 && coordinates.allSatisfy { $0.count == 2 }, "auto-split did not add exactly one pane: \(dimensions.output)")
            if horizontal {
                try require(coordinates[0][1] == coordinates[1][1] && coordinates[0][0] != coordinates[1][0], "wide pane was not split side by side")
            } else {
                try require(coordinates[0][0] == coordinates[1][0] && coordinates[0][1] != coordinates[1][1], "tall pane was not split top and bottom")
            }
            let after = try TerminalProcess.run(tmux, ["-L", socket, "display-message", "-p", "-t", target, "#{pane_pid}:#{pane_current_command}"])
            try require(before.output == after.output && after.output.contains("sleep"), "auto-split changed the active command")
        }
        try checkAutomaticSplit(width: 160, height: 30, horizontal: true)
        try checkAutomaticSplit(width: 80, height: 60, horizontal: false)
        print("PASS: Ghostty Cmd-T contexts, explicit tab shortcut, exact tmux auto-split in wide/tall panes and active command preservation")
        print("PASS: command timeouts and output limits are enforced")
        print("All terminal tests passed. No user configs, real tmux sessions, or GUI apps were changed.")
    }
}
