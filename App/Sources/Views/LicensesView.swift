import SwiftUI

/// The open-source packages inside the app and their licenses (Licenses.json, made from the packages' own files).
struct LicensesView: View {
    struct Package: Decodable, Identifiable {
        let name: String
        let url: String
        let license: String
        let text: String
        var id: String { name }
    }

    private let packages: [Package] = {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Package].self, from: data)) ?? []
    }()

    var body: some View {
        List {
            Section {
                ForEach(packages) { p in
                    NavigationLink {
                        ScrollView {
                            Text(p.text).font(Theme.monoSmall).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(p.name)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent(p.name, value: p.license)
                    }
                }
            } footer: {
                Text("Deckhand is built with these open-source packages. Thank you to their authors.")
            }
        }
        .navigationTitle("Open-source licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
