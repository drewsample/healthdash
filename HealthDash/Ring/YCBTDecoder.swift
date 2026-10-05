import Foundation

/// Decoded ring data, ready to persist. Timestamps are absolute `Date`s.
enum RingEvent {
    case stepsTotal(steps: Int, distanceM: Double, calories: Double, at: Date)
    case stepsBucket(steps: Int, distanceM: Double, at: Date)
    case heartRate(bpm: Int, at: Date)
    case spo2(percent: Int, at: Date)
    case hrv(ms: Double, at: Date)
    case respiratoryRate(rpm: Int, at: Date)
    case temperature(celsius: Double, at: Date)
    case bloodPressure(sys: Int, dia: Int, at: Date)
    case battery(percent: Int)
    case sleep(start: Date, stages: [UInt8])   // one byte per minute: 1 deep 2 light 3 REM 4 awake
}

/// Pure decoders for YCBT frames and reassembled history buffers.
/// Layouts from the decompiled Yucheng SDK via PulseLoop's YCBTHealthRecords.
enum YCBTDecoder {

    // MARK: - Live stream (group 0x06, be940003)

    static func decodeLive(_ frame: YCBTFrame, now: Date = Date()) -> [RingEvent] {
        let p = frame.payload
        switch frame.cmd {
        case YCBTCommand.liveStatus:
            // Cumulative day totals: [steps:u16][distance:u16][calories:u16].
            guard p.count >= 6 else { return [] }
            return [.stepsTotal(steps: YCBTBytes.u16(p, 0),
                                distanceM: Double(YCBTBytes.u16(p, 2)),
                                calories: Double(YCBTBytes.u16(p, 4)), at: now)]
        case YCBTCommand.liveHeartRate:
            guard let bpm = p.first, (30...220).contains(Int(bpm)) else { return [] }
            return [.heartRate(bpm: Int(bpm), at: now)]
        case YCBTCommand.liveSpo2:
            guard let v = p.first, (70...100).contains(Int(v)) else { return [] }
            return [.spo2(percent: Int(v), at: now)]
        case YCBTCommand.liveVitals:
            // [sbp@0][dbp@1][hr@2][hrv@3][spo2@4][tempInt@5][tempFrac@6]
            var out: [RingEvent] = []
            if p.count >= 2, p[0] > 0, p[1] > 0,
               (70...250).contains(Int(p[0])), (40...150).contains(Int(p[1])) {
                out.append(.bloodPressure(sys: Int(p[0]), dia: Int(p[1]), at: now))
            }
            if p.count >= 3, (30...220).contains(Int(p[2])), p[2] > 0 {
                out.append(.heartRate(bpm: Int(p[2]), at: now))
            }
            if p.count >= 4, p[3] > 0 { out.append(.hrv(ms: Double(p[3]), at: now)) }
            if p.count >= 5, (70...100).contains(Int(p[4])) { out.append(.spo2(percent: Int(p[4]), at: now)) }
            if p.count >= 7, p[5] > 0, p[6] != 15 {
                if let t = composite(p[5], p[6]), (30...45).contains(t) {
                    out.append(.temperature(celsius: t, at: now))
                }
            }
            return out
        case YCBTCommand.liveBattery:
            guard p.count >= 2 else { return [] }
            return [.battery(percent: Int(p[1]))]
        default:
            return []
        }
    }

    // MARK: - Get replies (group 0x02, be940001)

    static func decodeGetReply(_ frame: YCBTFrame) -> [RingEvent] {
        let p = frame.payload
        switch frame.cmd {
        case YCBTCommand.getDeviceInfo:
            // [deviceId:u16][fwSub][fwMain][state][battery%]
            guard p.count >= 6 else { return [] }
            return [.battery(percent: Int(p[5]))]
        default:
            return []
        }
    }

    // MARK: - History buffers (reassembled 05-transfer payloads)

    static func decodeHistory(_ buffer: [UInt8], type: YCBTHistoryType) -> [RingEvent] {
        switch type.queryKey {
        case YCBTHistoryType.sport.queryKey: return sport(buffer)
        case YCBTHistoryType.heart.queryKey: return heart(buffer)
        case YCBTHistoryType.spo2.queryKey: return spo2(buffer)
        case YCBTHistoryType.all.queryKey: return all(buffer)
        case YCBTHistoryType.sleep.queryKey: return sleep(buffer)
        default: return []
        }
    }

    /// 14-byte records: [start:u32][end:u32][steps:u16@8][distance:u16@10][cal:u16@12].
    private static func sport(_ b: [UInt8]) -> [RingEvent] {
        strideRecords(b, 14).compactMap { r in
            let steps = YCBTBytes.u16(r, 8), dist = YCBTBytes.u16(r, 10)
            guard steps > 0 || dist > 0 else { return nil }
            return .stepsBucket(steps: steps, distanceM: Double(dist),
                                at: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    /// 6-byte records: [ts:u32][mode@4][hr@5].
    private static func heart(_ b: [UInt8]) -> [RingEvent] {
        strideRecords(b, 6).compactMap { r in
            guard r[5] > 0, (30...220).contains(Int(r[5])) else { return nil }
            return .heartRate(bpm: Int(r[5]), at: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    /// 6-byte records: [ts:u32][type@4][spo2@5].
    private static func spo2(_ b: [UInt8]) -> [RingEvent] {
        strideRecords(b, 6).compactMap { r in
            guard r[5] > 0, (70...100).contains(Int(r[5])) else { return nil }
            return .spo2(percent: Int(r[5]), at: YCBTBytes.date(YCBTBytes.u32(r, 0)))
        }
    }

    /// 20-byte "All" records:
    /// [ts:u32][steps:u16@4][hr@6][sys@7][dia@8][spo2@9][resp@10][hrv@11]
    /// [tempInt@13][tempFrac@14][…][bloodSugar@17].
    /// Steps are a cumulative counter — deliberately NOT emitted (the live
    /// 06 00 stream is the trustworthy source for today's total).
    private static func all(_ b: [UInt8]) -> [RingEvent] {
        var out: [RingEvent] = []
        for r in strideRecords(b, 20) {
            let ts = YCBTBytes.date(YCBTBytes.u32(r, 0))
            if r[7] > 0, r[8] > 0, (70...250).contains(Int(r[7])), (40...150).contains(Int(r[8])) {
                out.append(.bloodPressure(sys: Int(r[7]), dia: Int(r[8]), at: ts))
            }
            if r[9] > 0, (70...100).contains(Int(r[9])) { out.append(.spo2(percent: Int(r[9]), at: ts)) }
            if r[10] > 0, (4...40).contains(Int(r[10])) { out.append(.respiratoryRate(rpm: Int(r[10]), at: ts)) }
            if r[11] > 0 { out.append(.hrv(ms: Double(r[11]), at: ts)) }
            if r[13] > 0, r[14] != 15, let t = composite(r[13], r[14]), (30...45).contains(t) {
                out.append(.temperature(celsius: t, at: ts))
            }
        }
        return out
    }

    /// Variable-length sessions: 20-byte header + 8-byte segments
    /// `[tag:1][segStart:u32][len:u24]`, stage = tag & 0x0F.
    private static func sleep(_ b: [UInt8]) -> [RingEvent] {
        var out: [RingEvent] = []
        var cursor = 0
        while cursor + 20 <= b.count {
            let recordLen = YCBTBytes.u16(b, cursor + 2)
            let segStart = cursor + 20
            let declared = max(0, recordLen - 20) / 8
            let available = (b.count - segStart) / 8
            let count = min(declared, available)
            var stages: [UInt8] = []
            var seen: Set<Int> = []
            for i in 0..<count {
                let o = segStart + i * 8
                guard let stage = sleepStage(b[o]) else { continue }
                let sStart = YCBTBytes.u32(b, o + 1)
                guard seen.insert(sStart).inserted else { continue }
                if stages.count >= 24 * 60 { break }
                let minutes = max(1, Int((Double(YCBTBytes.u24(b, o + 5)) / 60).rounded()))
                stages.append(contentsOf: repeatElement(stage, count: min(minutes, 24 * 60 - stages.count)))
            }
            if !stages.isEmpty {
                // Session start = earliest segment start.
                var firstStart = Int.max
                for i in 0..<count {
                    let o = segStart + i * 8
                    if sleepStage(b[o]) != nil { firstStart = min(firstStart, YCBTBytes.u32(b, o + 1)) }
                }
                if firstStart != Int.max {
                    out.append(.sleep(start: YCBTBytes.date(firstStart), stages: stages))
                }
            }
            cursor = segStart + count * 8
            if count == 0 { cursor += 20 }  // avoid spinning on a bogus header
        }
        return out
    }

    private static func sleepStage(_ tag: UInt8) -> UInt8? {
        switch tag & 0x0F {
        case 1, 2, 3, 4, 5: return tag & 0x0F
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func strideRecords(_ b: [UInt8], _ size: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i + size <= b.count { out.append(Array(b[i..<(i + size)])); i += size }
        return out
    }

    /// int/frac are string-concatenated ("36"."5" → 36.5), not added.
    private static func composite(_ int: UInt8, _ frac: UInt8) -> Double? {
        Double("\(int).\(frac)")
    }
}
