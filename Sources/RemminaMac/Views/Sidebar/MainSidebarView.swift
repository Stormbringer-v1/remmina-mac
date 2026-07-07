import SwiftUI
import SwiftData
import AppKit

struct MainSidebarView: View {
    let profiles: [ConnectionProfile]
    @Binding var selectedProfile: ConnectionProfile?
    @Binding var filterMode: MainView.FilterMode
    
    let onConnect: (ConnectionProfile) -> Void
    let onFavorite: (ConnectionProfile) -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onDelete: (ConnectionProfile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filterMode) {
                ForEach(MainView.FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(profiles, id: \.id, selection: $selectedProfile) { profile in
                ProfileRowView(profile: profile)
                    .tag(profile)
                    .onTapGesture(count: 2) {
                        onConnect(profile)
                    }
                    .contextMenu {
                        Button("Connect") { onConnect(profile) }
                        Divider()
                        Button(profile.isFavorite ? "Unfavorite" : "Favorite") { onFavorite(profile) }
                        Button("Copy Host") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(profile.host, forType: .string)
                        }
                        if !profile.username.isEmpty {
                            Button("Copy Username") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(profile.username, forType: .string)
                            }
                        }
                        Divider()
                        Button("Edit…") { onEdit(profile) }
                        Button("Delete", role: .destructive) { onDelete(profile) }
                    }
            }
            .listStyle(.sidebar)
        }
    }
}
