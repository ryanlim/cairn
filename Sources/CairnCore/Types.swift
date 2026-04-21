import Foundation

public struct Checksum: Hashable, Sendable, Codable, CustomStringConvertible {
    public let base64: String

    public init(base64: String) {
        self.base64 = base64
    }

    public var description: String { base64 }
}

public struct ServerAsset: Hashable, Sendable, Codable {
    public let id: String
    public let checksum: Checksum
    public let livePhotoVideoId: String?
    public let isTrashed: Bool

    public init(id: String, checksum: Checksum, livePhotoVideoId: String? = nil, isTrashed: Bool = false) {
        self.id = id
        self.checksum = checksum
        self.livePhotoVideoId = livePhotoVideoId
        self.isTrashed = isTrashed
    }
}

public struct RunID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: String

    public init(value: String = UUID().uuidString) {
        self.value = value
    }

    public var description: String { value }
}
