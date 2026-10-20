import XCTest
@testable import DockCore

final class AgentHostsTests: XCTestCase {
    /// A realistic process tree: iTerm2's server is reparented to launchd, VS Code's terminal runs under a helper,
    /// tmux panes belong to the tmux server, and Terminal.app runs login.
    let table = """
        1     0     0 ??      Ss   /sbin/launchd
      500     1     0 ??      S    /Users/f/Library/Application Support/iTerm2/iTermServer-3.6.4
      501   500   503 ttys001 Ss   /usr/bin/login
      502   501   503 ttys001 S    -zsh
      503   502   503 ttys001 S+   /Users/f/.local/bin/claude
      600     1     0 ??      S    /Applications/Visual Studio Code.app/Contents/MacOS/Electron
      601   600     0 ??      S    /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
      602   601   603 ttys002 Ss   /bin/zsh
      603   602   603 ttys002 S+   /opt/homebrew/bin/opencode
      700     1     0 ??      Ss   tmux
      701   700   702 ttys003 Ss   -zsh
      702   701   702 ttys003 S+   /Users/f/.local/bin/claude
      800     1     0 ??      S    /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
      801   800   803 ttys004 Ss   login
      802   801   803 ttys004 S    -zsh
      803   802   803 ttys004 S+   /opt/homebrew/bin/codex
      900     1     0 ??      S    /Applications/Ghostty.app/Contents/MacOS/ghostty
      901   900   901 ttys005 Ss+  /bin/zsh
      950     1     0 ??      Ss   /usr/sbin/sshd
      951   950   952 ttys006 Ss   -zsh
      952   951   952 ttys006 S+   /Users/f/.local/bin/claude
    """

    func testHostsComeFromTheParentChainAndTheOuterAppBundle() {
        let rows = ProcessRow.rows(table)
        XCTAssertEqual(rows.count, 21)
        // iTerm2 runs its session server from Application Support, reparented to launchd.
        XCTAssertEqual(AgentHosts.host(of: "/dev/ttys001", rows: rows).bundleIdentifier, "com.googlecode.iterm2")
        let code = AgentHosts.host(of: "/dev/ttys002", rows: rows, isApplication: { $0 == 600 })
        XCTAssertEqual(code.applicationPath, "/Applications/Visual Studio Code.app")
        XCTAssertEqual(code.processIdentifier, 600, "the app's own main process, not its helper")
        XCTAssertFalse(AgentHosts.host(of: "/dev/ttys006", rows: rows).isKnown, "an SSH login has no app")
        XCTAssertEqual(AgentHosts.host(of: "/dev/ttys003", rows: rows), AgentHost(applicationPath: nil, multiplexer: "tmux"))
        XCTAssertEqual(AgentHosts.host(of: "/dev/ttys004", rows: rows).applicationPath, "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(AgentHosts.host(of: "/dev/ttys099", rows: rows), AgentHost(applicationPath: nil, multiplexer: nil))
        XCTAssertNil(AgentHosts.application(of: "tmux"))
    }

    func testSessionsListOnlyForegroundAgentsAndSkipTerminalWhenItIsScripted() {
        let rows = ProcessRow.rows(table)
        let all = AgentHosts.sessions(rows: rows, inspect: { _ in nil }, resolve: { $0 })
        XCTAssertEqual(all.map(\.tty), ["/dev/ttys001", "/dev/ttys002", "/dev/ttys003", "/dev/ttys004"], "the idle Ghostty shell and the SSH login are not listed")
        XCTAssertEqual(all.map(\.tool.id), ["claude", "opencode", "claude", "codex"])
        let skipped = AgentHosts.sessions(rows: rows, inspect: { _ in nil }, resolve: { $0 }, skip: { $0.applicationPath?.hasSuffix("/Terminal.app") == true })
        XCTAssertEqual(skipped.map(\.tty), ["/dev/ttys001", "/dev/ttys002", "/dev/ttys003"])
    }
}
