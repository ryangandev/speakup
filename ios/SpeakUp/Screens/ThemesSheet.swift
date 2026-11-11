import SwiftUI

/// Ryan's interest themes (product.md#home): add one, pin one to the front, swipe to remove.
struct ThemesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @FocusState private var isNaming: Bool

    private var themes: ThemesModel { app.themes }
    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        TextField("New theme", text: $newName)
                            .font(Theme.Fonts.body)
                            .focused($isNaming)
                            .submitLabel(.done)
                            .onSubmit(add)
                            .accessibilityIdentifier("themes.newName")
                        Button("Add", action: add)
                            .font(Theme.Fonts.bodyEmphasis)
                            .buttonStyle(.borderless)
                            .disabled(trimmedName.isEmpty || themes.isAdding)
                            .accessibilityIdentifier("themes.add")
                    }
                    if let error = themes.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.Colors.negative)
                    }
                }
                if !themes.themes.isEmpty {
                    Section {
                        ForEach(themes.themes) { theme in
                            row(theme)
                        }
                        .onDelete { offsets in
                            let removed = offsets.map { themes.themes[$0] }
                            Task { for theme in removed { await themes.remove(theme, api: app.api) } }
                        }
                    }
                }
            }
            .navigationTitle("Themes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ theme: InterestTheme) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(theme.name)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: 0)
            Button {
                Task { await themes.setPinned(theme, !theme.pinned, api: app.api) }
            } label: {
                Image(systemName: theme.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(theme.pinned ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .frame(minWidth: 44)
                    // A full-size target without making the row taller than the add row.
                    .contentShape(Rectangle().inset(by: -Theme.Spacing.s))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(theme.pinned ? "Unpin \(theme.name)" : "Pin \(theme.name)")
            .accessibilityIdentifier("themes.pin.\(theme.name.lowercased())")
        }
        .accessibilityElement(children: .contain)
    }

    private func add() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        Task {
            guard await themes.add(name, api: app.api) else { return }
            newName = ""
            // With the keyboard down the whole list shows, the new theme included.
            isNaming = false
        }
    }
}
