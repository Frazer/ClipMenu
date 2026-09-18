import SwiftUI
import SwiftData
import Foundation

/// Actions tab in the Preferences window.
///
/// Covers: enable toggle, action-menu modifier key, invoke-immediately,
/// and the action menu editor.
struct ActionsPrefsView: View {

    @Environment(ClipMenuSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<ActionNode> { $0.parent == nil },
           sort: \ActionNode.sortIndex)
    private var rootNodes: [ActionNode]

    @State private var selectedNodeID: PersistentIdentifier?
    @State private var selectedCatalogID: String?
    @State private var rightTab: RightTab = .builtin

    private enum RightTab: String, CaseIterable {
        case builtin = "Built-in"
        case javaScript = "JavaScript"
        case users = "User's"
    }

    private struct AvailableActionItem: Identifiable, Hashable {
        var id: String
        var name: String
        var actionType: String
        var actionName: String?
        var scriptPath: String?
    }

    private struct CatalogNode: Identifiable, Hashable {
        var id: String
        var name: String
        var isLeaf: Bool
        var item: AvailableActionItem?
        var children: [CatalogNode]

        var visibleChildren: [CatalogNode]? {
            children.isEmpty ? nil : children
        }
    }

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                HStack(spacing: 12) {
                    Text("Hold this key while choosing a clip or snippet to open the action menu.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    Picker("", selection: $s.actionModifierKey) {
                        Text("Command (⌘)").tag(1)
                        Text("Option (⌥)").tag(0)
                        Text("Control (⌃)").tag(2)
                        Text("Shift (⇧)").tag(3)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            Text("Action Menu")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                actionTreePane
                actionControlsPane
                    .frame(width: 120)
                actionCatalogPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 8) {
                Text("Name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Action name", text: Binding(
                    get: { selectedNode?.title ?? "" },
                    set: { newValue in
                        guard let selectedNode else { return }
                        selectedNode.title = newValue
                        persist()
                    }
                ))
                .disabled(selectedNode == nil)
            }
        }
        .padding(4)
        .onAppear {
            if selectedNodeID == nil {
                selectedNodeID = rootNodes.first?.persistentModelID
            }
        }
        .onChange(of: rootNodes.count) { _, _ in
            if selectedNode == nil {
                selectedNodeID = rootNodes.first?.persistentModelID
            }
        }
    }

    // MARK: - Helpers

    private var actionTreePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current actions")
                .font(.subheadline)
                .fontWeight(.medium)

            List(selection: $selectedNodeID) {
                OutlineGroup(sortedRoots, children: \.sortedChildrenForUI) { node in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { node.isEnabled },
                            set: { newValue in
                                node.isEnabled = newValue
                                persist()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)

                        Image(systemName: node.isLeaf ? "bolt.fill" : "folder.fill")
                            .foregroundStyle(node.isLeaf ? .orange : .accentColor)

                        Text(node.title)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .tag(node.persistentModelID)
                    .draggable(nodeToken(node))
                    .dropDestination(for: String.self) { items, _ in
                        guard let sourceToken = items.first else { return false }
                        return handleDrop(sourceToken: sourceToken, onto: node)
                    }
                }
            }
            .listStyle(.sidebar)
            .dropDestination(for: String.self) { items, _ in
                guard let sourceToken = items.first,
                      let source = nodeForToken(sourceToken)
                else { return false }

                return moveNode(source, destinationParent: nil, destinationIndex: sortedRoots.count)
            }
        }
    }

    private var actionControlsPane: some View {
        VStack(spacing: 8) {
            Button {
                addSelectedCatalogAction()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(selectedCatalogItem == nil)

            Button {
                addFolder()
            } label: {
                Label("Folder", systemImage: "folder.badge.plus")
            }

            Button(role: .destructive) {
                removeSelectedNode()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedNode == nil)

            Divider()

            Button {
                moveSelectedNode(delta: -1)
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveSelectedNode(delta: -1))

            Button {
                moveSelectedNode(delta: 1)
            } label: {
                Label("Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveSelectedNode(delta: 1))
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.top, 28)
    }

    private var actionCatalogPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $rightTab) {
                ForEach(RightTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            List(selection: $selectedCatalogID) {
                OutlineGroup(catalogNodes, children: \.visibleChildren) { node in
                    HStack(spacing: 8) {
                        Image(systemName: node.isLeaf ? "bolt.fill" : "folder.fill")
                            .foregroundStyle(node.isLeaf ? .orange : .accentColor)
                        Text(node.name)
                    }
                    .tag(node.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var sortedRoots: [ActionNode] {
        rootNodes.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var selectedNode: ActionNode? {
        guard let selectedNodeID else { return nil }
        return allNodes.first { $0.persistentModelID == selectedNodeID }
    }

    private var allNodes: [ActionNode] {
        flatten(nodes: sortedRoots)
    }

    private var selectedCatalogItem: AvailableActionItem? {
        guard let selectedCatalogID else { return nil }
        return catalogLeafItemsByID[selectedCatalogID]
    }

    private var catalogLeafItemsByID: [String: AvailableActionItem] {
        var result: [String: AvailableActionItem] = [:]

        func collect(_ nodes: [CatalogNode]) {
            for node in nodes {
                if let item = node.item {
                    result[item.id] = item
                }
                if !node.children.isEmpty {
                    collect(node.children)
                }
            }
        }

        collect(catalogNodes)
        return result
    }

    private var catalogNodes: [CatalogNode] {
        switch rightTab {
        case .builtin:
            return [
                CatalogNode(
                    id: "builtin:pasteAsPlainText",
                    name: "Paste as Plain Text",
                    isLeaf: true,
                    item: AvailableActionItem(id: "builtin:pasteAsPlainText", name: "Paste as Plain Text", actionType: "builtin", actionName: "pasteAsPlainText"),
                    children: []
                ),
                CatalogNode(
                    id: "builtin:pasteAsFilePath",
                    name: "Paste as File Path",
                    isLeaf: true,
                    item: AvailableActionItem(id: "builtin:pasteAsFilePath", name: "Paste as File Path", actionType: "builtin", actionName: "pasteAsFilePath"),
                    children: []
                ),
                CatalogNode(
                    id: "builtin:pasteAsHFSFilePath",
                    name: "Paste as HFS File Path",
                    isLeaf: true,
                    item: AvailableActionItem(id: "builtin:pasteAsHFSFilePath", name: "Paste as HFS File Path", actionType: "builtin", actionName: "pasteAsHFSFilePath"),
                    children: []
                ),
                CatalogNode(
                    id: "builtin:removeAction",
                    name: "Remove",
                    isLeaf: true,
                    item: AvailableActionItem(id: "builtin:removeAction", name: "Remove", actionType: "builtin", actionName: "removeAction"),
                    children: []
                ),
            ]
        case .javaScript:
            let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("scripts/action")
            return scriptCatalogNodes(in: bundleURL)
        case .users:
            let userURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("ClipMenu/script/action")
            return scriptCatalogNodes(in: userURL)
        }
    }

    private func scriptCatalogNodes(in root: URL?) -> [CatalogNode] {
        guard let root else { return [] }

        struct ScriptRecord {
            let relativePath: String
            let fullPath: String
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [ScriptRecord] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "js" else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            records.append(ScriptRecord(relativePath: relative, fullPath: url.path))
        }

        final class MutableNode {
            let id: String
            let name: String
            var isLeaf: Bool
            var item: AvailableActionItem?
            var children: [String: MutableNode] = [:]

            init(id: String, name: String, isLeaf: Bool, item: AvailableActionItem? = nil) {
                self.id = id
                self.name = name
                self.isLeaf = isLeaf
                self.item = item
            }
        }

        let rootNode = MutableNode(id: "root", name: "root", isLeaf: false)

        for record in records {
            let parts = record.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }

            var cursor = rootNode
            for (idx, part) in parts.enumerated() {
                let isLast = idx == parts.count - 1
                if isLast {
                    let name = part.replacingOccurrences(of: ".js", with: "")
                    let item = AvailableActionItem(
                        id: "script:\(record.fullPath)",
                        name: name,
                        actionType: "javaScript",
                        actionName: nil,
                        scriptPath: record.fullPath
                    )
                    cursor.children[name] = MutableNode(
                        id: item.id,
                        name: name,
                        isLeaf: true,
                        item: item
                    )
                } else {
                    if cursor.children[part] == nil {
                        cursor.children[part] = MutableNode(
                            id: "folder:\(parts.prefix(idx + 1).joined(separator: "/"))",
                            name: part,
                            isLeaf: false
                        )
                    }
                    if let next = cursor.children[part] {
                        cursor = next
                    }
                }
            }
        }

        func freeze(_ node: MutableNode) -> CatalogNode {
            let sortedChildren = node.children.values
                .sorted { lhs, rhs in
                    if lhs.isLeaf != rhs.isLeaf {
                        return lhs.isLeaf && !rhs.isLeaf ? false : true
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map(freeze)

            return CatalogNode(
                id: node.id,
                name: node.name,
                isLeaf: node.isLeaf,
                item: node.item,
                children: sortedChildren
            )
        }

        return rootNode.children.values
            .sorted { lhs, rhs in
                if lhs.isLeaf != rhs.isLeaf {
                    return lhs.isLeaf && !rhs.isLeaf ? false : true
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(freeze)
    }

    private func addSelectedCatalogAction() {
        guard let item = selectedCatalogItem else { return }
        let newNode = ActionNode(title: item.name, isLeaf: true, sortIndex: 0)
        newNode.actionType = item.actionType
        newNode.actionName = item.actionName
        newNode.scriptPath = item.scriptPath
        insert(node: newNode, into: selectedFolderTarget)
        selectedNodeID = newNode.persistentModelID
    }

    private func addFolder() {
        let newFolder = ActionNode(title: "New Folder", isLeaf: false, sortIndex: 0)
        insert(node: newFolder, into: selectedFolderTarget)
        selectedNodeID = newFolder.persistentModelID
    }

    private var selectedFolderTarget: ActionNode? {
        guard let selectedNode else { return nil }
        return selectedNode.isLeaf ? selectedNode.parent : selectedNode
    }

    private func insert(node: ActionNode, into folder: ActionNode?) {
        if let folder {
            node.parent = folder
            node.sortIndex = nextSortIndex(in: folder)
            folder.children.append(node)
        } else {
            node.parent = nil
            node.sortIndex = nextRootSortIndex()
        }

        modelContext.insert(node)
        persist()
    }

    private func removeSelectedNode() {
        guard let selectedNode else { return }
        let parent = selectedNode.parent
        let selectedID = selectedNode.persistentModelID

        modelContext.delete(selectedNode)
        normalizeSiblings(in: parent)
        persist()

        if selectedNodeID == selectedID {
            if let parent {
                selectedNodeID = parent.persistentModelID
            } else {
                selectedNodeID = rootNodes.first?.persistentModelID
            }
        }
    }

    private func canMoveSelectedNode(delta: Int) -> Bool {
        guard let selectedNode else { return false }
        let siblings = siblingsOfSelectedNode(selectedNode)
        guard let index = siblings.firstIndex(where: { $0.persistentModelID == selectedNode.persistentModelID }) else {
            return false
        }
        let newIndex = index + delta
        return newIndex >= 0 && newIndex < siblings.count
    }

    private func moveSelectedNode(delta: Int) {
        guard let selectedNode else { return }
        let siblings = siblingsOfSelectedNode(selectedNode)
        guard let index = siblings.firstIndex(where: { $0.persistentModelID == selectedNode.persistentModelID }) else {
            return
        }
        let newIndex = index + delta
        guard newIndex >= 0 && newIndex < siblings.count else { return }

        let other = siblings[newIndex]
        let currentSort = selectedNode.sortIndex
        selectedNode.sortIndex = other.sortIndex
        other.sortIndex = currentSort
        normalizeSiblings(in: selectedNode.parent)
        persist()
    }

    private func siblingsOfSelectedNode(_ node: ActionNode) -> [ActionNode] {
        if let parent = node.parent {
            return parent.children.sorted { $0.sortIndex < $1.sortIndex }
        }
        return sortedRoots
    }

    private func nextRootSortIndex() -> Int {
        (sortedRoots.last?.sortIndex ?? -1) + 1
    }

    private func nextSortIndex(in folder: ActionNode) -> Int {
        let sorted = folder.children.sorted { $0.sortIndex < $1.sortIndex }
        return (sorted.last?.sortIndex ?? -1) + 1
    }

    private func normalizeSiblings(in parent: ActionNode?) {
        if let parent {
            let siblings = parent.children.sorted { $0.sortIndex < $1.sortIndex }
            for (idx, node) in siblings.enumerated() {
                node.sortIndex = idx
            }
            return
        }

        let roots = sortedRoots
        for (idx, node) in roots.enumerated() {
            node.sortIndex = idx
        }
    }

    private func flatten(nodes: [ActionNode]) -> [ActionNode] {
        var result: [ActionNode] = []
        for node in nodes.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            result.append(node)
            result.append(contentsOf: flatten(nodes: node.children))
        }
        return result
    }

    private func persist() {
        try? modelContext.save()
    }

    // MARK: - Drag and Drop

    private func nodeToken(_ node: ActionNode) -> String {
        String(describing: node.persistentModelID)
    }

    private func nodeForToken(_ token: String) -> ActionNode? {
        allNodes.first { nodeToken($0) == token }
    }

    private func handleDrop(sourceToken: String, onto target: ActionNode) -> Bool {
        guard let source = nodeForToken(sourceToken), source !== target else { return false }

        if target.isLeaf {
            let parent = target.parent
            let siblings = parent == nil
                ? sortedRoots
                : parent!.children.sorted { $0.sortIndex < $1.sortIndex }
            guard let targetIndex = siblings.firstIndex(where: { $0.persistentModelID == target.persistentModelID }) else {
                return false
            }
            return moveNode(source, destinationParent: parent, destinationIndex: targetIndex + 1)
        }

        let children = target.children.sorted { $0.sortIndex < $1.sortIndex }
        return moveNode(source, destinationParent: target, destinationIndex: children.count)
    }

    private func moveNode(_ source: ActionNode, destinationParent: ActionNode?, destinationIndex: Int) -> Bool {
        if let destinationParent {
            if source === destinationParent || isDescendant(destinationParent, of: source) {
                return false
            }
        }

        let sourceParent = source.parent
        if sourceParent === destinationParent {
            if sourceParent == nil {
                var roots = sortedRoots.filter { $0.persistentModelID != source.persistentModelID }
                let insertionIndex = max(0, min(destinationIndex, roots.count))
                roots.insert(source, at: insertionIndex)
                renumber(nodes: roots)
                persist()
                return true
            }

            guard let sourceParent else { return false }
            var siblings = sourceParent.children
                .filter { $0.persistentModelID != source.persistentModelID }
                .sorted { $0.sortIndex < $1.sortIndex }
            let insertionIndex = max(0, min(destinationIndex, siblings.count))
            siblings.insert(source, at: insertionIndex)
            sourceParent.children = siblings
            renumber(nodes: siblings)
            persist()
            return true
        }

        if let sourceParent {
            sourceParent.children.removeAll { $0.persistentModelID == source.persistentModelID }
            renumber(nodes: sourceParent.children.sorted { $0.sortIndex < $1.sortIndex })
        }

        if let destinationParent {
            var children = destinationParent.children
                .filter { $0.persistentModelID != source.persistentModelID }
                .sorted { $0.sortIndex < $1.sortIndex }
            let insertionIndex = max(0, min(destinationIndex, children.count))
            source.parent = destinationParent
            children.insert(source, at: insertionIndex)
            destinationParent.children = children
            renumber(nodes: children)
        } else {
            source.parent = nil
            var roots = sortedRoots.filter { $0.persistentModelID != source.persistentModelID }
            let insertionIndex = max(0, min(destinationIndex, roots.count))
            roots.insert(source, at: insertionIndex)
            renumber(nodes: roots)
        }

        selectedNodeID = source.persistentModelID
        persist()
        return true
    }

    private func renumber(nodes: [ActionNode]) {
        for (index, node) in nodes.enumerated() {
            node.sortIndex = index
        }
    }

    private func isDescendant(_ candidate: ActionNode, of ancestor: ActionNode) -> Bool {
        var current = candidate.parent
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }
}

private extension ActionNode {
    var sortedChildrenForUI: [ActionNode]? {
        let sorted = children.sorted { $0.sortIndex < $1.sortIndex }
        return sorted.isEmpty ? nil : sorted
    }
}

// MARK: - Preview

#Preview {
    ActionsPrefsView()
        .environment(ClipMenuSettings())
    .modelContainer(for: [ActionNode.self], inMemory: true)
    .frame(width: 820, height: 620)
}
