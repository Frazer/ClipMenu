import SwiftUI
import SwiftData

/// Snippets tab in the Preferences window.
///
/// Provides basic folder/snippet editing so users can manage items shown
/// in the Snippets menu.
struct SnippetsPrefsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClipMenuSettings.self) private var settings

    @Query(sort: \SnippetFolder.sortIndex) private var folders: [SnippetFolder]

    @State private var selectedFolderID: PersistentIdentifier?
    @State private var selectedSnippetID: PersistentIdentifier?
    @State private var editingFolderID: PersistentIdentifier?
    @State private var editingFolderTitle: String = ""
    @State private var editingSnippetID: PersistentIdentifier?
    @State private var editingSnippetTitle: String = ""
    /// While true, title keystrokes also update content (until the user edits content separately).
    @State private var mirroringTitleIntoContent = false
    @State private var lastMirroredTitle = ""
    /// Content edits are kept in-memory until selection changes (avoids save lag on every click).
    @State private var contentDirty = false

    @FocusState private var isFolderNameFocused: Bool
    @FocusState private var isSnippetNameFocused: Bool

    private var selectedFolder: SnippetFolder? {
        folders.first { $0.persistentModelID == selectedFolderID }
    }

    private var selectedSnippets: [Snippet] {
        guard let selectedFolder else { return [] }
        return selectedFolder.snippets.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var selectedSnippet: Snippet? {
        selectedSnippets.first { $0.persistentModelID == selectedSnippetID }
    }

    var body: some View {
        @Bindable var s = settings

        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("The position to show snippets in ClipMenu:")
                    Spacer()
                    Picker("Snippet position", selection: $s.positionOfSnippets) {
                        Text("Above the clipboard history").tag(0)
                        Text("Below the clipboard history").tag(1)
                        Text("Hidden").tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("The position to show snippets in ClipMenu:")
                    Picker("Snippet position", selection: $s.positionOfSnippets) {
                        Text("Above the clipboard history").tag(0)
                        Text("Below the clipboard history").tag(1)
                        Text("Hidden").tag(2)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                foldersPane
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: .infinity)
                snippetsPane
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: .infinity)
                contentPane
                    .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .onAppear { ensureSelection() }
        .onChange(of: folders.count) { _, _ in ensureSelection() }
        .onDisappear {
            flushContentIfNeeded()
            persist()
        }
    }

    private var foldersPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders")
                .font(.headline)

            VStack(spacing: 8) {
                List {
                    ForEach(folders) { folder in
                        folderRow(folder)
                            .listRowBackground(rowBackground(isSelected: folder.persistentModelID == selectedFolderID))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                ControlGroup {
                    Button(action: addFolder) {
                        Image(systemName: "plus")
                    }
                    .help("Add Folder")

                    Button(action: removeSelectedFolder) {
                        Image(systemName: "minus")
                    }
                    .help("Remove Folder")
                    .disabled(selectedFolder == nil)
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var snippetsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .font(.headline)

            if selectedFolder != nil {
                VStack(spacing: 8) {
                    List {
                        ForEach(selectedSnippets) { snippet in
                            snippetRow(snippet)
                                .listRowBackground(rowBackground(isSelected: snippet.persistentModelID == selectedSnippetID))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ControlGroup {
                        Button(action: {
                            guard let selectedFolder else { return }
                            addSnippet(to: selectedFolder)
                        }) {
                            Image(systemName: "plus")
                        }
                        .help("Add Snippet")

                        Button(action: removeSelectedSnippet) {
                            Image(systemName: "minus")
                        }
                        .help("Remove Snippet")
                        .disabled(selectedSnippet == nil)
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ContentUnavailableView("No Folder Selected", systemImage: "text.badge.plus", description: Text("Create a folder to start adding snippets."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content")
                .font(.headline)

            TextEditor(text: Binding(
                get: { selectedSnippet?.content ?? "" },
                set: { newValue in
                    guard let selectedSnippet else { return }
                    if mirroringTitleIntoContent, newValue != lastMirroredTitle {
                        mirroringTitleIntoContent = false
                    }
                    selectedSnippet.content = newValue
                    contentDirty = true
                }
            ))
            .frame(minHeight: 280, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .padding(8)
            .disabled(selectedSnippet == nil)
        }
        .padding(10)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var panelBackground: Color {
        Color.black.opacity(0.1)
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    @ViewBuilder
    private func folderRow(_ folder: SnippetFolder) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { folder.isEnabled },
                set: { newValue in
                    folder.isEnabled = newValue
                    persist()
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: "folder.fill")

            if editingFolderID == folder.persistentModelID {
                TextField("Folder", text: $editingFolderTitle)
                    .textFieldStyle(.plain)
                    .focused($isFolderNameFocused)
                    .onSubmit { commitFolderRename(folder) }
                    .onExitCommand { commitFolderRename(folder) }
            } else {
                Text(folder.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(folder.title)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Only the selected row listens for double-click rename. Otherwise SwiftUI
        // delays every single-click ~300ms waiting to see if a second tap is coming.
        .onTapGesture {
            guard editingFolderID != folder.persistentModelID else { return }
            selectFolder(folder)
        }
        .onDoubleClickWhen(selectedFolderID == folder.persistentModelID) {
            guard editingFolderID != folder.persistentModelID else { return }
            beginFolderRename(folder)
        }
    }

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { snippet.isEnabled },
                set: { newValue in
                    snippet.isEnabled = newValue
                    persist()
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            if editingSnippetID == snippet.persistentModelID {
                TextField("Title", text: $editingSnippetTitle)
                    .textFieldStyle(.plain)
                    .focused($isSnippetNameFocused)
                    .onSubmit { commitSnippetRename(snippet) }
                    .onExitCommand { commitSnippetRename(snippet) }
                    .onChange(of: editingSnippetTitle) { _, newTitle in
                        mirrorTitleIntoContentIfNeeded(snippet, title: newTitle)
                    }
            } else {
                Text(snippet.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(snippet.title)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingSnippetID != snippet.persistentModelID else { return }
            selectSnippet(snippet)
        }
        .onDoubleClickWhen(selectedSnippetID == snippet.persistentModelID) {
            guard editingSnippetID != snippet.persistentModelID else { return }
            beginSnippetRename(snippet)
        }
    }

    private func selectFolder(_ folder: SnippetFolder) {
        guard selectedFolderID != folder.persistentModelID else { return }
        commitFolderRenameIfNeeded()
        commitSnippetRenameIfNeeded()
        flushContentIfNeeded()
        selectedFolderID = folder.persistentModelID
        if !folder.snippets.contains(where: { $0.persistentModelID == selectedSnippetID }) {
            selectedSnippetID = folder.snippets.sorted { $0.sortIndex < $1.sortIndex }.first?.persistentModelID
        }
    }

    private func selectSnippet(_ snippet: Snippet) {
        guard selectedSnippetID != snippet.persistentModelID else { return }
        commitSnippetRenameIfNeeded()
        flushContentIfNeeded()
        selectedSnippetID = snippet.persistentModelID
    }

    private func flushContentIfNeeded() {
        guard contentDirty else { return }
        contentDirty = false
        persist()
    }

    private func addFolder() {
        commitFolderRenameIfNeeded()
        commitSnippetRenameIfNeeded()
        let nextIndex = (folders.map(\.sortIndex).max() ?? -1) + 1
        let folder = SnippetFolder(title: "New Folder", sortIndex: nextIndex)
        modelContext.insert(folder)
        persist()
        selectedFolderID = folder.persistentModelID
        selectedSnippetID = nil
        beginFolderRename(folder)
    }

    private func removeSelectedFolder() {
        guard let selectedFolder else { return }
        commitFolderRenameIfNeeded()
        commitSnippetRenameIfNeeded()
        modelContext.delete(selectedFolder)
        persist()
        selectedFolderID = nil
        selectedSnippetID = nil
        ensureSelection()
    }

    private func addSnippet(to folder: SnippetFolder) {
        commitSnippetRenameIfNeeded()
        let nextIndex = (folder.snippets.map(\.sortIndex).max() ?? -1) + 1
        let snippet = Snippet(title: "New Snippet", content: "New Snippet", sortIndex: nextIndex)
        snippet.folder = folder
        folder.snippets.append(snippet)
        modelContext.insert(snippet)
        persist()
        selectedSnippetID = snippet.persistentModelID
        beginSnippetRename(snippet, mirrorContent: true)
    }

    private func removeSelectedSnippet() {
        guard let selectedSnippet else { return }
        commitSnippetRenameIfNeeded()
        modelContext.delete(selectedSnippet)
        persist()
        selectedSnippetID = selectedSnippets.first?.persistentModelID
    }

    private func ensureSelection() {
        if selectedFolder == nil {
            selectedFolderID = folders.first?.persistentModelID
        }

        guard let selectedFolder else {
            selectedSnippetID = nil
            return
        }

        if !selectedFolder.snippets.contains(where: { $0.persistentModelID == selectedSnippetID }) {
            selectedSnippetID = selectedFolder.snippets.sorted { $0.sortIndex < $1.sortIndex }.first?.persistentModelID
        }
    }

    private func persist() {
        try? modelContext.save()
    }

    private func beginFolderRename(_ folder: SnippetFolder) {
        commitFolderRenameIfNeeded()
        selectedFolderID = folder.persistentModelID
        editingFolderID = folder.persistentModelID
        editingFolderTitle = folder.title
        DispatchQueue.main.async {
            isFolderNameFocused = true
        }
    }

    private func commitFolderRenameIfNeeded() {
        guard let editingFolderID,
              let folder = folders.first(where: { $0.persistentModelID == editingFolderID })
        else {
            editingFolderID = nil
            return
        }
        commitFolderRename(folder)
    }

    private func commitFolderRename(_ folder: SnippetFolder) {
        guard editingFolderID == folder.persistentModelID else { return }
        let trimmed = editingFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.title = trimmed.isEmpty ? folder.title : trimmed
        editingFolderID = nil
        isFolderNameFocused = false
        persist()
    }

    private func beginSnippetRename(_ snippet: Snippet, mirrorContent: Bool = false) {
        commitSnippetRenameIfNeeded()
        selectedSnippetID = snippet.persistentModelID
        editingSnippetID = snippet.persistentModelID
        editingSnippetTitle = snippet.title

        let trimmedContent = snippet.content.trimmingCharacters(in: .whitespacesAndNewlines)
        mirroringTitleIntoContent = mirrorContent
            || trimmedContent.isEmpty
            || snippet.content == snippet.title
        lastMirroredTitle = snippet.title
        if mirroringTitleIntoContent, snippet.content != snippet.title {
            snippet.content = snippet.title
            lastMirroredTitle = snippet.title
        }

        DispatchQueue.main.async {
            isSnippetNameFocused = true
        }
    }

    private func mirrorTitleIntoContentIfNeeded(_ snippet: Snippet, title: String) {
        guard mirroringTitleIntoContent else { return }
        if !snippet.content.isEmpty, snippet.content != lastMirroredTitle {
            mirroringTitleIntoContent = false
            return
        }
        snippet.content = title
        lastMirroredTitle = title
        contentDirty = true
    }

    private func commitSnippetRenameIfNeeded() {
        guard let editingSnippetID,
              let snippet = selectedSnippets.first(where: { $0.persistentModelID == editingSnippetID })
                ?? folders.lazy.flatMap(\.snippets).first(where: { $0.persistentModelID == editingSnippetID })
        else {
            editingSnippetID = nil
            mirroringTitleIntoContent = false
            return
        }
        commitSnippetRename(snippet)
    }

    private func commitSnippetRename(_ snippet: Snippet) {
        guard editingSnippetID == snippet.persistentModelID else { return }
        let trimmed = editingSnippetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? snippet.title : trimmed
        snippet.title = newTitle

        if mirroringTitleIntoContent || snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snippet.content = newTitle
        }

        editingSnippetID = nil
        isSnippetNameFocused = false
        mirroringTitleIntoContent = false
        persist()
    }
}

// MARK: - Preview

#Preview {
    let folder = SnippetFolder(title: "Templates", sortIndex: 0)
    let snippet = Snippet(title: "Greeting", content: "Hello from ClipMenu!", sortIndex: 0)
    snippet.folder = folder
    folder.snippets = [snippet]

    return SnippetsPrefsView()
        .modelContainer(for: [SnippetFolder.self, Snippet.self], inMemory: true)
}

private extension View {
    /// Attaches a double-click handler only when `enabled` is true, so unselected
    /// rows are not slowed down by SwiftUI's double-tap recognition window.
    @ViewBuilder
    func onDoubleClickWhen(_ enabled: Bool, perform: @escaping () -> Void) -> some View {
        if enabled {
            simultaneousGesture(TapGesture(count: 2).onEnded { perform() })
        } else {
            self
        }
    }
}
