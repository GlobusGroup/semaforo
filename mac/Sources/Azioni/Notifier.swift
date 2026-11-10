import Foundation

@MainActor
protocol Notifying: AnyObject {
    /// Ask for permission (first launch); safe to call every launch.
    func requestAuthorization()
    /// One notification per run, or a single summary when more than 3.
    func notifyFailures(_ runs: [WorkflowRun])
}

/// UNUserNotificationCenter-backed notifier; clicking opens the run's html_url.
@MainActor
final class Notifier: NSObject, Notifying {
    func requestAuthorization() {
        // TODO(agent: model)
    }

    func notifyFailures(_ runs: [WorkflowRun]) {
        // TODO(agent: model)
    }
}
