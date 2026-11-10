import AppKit
import Foundation
import UserNotifications

@MainActor
protocol Notifying: AnyObject {
    /// Ask for permission (first launch); safe to call every launch.
    func requestAuthorization()
    /// One notification per run, or a single summary when more than 3.
    func notifyFailures(_ runs: [WorkflowRun])
}

/// What one posted notification contains; the pure output of `Notifier.plan(for:)`.
struct NotificationContent: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    /// Opened on click (the run's html_url).
    var url: String?
}

/// UNUserNotificationCenter-backed notifier; clicking opens the run's html_url.
@MainActor
final class Notifier: NSObject, Notifying {
    /// More failures than this in one scan collapse into a single summary.
    nonisolated static let maxIndividual = 3
    nonisolated static let urlKey = "url"

    private var configuredCenter: UNUserNotificationCenter?

    /// nil without an app bundle (e.g. `swift test`), where `.current()` would crash.
    private var center: UNUserNotificationCenter? {
        if let configuredCenter { return configuredCenter }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configuredCenter = center
        return center
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyFailures(_ runs: [WorkflowRun]) {
        guard let center else { return }
        for item in Self.plan(for: runs) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            if let url = item.url { content.userInfo = [Self.urlKey: url] }
            let request = UNNotificationRequest(
                identifier: item.identifier, content: content, trigger: nil
            )
            center.add(request) { _ in }
        }
    }

    /// ≤3 runs → one notification each; more → a single "N workflows failed" summary.
    nonisolated static func plan(for runs: [WorkflowRun]) -> [NotificationContent] {
        guard !runs.isEmpty else { return [] }
        if runs.count <= maxIndividual {
            return runs.map { run in
                NotificationContent(
                    identifier: "run-\(run.id)",
                    title: title(for: run),
                    body: run.displayTitle,
                    url: run.htmlURL
                )
            }
        }
        let repos = orderedUnique(runs.map(\.repoFullName))
        let shown = repos.prefix(3).joined(separator: ", ")
        let more = repos.count > 3 ? " and \(repos.count - 3) more" : ""
        return [
            NotificationContent(
                identifier: "failures-" + runs.map { String($0.id) }.joined(separator: "-"),
                title: "\(runs.count) workflows failed",
                body: shown + more,
                url: runs.first?.htmlURL
            ),
        ]
    }

    /// "org/repo · CI failed on main".
    nonisolated static func title(for run: WorkflowRun) -> String {
        let workflow = run.workflowName.isEmpty ? run.name : run.workflowName
        var title = "\(run.repoFullName) · \(workflow) failed"
        if let branch = run.headBranch, !branch.isEmpty { title += " on \(branch)" }
        return title
    }

    private nonisolated static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is active (menu open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking a notification opens the run on GitHub.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let string = info[Notifier.urlKey] as? String, let url = URL(string: string) {
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
