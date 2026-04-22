import Foundation
import CairnCore

/// Umbrella module for iOS-side concrete implementations of `CairnCore`
/// protocols. Each concrete type lives in its own file. SwiftData and
/// UserDefaults backings work on macOS too (used by tests); PhotoKit-backed
/// types are gated by `#if canImport(Photos)`.
public enum CairnIOSCore {}
