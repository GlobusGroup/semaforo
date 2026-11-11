import SwiftUI

/// "All repositories": one card per repo, most recently changed first, each with its latest runs.
struct OverviewDetail: View {
    var repos: [RepoSummary]
    var loaded: Bool
    var problem: String?
    /// Selects the repo in the sidebar.
    var showRepo: (String) -> Void

    private static let minColumnWidth: CGFloat = 460
    private static let spacing: CGFloat = 14

    var body: some View {
        Group {
            if repos.isEmpty, !loaded, let problem {
                ContentUnavailableView("Can't reach GitHub", systemImage: "exclamationmark.icloud", description: Text(problem))
            } else if repos.isEmpty {
                ContentUnavailableView(
                    loaded ? "Nothing in the last 24 hours" : "Loading…",
                    systemImage: loaded ? "tray" : "hourglass",
                    description: Text(loaded ? "No workflow runs started in the last 24 hours match." : "Fetching workflow runs from GitHub.")
                )
            } else {
                GeometryReader { geo in
                    let count = max(1, Int((geo.size.width - 32 + Self.spacing) / (Self.minColumnWidth + Self.spacing)))
                    ScrollView {
                        // Masonry: a grid makes every row as tall as its tallest card, which leaves
                        // holes under short cards. Columns that stack independently don't.
                        HStack(alignment: .top, spacing: Self.spacing) {
                            ForEach(Array(Self.columns(repos, count: count).enumerated()), id: \.offset) { _, column in
                                LazyVStack(spacing: Self.spacing) {
                                    ForEach(column) { repo in
                                        RepoCard(repo: repo, showRepo: { showRepo(repo.fullName) })
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                        .padding(16)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("All repositories")
        .navigationSubtitle(loaded ? "\(repos.count) repositor\(repos.count == 1 ? "y" : "ies") active in the last 24 hours" : "Loading…")
    }
}

extension OverviewDetail {
    /// Deals cards, in order, onto whichever column is shortest so far. Height is estimated from the
    /// run count (header ≈ 1.2 rows), so the newest repos stay at the top, left to right.
    static func columns(_ repos: [RepoSummary], count: Int) -> [[RepoSummary]] {
        var columns = Array(repeating: [RepoSummary](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for repo in repos {
            let i = heights.indices.min { heights[$0] < heights[$1] }!
            columns[i].append(repo)
            heights[i] += 1.2 + Double(repo.runs.count)
        }
        return columns
    }
}

private struct RepoCard: View {
    @Environment(BoardModel.self) private var model
    var repo: RepoSummary
    var showRepo: () -> Void
    @State private var hovering = false

    var body: some View {
        let naming = model.repoNaming
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: showRepo) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(naming.name(repo.fullName)).font(.headline)
                        if let owner = naming.owner(repo.fullName) {
                            Text(owner).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Show all runs for \(repo.fullName)")

                let live = repo.runs.filter(\.isLive).count
                if live > 0 {
                    Text("\(live) running")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(GitHubColor.pending)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(GitHubColor.pending.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 8)
                // Controls appear on hover. They stay in the layout (just transparent) so the
                // header never changes height; a watched repo keeps its bell visible as a marker.
                let watched = model.notifyScope == .watched && model.notifies(repo.fullName)
                NotifyBell(repoFullName: repo.fullName)
                    .opacity(hovering || watched ? 1 : 0)
                Button {
                    if let url = RunFormat.repoActionsURL(repo.fullName) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open \(repo.fullName) Actions on GitHub")
                .opacity(hovering ? 1 : 0)
            }
            .frame(height: 22)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contextMenu { NotifyMenuToggle(repoFullName: repo.fullName) }

            Divider()

            VStack(spacing: 0) {
                ForEach(repo.runs) { run in
                    CardRunRow(run: run)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One line per run: status, workflow, title, branch, when, how long. Click opens it on GitHub.
private struct CardRunRow: View {
    var run: WorkflowRun
    @State private var hovering = false

    var body: some View {
        Button { run.open() } label: {
            HStack(spacing: 8) {
                GitHubStatusIcon(run: run)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.displayTitle)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(run.workflowName)
                        if let branch = run.headBranch {
                            Text("·")
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .labelStyle(CompactLabelStyle())
                        }
                        if let actor = run.actorLogin {
                            Text("·")
                            Text(actor)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                // GitHub's run-list style: calendar + "46 minutes ago", stopwatch + "1m 13s".
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        RelativeTime(date: run.startedAt)
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    Label {
                        DurationText(run: run)
                    } icon: {
                        Image(systemName: "stopwatch")
                    }
                }
                .labelStyle(MetaLabelStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.08) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open run #\(run.runNumber) on GitHub")
        .contextMenu {
            Button("Open on GitHub") { run.open() }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.htmlURL, forType: .string)
            }
        }
    }
}

/// Icon in a fixed-width column so the two lines' text lines up, as on GitHub.
private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .frame(width: 14, alignment: .center)
            configuration.title
                .lineLimit(1)
        }
    }
}
