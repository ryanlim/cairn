import Foundation
import CairnCore

/// Namespace marker for the iOS-side concrete implementations of
/// `CairnCore`'s protocols. Each concrete type lives in its own
/// file. SwiftData and UserDefaults backings compile and run on
/// macOS too (used by the cross-platform test suite); PhotoKit-backed
/// types are gated by `#if canImport(Photos)`.
public enum CairnIOSCore {}
