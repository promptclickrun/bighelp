import Foundation
import Testing
@testable import Bighelp

/// When Hermes can't find an agent's workspace, a chosen folder fixes it by becoming the agent's
/// working folder; problems a folder can't fix (a container, SSH) don't offer it.
@MainActor
struct WorkspaceFolderChooserTests {
    @Test func offeredOnlyWhereAFolderHelps() {
        for code in ["workspace_not_configured", "workspace_unavailable", "workspace_hermes_folder"] {
            #expect(WorkspaceFolderChooser.canFix(WorkspaceClientError.rejected(code: code)), "\(code)")
        }
        for code in ["workspace_in_container", "workspace_on_remote", "workspace_windows_unsupported"] {
            #expect(!WorkspaceFolderChooser.canFix(WorkspaceClientError.rejected(code: code)), "\(code)")
        }
        #expect(!WorkspaceFolderChooser.canFix(WorkspaceClientError.invalidResponse))
    }

    @Test func theChoiceIsSentAsHermesWorkingFolder() throws {
        // The client refuses fields its routes don't list before anything reaches Hermes.
        let route = try DirectHermesWorkspaceClient.route(.configSet, payload: [
            "profile": .string("default"), "key": .string("terminal.cwd"), "value": .string("/Users/sam/agent-files"),
        ])
        #expect(route == .rpc("config.set", [
            "profile": .string("default"), "key": .string("terminal.cwd"), "value": .string("/Users/sam/agent-files"),
        ]))
        for unsafe in ["relative/folder", "/with\nnewline", ""] {
            #expect(throws: (any Error).self) {
                try DirectHermesWorkspaceClient.route(.configSet, payload: [
                    "profile": .string("default"), "key": .string("terminal.cwd"), "value": .string(unsafe),
                ])
            }
        }
    }
}
