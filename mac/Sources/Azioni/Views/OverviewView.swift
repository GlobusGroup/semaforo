import SwiftUI

/// "All repositories": one card per repo, most recently changed first, each with its latest runs.
struct OverviewDetail: View {
    var repos: [RepoSummary]
    var loaded: Bool
    var problem: String?
    /// Selects the repo in the sidebar.
    var showRepo: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 460, maximum: 900), spacing: 14, alignment: .top)]

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
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(repos) { repo in
                            RepoCard(repo: repo, showRepo: { showRepo(repo.fullName) })
                        }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle("All repositories")
        .navigationSubtitle(loaded ? "\(repos.count) repositor\(repos.count == 1 ? "y" : "ies") active in the last 24 hours" : "Loading…")
    }
}

private struct RepoCard: View {
    @Environment(BoardModel.self) private var model
    var repo: RepoSummary
    var showRepo: () -> Void

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
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 8)
                RelativeTime(date: repo.lastChange, style: .short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = RunFormat.repoActionsURL(repo.fullName) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .help("Open \(repo.fullName) Actions on GitHub")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

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
