import SwiftUI
import PaircastShared

@MainActor
final class ReportsViewModel: ObservableObject {
    @Published var filter: ReportFilter = .pending
    @Published private(set) var reports: [UserReport] = []
    @Published private(set) var total = 0
    @Published private(set) var pending = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyId: Int64?

    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    var hasMore: Bool { reports.count < total }

    func load(append: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await session.graph.loadReports.invoke(
                filter: filter,
                offset: append ? Int32(reports.count) : 0,
                limit: LoadReportsUseCase.companion.PAGE_SIZE
            )
            let known = append ? Set(reports.map(\.id)) : []
            let fresh = page.reports.filter { !known.contains($0.id) }
            reports = append ? reports + fresh : fresh
            total = Int(page.total)
            pending = Int(page.pending)
        } catch {
            errorMessage = TandemL10n.message(for: error, fallback: .network)
        }
    }

    func resolve(_ report: UserReport, action: ReportAction) async {
        busyId = report.id
        defer { busyId = nil }
        do {
            try await session.graph.resolveReport.invoke(report: report, action: action)
            let closed: Set<Int64> = action == .ban
                ? Set(reports.filter { $0.targetId == report.targetId && $0.isPending }.map(\.id))
                : [report.id]
            reports.removeAll { closed.contains($0.id) }
            total = max(0, total - closed.count)
            pending = max(0, pending - closed.count)
            session.showToast(action == .ban
                ? TandemL10n.format("Banned {{name}}", ["name": report.targetName])
                : TandemL10n.string("Report ignored"))
        } catch {
            session.showToast(TandemL10n.message(for: error, fallback: .network))
        }
    }
}

/// Admin-only: review chat reports, ignore them or ban the reported user.
struct ReportsView: View {
    @StateObject private var viewModel: ReportsViewModel
    @State private var confirmBan: UserReport?

    init(session: AppSession) {
        _viewModel = StateObject(wrappedValue: ReportsViewModel(session: session))
    }

    var body: some View {
        List {
            Section {
                Picker("Reports", selection: $viewModel.filter) {
                    Text(viewModel.pending > 0
                        ? TandemL10n.format("Pending ({{count}})", ["count": String(viewModel.pending)])
                        : TandemL10n.string("Pending"))
                        .tag(ReportFilter.pending)
                    Text("Handled").tag(ReportFilter.handled)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if viewModel.reports.isEmpty {
                Section {
                    placeholder
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(viewModel.reports, id: \.id) { report in
                    Section {
                        ReportRow(
                            report: report,
                            busy: viewModel.busyId == report.id,
                            onIgnore: { Task { await viewModel.resolve(report, action: .ignore) } },
                            onBan: { confirmBan = report }
                        )
                    }
                }
                if viewModel.hasMore {
                    Section {
                        Button {
                            Task { await viewModel.load(append: true) }
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isLoading { ProgressView() } else { Text("Load more") }
                                Spacer()
                            }
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
            }
        }
        .listSectionSpacing(12)
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .task(id: viewModel.filter) { await viewModel.load() }
        .confirmationDialog(
            confirmBan.map { TandemL10n.format("Ban {{name}}?", ["name": $0.targetName]) } ?? "",
            isPresented: Binding(get: { confirmBan != nil }, set: { if !$0 { confirmBan = nil } }),
            titleVisibility: .visible,
            presenting: confirmBan
        ) { report in
            Button("Ban User", role: .destructive) {
                Task { await viewModel.resolve(report, action: .ban) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They are signed out right away and can no longer sign in. Their other pending reports are closed as well.")
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if viewModel.isLoading {
            ProgressView()
        } else if let error = viewModel.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TandemColors.secondaryLabel)
                Button("Retry") { Task { await viewModel.load() } }
            }
        } else {
            Text(viewModel.filter == .pending ? "No pending reports" : "No handled reports yet")
                .foregroundStyle(TandemColors.secondaryLabel)
        }
    }
}

private struct ReportRow: View {
    let report: UserReport
    let busy: Bool
    let onIgnore: () -> Void
    let onBan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(TandemL10n.format("Reported user: {{name}}", ["name": report.targetName]))
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                statusBadge
            }
            if let content {
                Text(content)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(TandemColors.groupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text(TandemL10n.format("Reported by {{name}} · {{time}}", ["name": report.reporterName, "time": time]))
                .font(.system(size: 12))
                .foregroundStyle(TandemColors.secondaryLabel)
            if report.isPending {
                HStack(spacing: 10) {
                    Button(action: onIgnore) {
                        Text("Ignore").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive, action: onBan) {
                        Text("Ban User").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(report.targetBanned)
                }
                .disabled(busy)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var content: String? {
        switch report.content {
        case "": nil
        case "[Sticker]": TandemL10n.string("[Sticker]")
        default: report.content
        }
    }

    private var time: String {
        Date(timeIntervalSince1970: TimeInterval(report.createdAtMs) / 1000)
            .formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(TandemL10n.locale))
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = if report.status == .banned || report.targetBanned {
            (TandemL10n.string("Banned"), TandemColors.danger)
        } else if report.status == .ignored {
            (TandemL10n.string("Ignored"), TandemColors.secondaryLabel)
        } else {
            (TandemL10n.string("Pending"), TandemColors.systemBlue)
        }
        return Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
