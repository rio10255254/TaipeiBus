import Foundation

public struct MapPlace: Sendable {
    public let id: String
    public let coordinate: Coordinate
    public let kind: String
    public let rank: Double
    public let names: [String: String]
    public init(id: String, coordinate: Coordinate, kind: String, rank: Double, names: [String: String]) {
        self.id = id; self.coordinate = coordinate; self.kind = kind; self.rank = rank; self.names = names
    }
}

/// Reads only named POI points from a vector tile; never creates UIKit objects.
public enum MapPlaceTile {
    private struct Field { let number: Int; let wire: Int; let data: Data; let integer: UInt64 }
    private static func integer(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < data.count else { throw FeedError.invalid("Vector tile varint") }
            let byte = data[offset]; offset += 1
            if shift == 63 && byte > 1 { throw FeedError.invalid("Vector tile overflow") }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw FeedError.invalid("Vector tile integer")
    }
    private static func fields(_ data: Data) throws -> [Field] {
        var offset = 0, result: [Field] = []
        while offset < data.count {
            let tag = try integer(data, &offset), number = Int(tag >> 3), wire = Int(tag & 7)
            guard number > 0 else { throw FeedError.invalid("Vector tile field") }
            if wire == 0 {
                result.append(Field(number: number, wire: wire, data: Data(), integer: try integer(data, &offset)))
            } else {
                let count: Int
                if wire == 2 {
                    let length = try integer(data, &offset)
                    guard length <= UInt64(data.count) else { throw FeedError.invalid("Vector tile length") }
                    count = Int(length)
                } else if wire == 1 { count = 8 }
                else if wire == 5 { count = 4 }
                else { throw FeedError.invalid("Vector tile wire") }
                guard count <= data.count - offset else { throw FeedError.invalid("Truncated vector tile") }
                result.append(Field(number: number, wire: wire, data: Data(data[offset..<(offset + count)]), integer: 0))
                offset += count
            }
        }
        return result
    }
    private enum Value { case string(String), number(Double), other }
    private static func value(_ data: Data) throws -> Value {
        for field in try fields(data) {
            if field.number == 1 { return .string(String(decoding: field.data, as: UTF8.self)) }
            if field.number == 4 || field.number == 5 { return .number(Double(field.integer)) }
            if field.number == 6 {
                let number = Int64(bitPattern: field.integer >> 1) ^ -Int64(field.integer & 1)
                return .number(Double(number))
            }
            if field.number == 3, field.data.count == 8 {
                let bits = field.data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                return .number(Double(bitPattern: bits))
            }
            if field.number == 2, field.data.count == 4 {
                let bits = field.data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                return .number(Double(Float(bitPattern: bits)))
            }
        }
        return .other
    }
    private static func packed(_ data: Data) throws -> [UInt64] {
        var offset = 0, result: [UInt64] = []
        while offset < data.count { result.append(try integer(data, &offset)) }
        return result
    }
    public static func decode(_ data: Data, zoom: Int, x: Int, y: Int) throws -> [MapPlace] {
        guard data.count <= 8 * 1024 * 1024, (0...22).contains(zoom), x >= 0, y >= 0,
              x < (1 << zoom), y < (1 << zoom) else { throw FeedError.invalid("Vector tile bounds") }
        var result: [MapPlace] = []
        for tileField in try fields(data) where tileField.number == 3 {
            let layer = try fields(tileField.data)
            guard layer.first(where: { $0.number == 1 }).map({ String(decoding: $0.data, as: UTF8.self) }) == "poi" else { continue }
            let keys = layer.filter { $0.number == 3 }.map { String(decoding: $0.data, as: UTF8.self) }
            let values = try layer.filter { $0.number == 4 }.map { try value($0.data) }
            let extent = Double(layer.first(where: { $0.number == 5 })?.integer ?? 4096)
            guard extent > 0, extent <= 65536 else { throw FeedError.invalid("Vector tile extent") }
            for feature in layer where feature.number == 2 {
                let body = try fields(feature.data)
                guard body.first(where: { $0.number == 3 })?.integer == 1,
                      let tagsData = body.first(where: { $0.number == 2 })?.data,
                      let geometry = body.first(where: { $0.number == 4 })?.data else { continue }
                let tags = try packed(tagsData)
                guard tags.count.isMultiple(of: 2) else { throw FeedError.invalid("Vector tile tags") }
                var names: [String: String] = [:], kind = "", rank = 999999.0
                for i in stride(from: 0, to: tags.count, by: 2) {
                    guard tags[i] < UInt64(keys.count), tags[i + 1] < UInt64(values.count) else { throw FeedError.invalid("Vector tile attribute") }
                    let key = keys[Int(tags[i])], val = values[Int(tags[i + 1])]
                    if case .string(let text) = val {
                        if key == "class" { kind = text }
                        if ["name", "name:zh", "name:en", "name_en", "name:latin"].contains(key), !text.isEmpty { names[key] = text }
                    }
                    if key == "rank", case .number(let number) = val { rank = number }
                }
                guard let name = names["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !kind.isEmpty, rank.isFinite, rank >= 0 else { continue }
                let command = try packed(geometry)
                guard command.count >= 3, command[0] & 7 == 1, command[0] >> 3 >= 1 else { continue }
                let px = Double(Int64(bitPattern: command[1] >> 1) ^ -Int64(command[1] & 1))
                let py = Double(Int64(bitPattern: command[2] >> 1) ^ -Int64(command[2] & 1))
                let size = pow(2, Double(zoom))
                let longitude = (Double(x) + px / extent) / size * 360 - 180
                let latitude = atan(sinh(.pi * (1 - 2 * (Double(y) + py / extent) / size))) * 180 / .pi
                guard longitude.isFinite, latitude.isFinite, abs(longitude) <= 180, abs(latitude) < 85 else { continue }
                let coordinate = Coordinate(latitude: latitude, longitude: longitude)
                let id = "\(kind):\(name):\(String(format: "%.6f", latitude)):\(String(format: "%.6f", longitude))"
                result.append(MapPlace(id: id, coordinate: coordinate, kind: kind, rank: rank, names: names))
            }
        }
        return result
    }
}
