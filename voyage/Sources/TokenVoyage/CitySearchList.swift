import SwiftUI
import VoyageCore

/// Onboarding and settings use the same searchable, lazily rendered home-city list.
struct CitySearchList: View {
    @Environment(\.theme) private var theme
    @Environment(\.l10n) private var l10n
    let catalog: CityCatalog
    @Binding var selection: String
    @Binding var search: String

    // The catalog caches ordering and matching. Read it on the first render too,
    // so both windows and synchronous snapshots start with populated rows.
    private var results: [City] { catalog.cities(matching: search, language: l10n.language) }

    var body: some View {
        let results = results
        VStack(alignment: .leading, spacing: 10) {
            TextField(l10n("onboarding.search"), text: $search)
                .textFieldStyle(.plain).padding(10).background(theme.surfaceRaised).pixelBorder(theme.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { city in
                        Button { selection = city.id } label: {
                            Text(l10n.cityName(city) + " · " + l10n.countryName(catalog.countryNames(city.countryCode)))
                                .font(Theme.pixel()).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(selection == city.id ? theme.selectedText : theme.text)
                                .background(selection == city.id ? theme.selectedFill : theme.surfaceRaised)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == city.id ? .isSelected : [])
                    }
                    if results.isEmpty {
                        Text(l10n("city.noMatches")).font(Theme.pixel()).foregroundStyle(theme.textMuted).padding(10)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
