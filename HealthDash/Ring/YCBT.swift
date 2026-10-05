import Foundation
import CoreBluetooth

// MARK: - GATT topology

enum YCBTUUIDs {
    static let service = CBUUID(string: "be940000-7333-be46-b7ae-689e71722bd5")
    /// Command channel: the app writes here AND receives replies here (write + indicate).
    static let command = CBUUID(string: "be940001-7333-be46-b7ae-689e71722bd5")
    /// Async stream: live vitals + history data frames (indicate).
    static let stream = CBUUID(string: "be940003-7333-be46-b7ae-689e71722bd5")
}

// MARK: - Framing

/// Wire format on both channels:
///   `[type:1][cmd:1][len:2 LE][payload:N][crc16:2 LE]`
/// where `len` is the TOTAL frame length and the CRC is CRC16/CCITT-FALSE
/// (poly 0x1021, init 0xFFFF) over every byte before it.
struct YCBTFrame {
    let type: UInt8
    let cmd: UInt8
    let payload: [UInt8]

    init?(validating data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return nil }
        let declared = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard declared == bytes.count else { return nil }
        let given = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard YCBTFrame.crc16(bytes[0..<(bytes.count - 2)]) == given else { return nil }
        self.type = bytes[0]
        self.cmd = bytes[1]
        self.payload = Array(bytes[4..<(bytes.count - 2)])
    }

    static func frame(_ logical: [UInt8]) -> Data {
        guard logical.count >= 2 else { return Data(logical) }
        let total = logical.count + 4
        var out: [UInt8] = [logical[0], logical[1],
                            UInt8(total & 0xff), UInt8((total >> 8) & 0xff)]
        out.append(contentsOf: logical[2...])
        let crc = crc16(out[0..<out.count])
        out.append(UInt8(crc & 0xff)); out.append(UInt8((crc >> 8) & 0xff))
        return Data(out)
    }

    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1) }
        }
        return crc
    }
}

/// Reassembles GATT notifications into whole frames. Frames longer than MTU-3
/// arrive split across notifications; several short frames can share one.
final class YCBTFrameAssembler {
    private var pending: [CBUUID: [UInt8]] = [:]

    func reset() { pending.removeAll() }

    func append(_ data: Data, from characteristic: CBUUID) -> [Data] {
        var buffer = pending[characteristic] ?? []
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let declared = Int(buffer[2]) | (Int(buffer[3]) << 8)
            guard (0x01...0x06).contains(buffer[0]), declared >= 6, declared <= 2048 else {
                buffer.removeFirst(); continue   // resync past garbage
            }
            guard buffer.count >= declared else { break }
            frames.append(Data(buffer[0..<declared]))
            buffer.removeFirst(declared)
        }
        pending[characteristic] = buffer
        return frames
    }
}

// MARK: - Byte helpers (ring epoch = seconds since 2000-01-01, local wall clock)

enum YCBTBytes {
    static let epochOffset: TimeInterval = 946_684_800

    static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 2 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }
    static func u24(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 3 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
    }
    static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard b.count >= i + 4 else { return 0 }
        return Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    static func date(_ ringSeconds: Int, timeZone: TimeZone = .current) -> Date {
        let wallClock = Date(timeIntervalSince1970: TimeInterval(ringSeconds) + epochOffset)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return local.date(from: utc.dateComponents(fields, from: wallClock))
            ?? wallClock.addingTimeInterval(-TimeInterval(timeZone.secondsFromGMT()))
    }
}

// MARK: - Opcodes

enum YCBTGroup {
    static let setting: UInt8 = 0x01
    static let get: UInt8 = 0x02
    static let appControl: UInt8 = 0x03
    static let devControl: UInt8 = 0x04
    static let health: UInt8 = 0x05
    static let real: UInt8 = 0x06
}

enum YCBTCommand {
    // group 0x02
    static let getDeviceInfo: UInt8 = 0x00    // battery @payload[5]
    static let getSupportFunction: UInt8 = 0x01
    static let getDeviceName: UInt8 = 0x03
    static let getUserConfig: UInt8 = 0x07
    static let getChipScheme: UInt8 = 0x1b
    // group 0x03
    static let findDevice: UInt8 = 0x00
    static let liveMeasurement: UInt8 = 0x2f  // [enable, mode]
    static let liveStatusPush: UInt8 = 0x09
    // group 0x06 (async stream)
    static let liveStatus: UInt8 = 0x00       // [steps:u16][distance:u16][cal:u16]
    static let liveHeartRate: UInt8 = 0x01
    static let liveSpo2: UInt8 = 0x02
    static let liveVitals: UInt8 = 0x03
    static let liveBattery: UInt8 = 0x15
}

enum YCBTSettingKey {
    static let setTime: UInt8 = 0x00
    static let userInfo: UInt8 = 0x03
    static let units: UInt8 = 0x04
    static let heartMonitor: UInt8 = 0x0c
    static let language: UInt8 = 0x12
    static let bloodPressureMonitor: UInt8 = 0x1c
    static let temperatureMonitor: UInt8 = 0x20
    static let bloodOxygenMonitor: UInt8 = 0x26
    static let hrvMonitor: UInt8 = 0x45
}

enum YCBTMeasurementMode {
    static let heartRate: UInt8 = 0x00
    static let spo2: UInt8 = 0x02
    static let hrv: UInt8 = 0x0a
}

/// One history type: query key → ack key → fixed record stride.
struct YCBTHistoryType: Hashable {
    let queryKey: UInt8
    let ackKey: UInt8
    let recordStride: Int?   // nil = variable length (sleep)
    let label: String

    static let sport = YCBTHistoryType(queryKey: 0x02, ackKey: 0x11, recordStride: 14, label: "activity")
    static let sleep = YCBTHistoryType(queryKey: 0x04, ackKey: 0x13, recordStride: nil, label: "sleep")
    static let heart = YCBTHistoryType(queryKey: 0x06, ackKey: 0x15, recordStride: 6, label: "heart rate")
    static let spo2  = YCBTHistoryType(queryKey: 0x1a, ackKey: 0x22, recordStride: 6, label: "blood oxygen")
    static let all   = YCBTHistoryType(queryKey: 0x09, ackKey: 0x18, recordStride: 20, label: "vitals")

    /// v1 sync set. The ring answers unimplemented types with a no-data
    /// header or 0xFC, which the transfer machine skips.
    static let syncSet: [YCBTHistoryType] = [.sport, .sleep, .heart, .spo2, .all]
}

enum YCBTHealth {
    static let terminalBlock: UInt8 = 0x80
}

/// Device-side rejection: any 1-byte payload in 0xFB…0xFF.
enum YCBTFrameError: UInt8 {
    case unsupportedCommand = 0xfb
    case unsupportedKey = 0xfc
    static func detect(in payload: [UInt8]) -> YCBTFrameError? {
        guard payload.count == 1 else { return nil }
        return YCBTFrameError(rawValue: payload[0])
    }
}
