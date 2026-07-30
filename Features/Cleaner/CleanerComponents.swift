import SwiftUI

/// Green / amber / red for a 0–100 score.
///
/// System colours, so they follow the appearance and the accessibility
/// settings — and every place that uses this prints the number beside it, so
/// the colour is never the only thing carrying the meaning.
func cleanerScoreColor(_ score: Int) -> Color {
    switch score {
    case 70...: .green
    case 40..<70: .orange
    default: .red
    }
}

/// One selectable line in a cleaner list: symbol, name, detail, size, tick.
///
/// The tick is the system checkbox rather than a drawn square — it picks up the
/// accent colour, the focus ring, VoiceOver and the mixed state for free.
struct CleanerRow: View {
    let symbol: String
    let title: String
    let detail: String
    let size: String
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Select \(title)", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(size)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        // The whole row is the target, not just the checkbox.
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }
}

/// A group's heading: one checkbox for the whole group, its name, its subtotal.
///
/// `Toggle(sources:)` is what gives the box its third state — half-ticked when
/// only some of the group is chosen — without drawing it by hand.
struct CleanerGroupHeader: View {
    let title: String
    let size: String
    let selection: [Binding<Bool>]

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Select everything in \(title)", sources: selection, isOn: \.self)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text(title)
            Spacer()
            Text(size)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// The footer every tab shares: what is picked on the left, the one action on
/// the right.
struct CleanerActionBar: View {
    let summary: String
    let title: String
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if isBusy { ProgressView().controlSize(.small) }
            // Deliberately NOT .defaultAction: in three of the four tabs this
            // button deletes, and Return arriving from a stray focus should
            // never be what starts that.
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled || isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The heading over a list: the total, what it covers, and select-all.
///
/// The button's label and its action read the SAME value. They used to be
/// computed separately — "is everything ticked" for the label, "is nothing
/// ticked" for the action — so with a partial selection it said Select All and
/// cleared instead.
struct CleanerListHeader: View {
    let total: String
    let caption: String
    let hasRows: Bool
    let allSelected: Bool
    /// `true` = select everything, `false` = clear.
    let setAll: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(total)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(allSelected ? "Deselect All" : "Select All") { setAll(!allSelected) }
                .disabled(!hasRows)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
