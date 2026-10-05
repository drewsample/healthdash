import Foundation

/// Builds logical YCBT commands (`[type, cmd, payload…]`); the transport adds
/// the length field and CRC. Mirrors the SmartHealth app's connect order.
enum YCBTCommands {
    // MARK: - Handshake

    /// Commands sent the instant both indication channels are live.
    static func postSubscriptionHandshake(now: Date = Date()) -> [[UInt8]] {
        [[YCBTGroup.get, YCBTCommand.getDeviceName, 0x47, 0x50],
         setTime(now)]
    }

    /// Full startup sequence after the handshake.
    static func startupSequence(profile: Profile, weightKg: Double, now: Date = Date()) -> [[UInt8]] {
        var seq: [[UInt8]] = []
        seq.append([YCBTGroup.get, YCBTCommand.getDeviceInfo, 0x47, 0x43])
        seq.append([YCBTGroup.get, YCBTCommand.getSupportFunction, 0x47, 0x46])
        seq.append([YCBTGroup.get, YCBTCommand.getUserConfig, 0x43, 0x46])
        seq.append([YCBTGroup.setting, YCBTSettingKey.language, 0x00])
        seq.append([YCBTGroup.setting, YCBTSettingKey.units, 0, 0, 0, 0, 0, 0]) // metric, 24h
        seq.append(contentsOf: monitorCommands())
        seq.append(userInfo(profile, weightKg: weightKg))
        seq.append(enableLiveStatus())
        return seq
    }

    // MARK: - Setting group

    /// `01 00` + [year:u16 LE][month][day][hour][min][sec][weekday Mon=0…Sun=6].
    static func setTime(_ date: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = UInt16(c.year ?? 2000)
        let gregorian = c.weekday ?? 1
        let weekday = UInt8(gregorian == 1 ? 6 : gregorian - 2)
        return [YCBTGroup.setting, YCBTSettingKey.setTime,
                UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
                UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
                weekday]
    }

    /// `01 03` + [heightCm][weightKg][sex 1=male][age]. Feeds the ring's own
    /// step/calorie algorithms. Weight comes from the latest scale reading.
    static func userInfo(_ profile: Profile, weightKg: Double) -> [UInt8] {
        [YCBTGroup.setting, YCBTSettingKey.userInfo,
         UInt8(min(255, max(0, Int(profile.heightCm.rounded())))),
         UInt8(min(255, max(0, Int(weightKg.rounded())))),
         profile.isMale ? 1 : 0,
         UInt8(min(255, max(0, profile.age)))]
    }

    /// The five all-day samplers, `{enable, intervalMinutes}`. These — not any
    /// `05 4x` command — are what make the ring record between syncs.
    /// (05 40…4E are Health *Delete* opcodes: never send them.)
    static func monitorCommands(intervalMinutes: UInt8 = 60) -> [[UInt8]] {
        let iv = max(30, intervalMinutes)   // firmware floor is 30 min
        return [
            [YCBTGroup.setting, YCBTSettingKey.heartMonitor, 1, iv],
            [YCBTGroup.setting, YCBTSettingKey.bloodPressureMonitor, 1, iv],
            [YCBTGroup.setting, YCBTSettingKey.temperatureMonitor, 1, iv],
            [YCBTGroup.setting, YCBTSettingKey.bloodOxygenMonitor, 1, iv],
            [YCBTGroup.setting, YCBTSettingKey.hrvMonitor, 1, iv, 0, 0, 0],
        ]
    }

    // MARK: - Live stream

    /// `03 09 01 00 02` — ring then pushes `06 00` status frames continuously.
    static func enableLiveStatus() -> [UInt8] {
        [YCBTGroup.appControl, YCBTCommand.liveStatusPush, 0x01, 0x00, 0x02]
    }

    static func disableLiveStatus() -> [UInt8] {
        [YCBTGroup.appControl, YCBTCommand.liveStatusPush, 0x00, 0x00, 0x02]
    }

    /// `03 2f {enable, mode}`. The stop must echo its own mode.
    static func liveMeasurement(enable: Bool, mode: UInt8) -> [UInt8] {
        [YCBTGroup.appControl, YCBTCommand.liveMeasurement, enable ? 1 : 0, mode]
    }

    // MARK: - History

    /// `05 <queryKey>`, empty payload. The ring dumps everything stored.
    static func historyRequest(_ type: YCBTHistoryType) -> [UInt8] {
        [YCBTGroup.health, type.queryKey]
    }

    /// Mandatory end-of-transfer ACK: `05 80 {00 ok | 04 crc-fail}`.
    static func historyBlockAck(ok: Bool) -> [UInt8] {
        [YCBTGroup.health, YCBTHealth.terminalBlock, ok ? 0x00 : 0x04]
    }

    /// ACK a device→app push (`04 <key> {00}`). The ring retransmits until it arrives.
    static func pushAck(key: UInt8) -> [UInt8] {
        [YCBTGroup.devControl, key, 0x00]
    }
}
