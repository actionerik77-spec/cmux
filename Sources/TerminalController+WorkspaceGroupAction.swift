import Foundation
import CmuxWorkspaces

extension TerminalController {
    /// Mobile-gated workspace-group creation that mirrors mobile workspace.create.
    func v2MobileWorkspaceGroupCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        let identity = mobileWorkspaceGroupExternalID(params: params)
        if let error = identity.error { return error }
        let title = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false ? title ?? "" : ""

        var mutationError: V2CallResult?
        v2MainSync {
            guard tabManager.createWorkspaceGroup(
                name: name,
                externalID: identity.value,
                selectAnchor: false,
                collapseSidebarSelection: false
            ) != nil else {
                mutationError = .err(code: "not_created", message: "Group was not created", data: nil)
                return
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "title")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    /// Mobile-gated workspace-group mutations that mirror the desktop header menu.
    func v2MobileWorkspaceGroupAction(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "group_id"), let groupID = v2UUID(params, "group_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid group_id", data: nil)
        }
        guard let action = mobileWorkspaceGroupAction(params: params) else {
            return .err(
                code: "method_not_found",
                message: "Unsupported workspace group action for mobile",
                data: ["action": v2OrNull(v2RawString(params, "action"))]
            )
        }
        let title = mobileWorkspaceGroupActionTitle(params: params, action: action)
        if action == .rename, title == nil {
            return .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }

        var mutationError: V2CallResult?
        v2MainSync {
            guard tabManager.workspaceGroups.contains(where: { $0.id == groupID }) else {
                mutationError = .err(
                    code: "not_found",
                    message: "Group not found",
                    data: ["group_id": groupID.uuidString]
                )
                return
            }
            switch action {
            case .pin:
                tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: true)
            case .unpin:
                tabManager.setWorkspaceGroupPinned(groupId: groupID, isPinned: false)
            case .rename:
                guard let title else {
                    mutationError = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                tabManager.renameWorkspaceGroup(groupId: groupID, name: title)
            case .ungroup:
                let removeGeneratedAnchor: Bool
                if !v2HasNonNullParam(params, "remove_generated_anchor") {
                    removeGeneratedAnchor = false
                } else if let value = params["remove_generated_anchor"] as? Bool {
                    removeGeneratedAnchor = value
                } else {
                    mutationError = .err(
                        code: "invalid_params",
                        message: controlWorkspaceGroupStrings().removeGeneratedAnchorMustBeBoolean,
                        data: nil
                    )
                    return
                }
                switch tabManager.ungroupWorkspaceGroup(
                    groupId: groupID,
                    removeGeneratedAnchor: removeGeneratedAnchor
                ) {
                case .groupNotFound:
                    mutationError = .err(code: "not_found", message: "Group not found", data: nil)
                case .dissolved, .removedGeneratedAnchor:
                    break
                case .generatedAnchorRequiresAnchorOnly:
                    mutationError = .err(
                        code: "invalid_state",
                        message: controlWorkspaceGroupStrings().generatedAnchorRequiresAnchorOnly,
                        data: nil
                    )
                case .generatedAnchorNotOwned:
                    mutationError = .err(
                        code: "invalid_state",
                        message: controlWorkspaceGroupStrings().generatedAnchorNotOwned,
                        data: nil
                    )
                case .generatedAnchorRemovalFailed:
                    mutationError = .err(
                        code: "not_removed",
                        message: controlWorkspaceGroupStrings().generatedAnchorRemovalFailed,
                        data: nil
                    )
                }
            case .delete:
                let memberCount = tabManager.tabs.filter { $0.groupId == groupID }.count
                guard memberCount > 0 else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: "Group has no workspaces to close",
                        data: ["group_id": groupID.uuidString]
                    )
                    return
                }
                guard memberCount < tabManager.tabs.count else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: "Cannot delete every workspace in a window",
                        data: [
                            "group_id": groupID.uuidString,
                            "workspace_count": memberCount,
                        ]
                    )
                    return
                }
                let closed = tabManager.deleteWorkspaceGroup(groupId: groupID)
                guard closed == memberCount else {
                    mutationError = .err(
                        code: "invalid_request",
                        message: "Could not close every workspace in the group",
                        data: [
                            "group_id": groupID.uuidString,
                            "requested_close_count": memberCount,
                            "closed_count": closed,
                        ]
                    )
                    return
                }
            }
        }
        if let mutationError {
            return mutationError
        }

        var listParams = params
        listParams.removeValue(forKey: "group_id")
        listParams.removeValue(forKey: "action")
        listParams.removeValue(forKey: "title")
        return v2MobileWorkspaceList(params: listParams, tabManager: tabManager)
    }

    private func mobileWorkspaceGroupAction(params: [String: Any]) -> MobileWorkspaceGroupAction? {
        guard let rawAction = v2RawString(params, "action")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_"),
            !rawAction.isEmpty else {
            return nil
        }
        return MobileWorkspaceGroupAction(rawValue: rawAction)
    }

    private func mobileWorkspaceGroupActionTitle(
        params: [String: Any],
        action: MobileWorkspaceGroupAction
    ) -> String? {
        guard action == .rename else { return nil }
        guard let trimmed = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Parses the shared caller-owned identity accepted by mobile and control
    /// workspace-group creation. The control-socket path supplies localized
    /// errors; this mobile path is only reached after authenticated RPC gating.
    private func mobileWorkspaceGroupExternalID(
        params: [String: Any]
    ) -> (value: String?, error: V2CallResult?) {
        let external = v2RawString(params, "external_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idempotency = v2RawString(params, "idempotency_key")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if v2HasNonNullParam(params, "external_id"), external == nil {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeyMustBeString",
                    defaultValue: "external_id and idempotency_key must be strings"
                ),
                data: nil
            ))
        }
        if v2HasNonNullParam(params, "idempotency_key"), idempotency == nil {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeyMustBeString",
                    defaultValue: "external_id and idempotency_key must be strings"
                ),
                data: nil
            ))
        }
        if v2HasNonNullParam(params, "external_id"), external?.isEmpty != false {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeyMustNotBeEmpty",
                    defaultValue: "The group identity must not be empty"
                ),
                data: nil
            ))
        }
        if v2HasNonNullParam(params, "idempotency_key"), idempotency?.isEmpty != false {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeyMustNotBeEmpty",
                    defaultValue: "The group identity must not be empty"
                ),
                data: nil
            ))
        }
        if let external, let idempotency, external != idempotency {
            return (nil, .err(
                code: "invalid_params",
                message: String(
                    localized: "workspaceGroup.error.idempotencyKeysMustMatch",
                    defaultValue: "external_id and idempotency_key must match"
                ),
                data: nil
            ))
        }
        return (external ?? idempotency, nil)
    }
}

private enum MobileWorkspaceGroupAction: String {
    case pin
    case unpin
    case rename
    case ungroup
    case delete
}
