import Foundation

/// Deadlines in the process-spawning test suites are **hang guards**, not
/// performance assertions: they exist so a genuinely stuck child fails the run
/// instead of blocking it forever.
///
/// A CI runner has far fewer cores and far more contention than a development
/// machine, and these tests spawn real child processes. The same wall-clock
/// bound that is generous locally is tight there — the observed failure mode
/// (PROBLEMS.md ISSUE-033) was five process-spawning tests timing out on CI
/// while passing locally, with every test in the run reporting the same ~16s
/// elapsed because they all started simultaneously.
///
/// Scale the guards up under CI rather than making the local suite slow.
/// GitHub Actions sets `CI=true`.
let ciDeadlineScale: Double = ProcessInfo.processInfo.environment["CI"] != nil ? 6.0 : 1.0

/// A hang-guard deadline in seconds, scaled for the environment.
func guardDeadline(_ seconds: Double) -> DispatchTime {
    .now() + seconds * ciDeadlineScale
}

/// A poll budget: how many iterations of a fixed interval to allow, scaled for CI.
func pollIterations(_ base: Int) -> Int {
    Int(Double(base) * ciDeadlineScale)
}
