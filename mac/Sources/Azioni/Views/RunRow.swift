import SwiftUI

/// Live-ticking or fixed duration text for a run.
struct DurationText: View {
    var run: WorkflowRun

    var body: some View {
        if run.isLive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RunFormat.duration(run.duration(now: context.date)))
            }
        } else {
            Text(RunFormat.duration(run.duration(now: .now)))
        }
    }
}

/// One run in a compact list: dot, "repo · workflow", "branch · title", and elapsed / age on the right.
struct RunRow: View {
    var run: WorkflowRun
    var highlighted = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GitHubStatusIcon(run: run, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // The repo name is what you scan for; let the workflow name truncate first.
                    Text(run.repoFullName)
                        .fontWeight(.medium)
                        .layoutPriority(1)
                    Text("·").foregroundStyle(.secondary)
                    Text(run.workflowName)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let branch = run.headBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(CompactLabelStyle())
                        Text("·")
                    }
                    Text(run.displayTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            trailing
                .font(.caption.monospacedDigit())
                .foregroundStyle(highlighted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        if run.isLive {
            DurationText(run: run)
        } else {
            Text(run.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
        }
    }
}

#if DEBUG
extension WorkflowRun {
    static func sample(
        id: Int = 1,
        repo: String = "acme/web",
        workflow: String = "CI",
        status: String = "completed",
        conclusion: String? = "success",
        minutesAgo: Double = 5
    ) -> WorkflowRun {
        let started = Date().addingTimeInterval(-minutesAgo * 60)
        return WorkflowRun(
            id: id, name: workflow, displayTitle: "Fix flaky login test", status: status,
            conclusion: conclusion, htmlURL: "https://github.com/\(repo)/actions/runs/\(id)",
            runStartedAt: started, createdAt: started, updatedAt: started.addingTimeInterval(150),
            headBranch: "main", event: "push", actorLogin: "octocat", repoFullName: repo,
            workflowName: workflow, runNumber: id
        )
    }
}

#Preview("RunRow") {
    VStack(alignment: .leading) {
        RunRow(run: .sample(id: 1, conclusion: "failure"), highlighted: true)
        RunRow(run: .sample(id: 2, status: "in_progress", conclusion: nil, minutesAgo: 2))
        RunRow(run: .sample(id: 3, status: "queued", conclusion: nil, minutesAgo: 0.5))
        RunRow(run: .sample(id: 4))
        RunRow(run: .sample(id: 5, conclusion: "cancelled"))
    }
    .padding()
    .frame(width: MenuView.width)
}
#endif

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
