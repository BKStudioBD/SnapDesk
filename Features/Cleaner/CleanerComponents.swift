import SwiftUI

/// Whether a group is fully, partly, or not selected — drawn as one box the
/// person can click to take the whole group with it.
enum SelectionState {
    case none, some, all

    init(selected: Int, total: Int) {
        if total > 0 && selected == total { self = .all }
        else if selected > 0 { self = .some }
        else { self = .none }
    }

    var symbol: String {
        switch self {
        case .none: "square"
        case .some: "minus.square"
        case .all: "checkmark.square.fill"
        }
    }

    /// What a click should do: an untouched or partial group fills in, a full
    /// group empties.
    var clickSelects: Bool { self != .all }
}

/// The tick box used by every list in the cleaner. A real `Button` rather than a
/// tap gesture, so VoiceOver and the keyboard reach it.
struct SelectionBox: View {
    let state: SelectionState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state.symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? CleanerTheme.muted : CleanerTheme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .all ? "selected" : state == .some ? "partly selected" : "not selected")
    }
}

/// One selectable line: icon tile, name, a line of detail, a size, a tick.
struct CleanerRow: View {
    let symbol: String
    let title: String
    let detail: String
    let size: String
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(CleanerTheme.muted)
                .frame(width: 28, height: 28)
                .background(CleanerTheme.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(CleanerTheme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(size)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(CleanerTheme.muted)
            SelectionBox(state: isSelected ? .all : .none, label: title, action: toggle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        // The whole row is the target, not just the 15pt box.
        .onTapGesture(perform: toggle)
    }
}

/// A group's heading: its own tick box, its name, and what it adds up to.
struct CleanerGroupHeader: View {
    let title: String
    let state: SelectionState
    let size: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            SelectionBox(state: state, label: "Select all in \(title)", action: toggle)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                .foregroundStyle(CleanerTheme.muted)
            Spacer()
            Text(size).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(CleanerTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

/// The footer every tab shares: what is selected on the left, the one action on
/// the right.
struct CleanerActionBar: View {
    let summary: String
    let title: String
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary).font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color(hex: "#052E16") : CleanerTheme.muted)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(isEnabled ? CleanerTheme.accent : CleanerTheme.line)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || isBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(CleanerTheme.card)
        .overlay(alignment: .top) { Rectangle().fill(CleanerTheme.line).frame(height: 1) }
    }
}

/// Shown when a scan found nothing — which is a good outcome, and should read
/// like one.
struct CleanerEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(CleanerTheme.accent)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(CleanerTheme.text)
            Text(detail).font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
