import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case recent
    case repo(String)
}

/// The projects window: sidebar of repos, detail table of runs.
struct ProjectsView: View {
    @Environment(BoardModel.self) private var model
    @State private var selection: SidebarItem? = .overview
    @State private var search = ""
    @State private var filter: RunFilter = .all
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        // Present for every selection, so the toolbar (and its height) never comes and goes.
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Check GitHub for new runs now")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(model)
        }
    }

    private var sidebar: some View {
        let repos = model.sidebarRepos(filter: filter, search: search)
        return List(selection: $selection) {
            Label("All repositories", systemImage: "square.grid.2x2")
                .tag(SidebarItem.overview)
            Label("Recent activity", systemImage: "clock.arrow.circlepath")
                .tag(SidebarItem.recent)
            // With "Watched repositories", the ones you watch get their own section on top.
            let split = model.notifyScope == .watched
            let watched = split ? repos.filter { model.notifies($0.fullName) } : []
            let others = split ? repos.filter { !model.notifies($0.fullName) } : repos
            if !watched.isEmpty {
                Section("Watched") {
                    ForEach(watched) { repo in
                        RepoSidebarRow(repo: repo)
                            .tag(SidebarItem.repo(repo.fullName))
                    }
                }
            }
            Section(watched.isEmpty ? "Repositories" : "Other") {
                ForEach(others) { repo in
                    RepoSidebarRow(repo: repo)
                        .tag(SidebarItem.repo(repo.fullName))
                }
                if repos.isEmpty {
                    Text(model.repos.isEmpty ? "No repositories yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Filter", selection: $filter) {
                ForEach(RunFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .repo(let name):
            if let repo = model.repos.first(where: { $0.fullName == name }) {
                RepoDetail(repo: repo, filter: filter)
            } else {
                ContentUnavailableView("No runs", systemImage: "tray", description: Text(name))
            }
        case .overview, nil:
            OverviewDetail(
                repos: model.sidebarRepos(filter: filter, search: search),
                loaded: model.fetchedAt != nil,
                problem: model.problem,
                showRepo: { selection = .repo($0) }
            )
        case .recent:
            RecentActivityDetail(runs: model.activity(filter: filter, search: search), loaded: model.fetchedAt != nil, problem: model.problem)
        }
    }
}

private struct RepoSidebarRow: View {
    @Environment(BoardModel.self) private var model
    var repo: RepoSummary

    var body: some View {
        let naming = model.repoNaming
        HStack(spacing: 8) {
            StatusDot(signal: repo.latest?.signal ?? .neutral)
            VStack(alignment: .leading, spacing: 0) {
                Text(naming.name(repo.fullName)).lineLimit(1)
                if let owner = naming.owner(repo.fullName) {
                    Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            let live = repo.runs.filter(\.isLive).count
            if live > 0 {
                Text("\(live)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(GitHubColor.pending.opacity(0.18), in: Capsule())
                    .help("\(live) running")
            }
        }
        .help(repo.fullName)
        .contextMenu { NotifyMenuToggle(repoFullName: repo.fullName) }
    }
}

private struct RecentActivityDetail: View {
    var runs: [WorkflowRun]
    var loaded: Bool
    var problem: String?

    var body: some View {
        Group {
            if runs.isEmpty, !loaded, let problem {
                ContentUnavailableView(
                    "Can't reach GitHub",
                    systemImage: "exclamationmark.icloud",
                    description: Text(problem)
                )
            } else if runs.isEmpty {
                ContentUnavailableView(
                    loaded ? "No runs" : "Loading…",
                    systemImage: loaded ? "tray" : "hourglass",
                    description: Text(loaded ? "No workflow runs match." : "Fetching workflow runs from GitHub.")
                )
            } else {
                RunsTable(runs: runs, showRepo: true)
            }
        }
        .navigationTitle("Recent activity")
        // Always set a subtitle: the repo detail has one, and a subtitle makes the title bar taller.
        .navigationSubtitle(loaded ? "\(runs.count) run\(runs.count == 1 ? "" : "s")" : "Loading…")
    }
}

private struct RepoDetail: View {
    @Environment(BoardModel.self) private var model
    var repo: RepoSummary
    var filter: RunFilter

    var body: some View {
        let runs = repo.runs.filter(filter.matches)
        Group {
            if runs.isEmpty {
                ContentUnavailableView("No runs", systemImage: "tray", description: Text("No \(filter == .all ? "" : filter.rawValue.lowercased() + " ")runs in \(repo.fullName)."))
            } else {
                RunsTable(runs: runs, showRepo: false)
            }
        }
        .navigationTitle(model.repoNaming.name(repo.fullName))
        .navigationSubtitle(repo.latest.map { "Latest: \($0.signal.label)" } ?? "No runs")
        .toolbar {
            ToolbarItem {
                NotifyBell(repoFullName: repo.fullName)
            }
            ToolbarItem {
                Button {
                    if let url = RunFormat.repoActionsURL(repo.fullName) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
                .help("Open \(repo.fullName) Actions on GitHub")
            }
        }
    }
}

/// Runs as a table; double-click (or the context menu) opens a run on GitHub.
struct RunsTable: View {
    @Environment(BoardModel.self) private var model: BoardModel?
    var runs: [WorkflowRun]
    var showRepo: Bool
    @State private var selection: Set<WorkflowRun.ID> = []

    var body: some View {
        Table(runs, selection: $selection) {
            TableColumn("") { run in GitHubStatusIcon(run: run, size: 14) }
                .width(18)
            // `if` inside a TableColumnBuilder needs macOS 14.4; hide the column instead.
            TableColumn("Repository") { run in
                Text((model?.repoNaming ?? .full).name(run.repoFullName)).help(run.repoFullName)
            }
                .width(min: 100, ideal: 170)
                .defaultVisibility(showRepo ? .visible : .hidden)
            TableColumn("Workflow") { run in Text(run.workflowName) }
                .width(min: 80, ideal: 120)
            TableColumn("Title") { run in Text(run.displayTitle).help(run.displayTitle) }
                .width(min: 120, ideal: 240)
            TableColumn("Branch") { run in Text(run.headBranch ?? "—") }
                .width(min: 60, ideal: 100)
            TableColumn("Event") { run in Text(run.event).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 80)
            TableColumn("Actor") { run in Text(run.actorLogin ?? "—").foregroundStyle(.secondary) }
                .width(min: 50, ideal: 90)
            TableColumn("Started") { run in
                Text(run.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 110)
            TableColumn("Duration") { run in DurationText(run: run).monospacedDigit() }
                .width(min: 55, ideal: 70)
        }
        .contextMenu(forSelectionType: WorkflowRun.ID.self) { ids in
            Button("Open on GitHub") { open(ids) }
                .disabled(ids.isEmpty)
            if let id = ids.first, ids.count == 1, let run = runs.first(where: { $0.id == id }) {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.htmlURL, forType: .string)
                }
            }
        } primaryAction: { ids in
            open(ids)
        }
    }

    private func open(_ ids: Set<WorkflowRun.ID>) {
        for run in runs where ids.contains(run.id) { run.open() }
    }
}
