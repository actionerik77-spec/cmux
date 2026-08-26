import Foundation

extension CmuxExtensionWorktreeCreationResult {
    init(
        projectRootPath: String,
        worktreePath: String,
        branchName: String,
        workspaceTitle: String,
        createdHead: String,
        generatedArtifactRelativePath: String,
        generatedArtifactContents: Data,
        worktreeDeviceID: UInt64? = nil,
        worktreeFileID: UInt64? = nil,
        setupCommand: String
    ) {
        self.projectRootPath = projectRootPath
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.workspaceTitle = workspaceTitle
        self.createdHead = createdHead
        self.generatedArtifactRelativePath = generatedArtifactRelativePath
        self.generatedArtifactContents = generatedArtifactContents
        self.worktreeDeviceID = worktreeDeviceID
        self.worktreeFileID = worktreeFileID
        self.setupCommand = setupCommand
    }
}
