import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LaxifyMetrics.sectionSpacing) {
                header

                searchField
            }
            .padding(.horizontal, LaxifyMetrics.screenPadding)
            .padding(.top, 12)
        }
        .background(LaxifyPalette.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Поиск")
                .font(LaxifyTypography.largeTitle)
                .foregroundStyle(LaxifyPalette.textPrimary)

            Spacer()

            Button("Готово") {
                dismiss()
            }
            .font(LaxifyTypography.headline)
            .foregroundStyle(LaxifyPalette.accent)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LaxifyPalette.textTertiary)
            TextField("Треки, артисты", text: $query)
                .foregroundStyle(LaxifyPalette.textPrimary)
        }
        .font(LaxifyTypography.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .laxGlassCapsule()
    }
}

#Preview {
    SearchView()
}
