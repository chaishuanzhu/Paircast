import SwiftUI
import PaircastShared

/// Admin-only hub: user management, adding users and chat reports.
struct AdminView: View {
    let session: AppSession
    @State private var pendingReports = 0

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UsersView(session: session)
                } label: {
                    row("User Management", systemImage: "person.2.fill", color: TandemColors.systemBlue)
                }
                NavigationLink {
                    AddUserView(session: session)
                } label: {
                    row("Add User", systemImage: "person.badge.plus", color: .green)
                }
                NavigationLink {
                    ReportsView(session: session)
                } label: {
                    row("Reports", systemImage: "flag.fill", color: TandemColors.danger)
                }
                .badge(pendingReports)
            }
        }
        .navigationTitle("Admin Console")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let page = try? await session.graph.loadReports.invoke(filter: .pending, offset: 0, limit: 1)
            pendingReports = page.map { Int($0.pending) } ?? 0
        }
    }

    private func row(_ title: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
