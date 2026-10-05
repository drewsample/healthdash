import Foundation

/// Decodes weight broadcasts from OKOK-platform BLE scales.
///
/// The scale never needs a GATT connection: it advertises the reading in the
/// manufacturer-specific AD field. Four variants, keyed by company ID:
///   V20 (0x20CA), V11 (0x11CA), VF0 (0xF0FF), C0 (any ID with low byte 0xC0).
/// Ported from okok_ble_reader.py (100nandoo/okok-bia-formulas).
enum OKOKAdvertParser {
    struct Reading {
        let variant: String
        let kg: Double
        let impedanceOhms: Double?
    }

    private static let v20: UInt16 = 0x20CA
    private static let v11: UInt16 = 0x11CA
    private static let vf0: UInt16 = 0xF0FF

    /// - Parameter manufacturerData: the raw CBAdvertisementDataManufacturerDataKey
    ///   bytes (company ID as first 2 bytes, little-endian, then payload).
    static func parse(_ manufacturerData: Data) -> Reading? {
        guard manufacturerData.count >= 2 else { return nil }
        let bytes = [UInt8](manufacturerData)
        let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payload = Array(bytes.dropFirst(2))

        if company == v20, let r = parseV20(payload) { return r }
        if company == v11, let r = parseV11(payload) { return r }
        if company == vf0, let r = parseVF0(payload) { return r }
        if company & 0xFF == 0xC0, let r = parseC0(payload) { return r }
        return nil
    }

    // MARK: - Variants

    private static func parseV20(_ d: [UInt8]) -> Reading? {
        guard d.count == 19 else { return nil }
        guard d[6] & 0x01 != 0 else { return nil }          // stable flag
        var checksum: UInt8 = 0x20
        for i in 0..<12 { checksum ^= d[i] }
        guard checksum == d[12] else { return nil }
        let divider: Double = (d[6] & 0x04) != 0 ? 100 : 10
        let kg = Double(u16be(d[8], d[9])) / divider
        let impRaw = u16be(d[10], d[11])
        return Reading(variant: "V20", kg: kg, impedanceOhms: impRaw > 0 ? Double(impRaw) / 10 : nil)
    }

    private static func parseV11(_ d: [UInt8]) -> Reading? {
        guard d.count == 23 else { return nil }
        var checksum: UInt8 = 0xCA ^ 0x11
        for i in 0..<16 { checksum ^= d[i] }
        guard checksum == d[16] else { return nil }
        let props = d[9]
        let divider = resolveDivider((props >> 1) & 0x3)
        let unit = (props >> 3) & 0x3
        let raw = u16be(d[3], d[4])
        guard let kg = toKg(raw: raw, unit: unit, divider: divider) else { return nil }
        return Reading(variant: "V11", kg: kg, impedanceOhms: nil)
    }

    private static func parseVF0(_ d: [UInt8]) -> Reading? {
        guard d.count >= 4 else { return nil }
        return Reading(variant: "VF0", kg: Double(u16be(d[3], d[2])) / 10, impedanceOhms: nil)
    }

    private static func parseC0(_ d: [UInt8]) -> Reading? {
        guard d.count >= 7 else { return nil }
        let attrib = d[6]
        guard attrib & 0x01 != 0 else { return nil }        // stable flag
        let divider = resolveDivider((attrib >> 1) & 0x3)
        let unit = (attrib >> 3) & 0x3
        guard let kg = toKg(raw: u16be(d[0], d[1]), unit: unit, divider: divider) else { return nil }
        let impRaw = u16be(d[2], d[3])
        return Reading(variant: "C0", kg: kg, impedanceOhms: impRaw > 0 ? Double(impRaw) / 10 : nil)
    }

    // MARK: - Helpers

    private static func u16be(_ msb: UInt8, _ lsb: UInt8) -> Int {
        (Int(msb) << 8) | Int(lsb)
    }

    private static func resolveDivider(_ resBits: UInt8) -> Double {
        switch resBits { case 1: return 1; case 2: return 100; default: return 10 }
    }

    /// unit: 0 kg, 1 jin, 2 lb, 3 st+lb
    private static func toKg(raw: Int, unit: UInt8, divider: Double) -> Double? {
        switch unit {
        case 0: return Double(raw) / divider
        case 1: return Double(raw) / divider / 2.0
        case 2: return (Double(raw) / divider) / 2.204623
        case 3:
            let stones = raw >> 8
            let pounds = Double(raw & 0xFF) / divider
            return Double(stones) * 6.350293 + pounds * 0.453592
        default: return nil
        }
    }
}
