import Foundation
import Testing
@testable import CairnIOSCore

/// Pins the contract on `CairnAppModel`'s sync narration surface:
/// the activity ring buffer, the phase timeline, and the phase
/// transition helper. These behave like a small state machine; the
/// reconciler + AppDependencies wiring (commit 2 of the narration
/// plan) drives this state from real PhotoKit events, but the model
/// surface stands on its own and is tested without a host.
@Suite("CairnAppModel — sync narration")
struct SyncActivityTests {

    // MARK: - Activity ring buffer

    @Test("appendSyncActivity inserts newest-first")
    @MainActor
    func appendInsertsNewestFirst() {
        let model = CairnAppModel()
        let now = Date()
        model.appendSyncActivity(.init(timestamp: now, kind: .note, detail: "first"))
        model.appendSyncActivity(.init(timestamp: now.addingTimeInterval(1), kind: .note, detail: "second"))
        #expect(model.syncActivity.count == 2)
        #expect(model.syncActivity[0].detail == "second")
        #expect(model.syncActivity[1].detail == "first")
    }

    @Test("appendSyncActivity respects the cap")
    @MainActor
    func appendRespectsCap() {
        let model = CairnAppModel()
        let cap = CairnAppModel.syncActivityCap
        for i in 0..<(cap + 10) {
            model.appendSyncActivity(.init(kind: .note, detail: "n\(i)"))
        }
        #expect(model.syncActivity.count == cap)
        // The oldest 10 should have been evicted; the newest should be on top.
        #expect(model.syncActivity[0].detail == "n\(cap + 9)")
        #expect(model.syncActivity.last?.detail == "n10")
    }

    @Test("resetSyncNarration clears both buffers")
    @MainActor
    func resetClears() {
        let model = CairnAppModel()
        model.appendSyncActivity(.init(kind: .note, detail: "x"))
        model.transitionSyncPhase(to: .preparing)
        #expect(!model.syncActivity.isEmpty)
        #expect(!model.syncTimeline.isEmpty)
        model.resetSyncNarration()
        #expect(model.syncActivity.isEmpty)
        #expect(model.syncTimeline.isEmpty)
    }

    // MARK: - Phase transitions

    @Test("transition closes prior duration and opens the next phase")
    @MainActor
    func transitionClosesPrior() {
        let model = CairnAppModel()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(1.5)
        let t2 = t1.addingTimeInterval(2.0)

        model.transitionSyncPhase(to: .preparing, at: t0)
        #expect(model.syncPhase == .preparing)
        #expect(model.syncTimeline.count == 1)
        #expect(model.syncTimeline[0].durationMs == nil)

        model.transitionSyncPhase(to: .hashing, at: t1)
        #expect(model.syncPhase == .hashing)
        #expect(model.syncTimeline.count == 2)
        #expect(model.syncTimeline[0].durationMs == 1500)
        #expect(model.syncTimeline[1].durationMs == nil)

        model.transitionSyncPhase(to: .idle, at: t2)
        #expect(model.syncPhase == .idle)
        // The hashing entry closed; .idle does not push a new row.
        #expect(model.syncTimeline.count == 2)
        #expect(model.syncTimeline[1].durationMs == 2000)
    }

    @Test("transition is idempotent on identical phase")
    @MainActor
    func transitionIdempotent() {
        let model = CairnAppModel()
        let t0 = Date()
        model.transitionSyncPhase(to: .hashing, at: t0)
        model.transitionSyncPhase(to: .hashing, at: t0.addingTimeInterval(1))
        #expect(model.syncTimeline.count == 1)
        #expect(model.syncPhase == .hashing)
    }

    @Test("timeline preserves phase order across transitions")
    @MainActor
    func timelinePreservesOrder() {
        let model = CairnAppModel()
        let now = Date()
        let phases: [CairnAppModel.SyncPhase] = [
            .preparing, .fetchingServer, .hashing, .reconciling, .finalizing,
        ]
        for (i, p) in phases.enumerated() {
            model.transitionSyncPhase(to: p, at: now.addingTimeInterval(Double(i)))
        }
        #expect(model.syncTimeline.map(\.phase) == phases)
    }

    // MARK: - SyncPhase display labels

    @Test("each SyncPhase has a non-empty display name")
    func phaseDisplayNames() {
        let cases: [CairnAppModel.SyncPhase] = [
            .idle, .preparing, .fetchingServer, .hashing, .reconciling, .finalizing,
        ]
        for c in cases {
            #expect(!c.displayName.isEmpty)
        }
    }

    // MARK: - SyncDetailSheet duration formatter

    @Test("SyncDetailSheet duration formatter — sub-second")
    func durationFormatterSubSecond() {
        #expect(SyncDetailSheet.formatDuration(ms: 0) == "0ms")
        #expect(SyncDetailSheet.formatDuration(ms: 240) == "240ms")
        #expect(SyncDetailSheet.formatDuration(ms: 999) == "999ms")
    }

    @Test("SyncDetailSheet duration formatter — seconds")
    func durationFormatterSeconds() {
        #expect(SyncDetailSheet.formatDuration(ms: 1000) == "1.0s")
        #expect(SyncDetailSheet.formatDuration(ms: 12_400) == "12.4s")
        #expect(SyncDetailSheet.formatDuration(ms: 59_999) == "60.0s")
    }

    @Test("SyncDetailSheet duration formatter — minutes")
    func durationFormatterMinutes() {
        #expect(SyncDetailSheet.formatDuration(ms: 60_000) == "1m 0s")
        #expect(SyncDetailSheet.formatDuration(ms: 90_500) == "1m 30s")
        #expect(SyncDetailSheet.formatDuration(ms: 600_000) == "10m 0s")
    }

    // MARK: - ETA coefficient-of-variation

    @Test("CV — below minSamples returns nil")
    func cvBelowMin() {
        #expect(InitialScanScreen.coefficientOfVariation(of: [], minSamples: 3) == nil)
        #expect(InitialScanScreen.coefficientOfVariation(of: [10], minSamples: 3) == nil)
        #expect(InitialScanScreen.coefficientOfVariation(of: [10, 12], minSamples: 3) == nil)
    }

    @Test("CV — identical samples produce 0")
    func cvIdentical() {
        let cv = InitialScanScreen.coefficientOfVariation(of: [60, 60, 60, 60, 60], minSamples: 3)
        #expect(cv == 0.0)
    }

    @Test("CV — small drift gives small CV (< 5%)")
    func cvSmallDrift() {
        // ETAs of 600 ± ~3% (590, 605, 600, 595, 610). CV should be
        // well under 5% — high confidence territory.
        let samples: [TimeInterval] = [590, 605, 600, 595, 610]
        let cv = InitialScanScreen.coefficientOfVariation(of: samples, minSamples: 3) ?? 1.0
        #expect(cv < 0.05)
    }

    @Test("CV — bouncing samples push past 15%")
    func cvBouncing() {
        // ETA bouncing between 300 and 800. CV should clear the 15%
        // threshold easily — low confidence territory.
        let samples: [TimeInterval] = [300, 800, 400, 750, 350]
        let cv = InitialScanScreen.coefficientOfVariation(of: samples, minSamples: 3) ?? 0.0
        #expect(cv > 0.15)
    }

    @Test("CV — non-positive mean returns nil")
    func cvNonPositiveMean() {
        // Degenerate (negative ETA shouldn't happen but guard works).
        let cv = InitialScanScreen.coefficientOfVariation(of: [-10, -10, -10], minSamples: 3)
        #expect(cv == nil)
    }
}
