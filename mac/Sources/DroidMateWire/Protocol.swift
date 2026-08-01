// DroidMateWire — shared wire protocol (Foundation only).
// Used by the Mac app and available to MCP for future Data Channel work.
// See docs/PROTOCOL.md and docs/adr/0004-mcp-uses-adb-not-data-channel.md.
//
// Frame layout (little-endian):
//   [u16 streamId][u16 msgType][u32 payloadLen][payload bytes]

import Foundation

public enum StreamId {
    public static let control: UInt16 = 0x0000
    public static let files: UInt16 = 0x0003
    public static let clipboard: UInt16 = 0x0004
    public static let notifications: UInt16 = 0x0005
}

public enum MsgType {
    public static let hello: UInt16 = 0x0001
    public static let helloAck: UInt16 = 0x0002
    public static let ping: UInt16 = 0x0010
    public static let pong: UInt16 = 0x0011
    public static let error: UInt16 = 0x00FF

    public static let listDir: UInt16 = 0x0300
    public static let dirEntry: UInt16 = 0x0301
    public static let uploadStart: UInt16 = 0x0310
    public static let uploadData: UInt16 = 0x0311
    public static let uploadComplete: UInt16 = 0x0312
    public static let uploadAbort: UInt16 = 0x0313
    public static let downloadStart: UInt16 = 0x0320
    public static let downloadData: UInt16 = 0x0321
    public static let downloadComplete: UInt16 = 0x0322
    public static let downloadCancel: UInt16 = 0x0323

    public static let fsDelete: UInt16 = 0x0330
    public static let fsDeleteResult: UInt16 = 0x0331
    public static let fsRename: UInt16 = 0x0332
    public static let fsRenameResult: UInt16 = 0x0333
    public static let fsMkdir: UInt16 = 0x0334
    public static let fsMkdirResult: UInt16 = 0x0335
    public static let fsCopy: UInt16 = 0x0336
    public static let fsCopyResult: UInt16 = 0x0337

    public static let clipboardSync: UInt16 = 0x0400

    public static let notificationAdded: UInt16 = 0x0500
    public static let notificationRemoved: UInt16 = 0x0501
}

public enum ErrorCode {
    public static let protocolVersionMismatch = "PROTOCOL_VERSION_MISMATCH"
    public static let unknownMessage = "UNKNOWN_MESSAGE"
    public static let malformedPayload = "MALFORMED_PAYLOAD"
    public static let capabilityNotSupported = "CAPABILITY_NOT_SUPPORTED"
    public static let projectionRevoked = "PROJECTION_REVOKED"
    public static let inputPermissionDenied = "INPUT_PERMISSION_DENIED"
    public static let fileNotFound = "FILE_NOT_FOUND"
    public static let filePermissionDenied = "FILE_PERMISSION_DENIED"
    public static let fileExists = "FILE_EXISTS"
    public static let fileIoError = "FILE_IO_ERROR"
}

// MARK: - FS mutation payloads

public struct FSDeleteRequest: Codable, Equatable, Sendable {
    public var reqId: Int
    public var paths: [String]
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case paths
    }
    public init(reqId: Int, paths: [String]) {
        self.reqId = reqId
        self.paths = paths
    }
}

public struct FSPathResult: Codable, Equatable, Sendable {
    public var path: String
    public var success: Bool
    public var error: String?
    public init(path: String, success: Bool, error: String? = nil) {
        self.path = path
        self.success = success
        self.error = error
    }
}

public struct FSDeleteResult: Codable, Equatable, Sendable {
    public var reqId: Int
    public var results: [FSPathResult]
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case results
    }
    public init(reqId: Int, results: [FSPathResult]) {
        self.reqId = reqId
        self.results = results
    }
}

public struct FSRenameRequest: Codable, Equatable, Sendable {
    public var reqId: Int
    public var from: String
    public var to: String
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case from, to
    }
    public init(reqId: Int, from: String, to: String) {
        self.reqId = reqId
        self.from = from
        self.to = to
    }
}

public struct FSCopyRequest: Codable, Equatable, Sendable {
    public var reqId: Int
    public var from: String
    public var to: String
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case from, to
    }
    public init(reqId: Int, from: String, to: String) {
        self.reqId = reqId
        self.from = from
        self.to = to
    }
}

public struct FSMkdirRequest: Codable, Equatable, Sendable {
    public var reqId: Int
    public var path: String
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case path
    }
    public init(reqId: Int, path: String) {
        self.reqId = reqId
        self.path = path
    }
}

public struct FSOpResult: Codable, Equatable, Sendable {
    public var reqId: Int
    public var success: Bool
    public var error: String?
    public enum CodingKeys: String, CodingKey {
        case reqId = "req_id"
        case success, error
    }
    public init(reqId: Int, success: Bool, error: String? = nil) {
        self.reqId = reqId
        self.success = success
        self.error = error
    }
}

// MARK: - Control payloads

public struct Hello: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public var protocolVersion: Int
    public var clientName: String
    public var osVersion: String
    public var capabilities: [String]

    public enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case clientName = "client_name"
        case osVersion = "os_version"
        case capabilities
    }

    public init(
        protocolVersion: Int = Hello.currentProtocolVersion,
        clientName: String,
        osVersion: String,
        capabilities: [String]
    ) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.osVersion = osVersion
        self.capabilities = capabilities
    }
}

public struct HelloAck: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverName: String
    public var deviceModel: String
    public var androidVersion: String
    public var screenWidth: Int
    public var screenHeight: Int
    public var screenDpi: Int
    public var capabilities: [String]
    public var supportedEncoders: [String]
    public var isRooted: Bool

    public enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case serverName = "server_name"
        case deviceModel = "device_model"
        case androidVersion = "android_version"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case screenDpi = "screen_dpi"
        case capabilities
        case supportedEncoders = "supported_encoders"
        case isRooted = "is_rooted"
    }

    public init(
        protocolVersion: Int,
        serverName: String,
        deviceModel: String,
        androidVersion: String,
        screenWidth: Int,
        screenHeight: Int,
        screenDpi: Int,
        capabilities: [String],
        supportedEncoders: [String] = [],
        isRooted: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.deviceModel = deviceModel
        self.androidVersion = androidVersion
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenDpi = screenDpi
        self.capabilities = capabilities
        self.supportedEncoders = supportedEncoders
        self.isRooted = isRooted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        serverName = try c.decode(String.self, forKey: .serverName)
        deviceModel = try c.decode(String.self, forKey: .deviceModel)
        androidVersion = try c.decode(String.self, forKey: .androidVersion)
        screenWidth = try c.decode(Int.self, forKey: .screenWidth)
        screenHeight = try c.decode(Int.self, forKey: .screenHeight)
        screenDpi = try c.decode(Int.self, forKey: .screenDpi)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        supportedEncoders = try c.decodeIfPresent([String].self, forKey: .supportedEncoders) ?? []
        isRooted = try c.decodeIfPresent(Bool.self, forKey: .isRooted) ?? false
    }
}

public struct ErrorMsg: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
    public var ts: Int64
    public var source: String
    public var mime: String
    public var text: String
    public init(ts: Int64, source: String, mime: String, text: String) {
        self.ts = ts
        self.source = source
        self.mime = mime
        self.text = text
    }
}

public struct NotificationAddedPayload: Codable, Equatable, Sendable {
    public var ts: Int64
    public var key: String
    public var package: String
    public var id: Int
    public var tag: String?
    public var title: String
    public var text: String
    public var category: String?
    public init(
        ts: Int64,
        key: String,
        package: String,
        id: Int,
        tag: String? = nil,
        title: String,
        text: String,
        category: String? = nil
    ) {
        self.ts = ts
        self.key = key
        self.package = package
        self.id = id
        self.tag = tag
        self.title = title
        self.text = text
        self.category = category
    }
}

public struct NotificationRemovedPayload: Codable, Equatable, Sendable {
    public var ts: Int64
    public var key: String
    public var reason: String
    public init(ts: Int64, key: String, reason: String) {
        self.ts = ts
        self.key = key
        self.reason = reason
    }
}

// MARK: - Frame codec

public enum FrameHeader {
    public static let sizeBytes = 8
    public static let maxPayload = 16 * 1024 * 1024
}

public struct Frame: Sendable {
    public let streamId: UInt16
    public let msgType: UInt16
    public let payload: Data

    public init(streamId: UInt16, msgType: UInt16, payload: Data) {
        self.streamId = streamId
        self.msgType = msgType
        self.payload = payload
    }
}

public enum WireJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .useDefaultKeys
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()
}

public enum FrameParser {
    public static func parse(from data: inout Data) -> [Frame] {
        var frames: [Frame] = []
        while data.count >= FrameHeader.sizeBytes {
            let streamId = readLE16(data, at: 0)
            let msgType = readLE16(data, at: 2)
            let payloadLen = readLE32(data, at: 4)
            let len = Int(payloadLen)
            guard len < FrameHeader.maxPayload else { return frames }
            let totalNeeded = FrameHeader.sizeBytes + len
            if data.count < totalNeeded { break }

            let payload = data.subdata(in: 8..<(8 + len))
            frames.append(Frame(streamId: streamId, msgType: msgType, payload: payload))
            data.removeSubrange(0..<totalNeeded)
        }
        return frames
    }
}

public func readLE16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

public func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) |
    (UInt32(data[offset + 1]) << 8) |
    (UInt32(data[offset + 2]) << 16) |
    (UInt32(data[offset + 3]) << 24)
}

public func readLE64(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(data[offset]) |
    (UInt64(data[offset + 1]) << 8) |
    (UInt64(data[offset + 2]) << 16) |
    (UInt64(data[offset + 3]) << 24) |
    (UInt64(data[offset + 4]) << 32) |
    (UInt64(data[offset + 5]) << 40) |
    (UInt64(data[offset + 6]) << 48) |
    (UInt64(data[offset + 7]) << 56)
}

public func encodeFrame(streamId: UInt16, msgType: UInt16, payload: Data) -> Data {
    var out = Data(capacity: FrameHeader.sizeBytes + payload.count)
    withUnsafeBytes(of: streamId.littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: msgType.littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

public func encodeJSONFrame<T: Encodable>(streamId: UInt16, msgType: UInt16, payload: T) throws -> Data {
    let body = try WireJSON.encoder.encode(payload)
    return encodeFrame(streamId: streamId, msgType: msgType, payload: body)
}
