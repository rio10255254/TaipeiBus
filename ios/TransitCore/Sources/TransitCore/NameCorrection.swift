import Foundation

/// Puts the right characters back into a stop or place name that speech recognition heard by sound
/// but wrote with other characters: 忠孝敦華 for 忠孝敦化, or, with an accent that merges zh and z,
/// eng and en or n and l, 宗孝敦化 for 忠孝敦化. A short name must sound exactly the same, tones
/// included, so 公關 stays 公關 rather than becoming 公館. Names on screen or nearby are compared
/// without tones and with those accents folded from three characters; the city's thousands of other
/// stop names only from four, so ordinary words are not mistaken for one of them.
public struct NameCorrection: Sendable {
    struct Name: Sendable {
        let text: [Character]
        /// Pinyin with tone marks.
        let exact: [String]
        /// Pinyin without tones, accents folded.
        let loose: [String]
        /// The length from which the folded pinyin is enough.
        let looseFrom: Int
    }
    private let names: [Name]

    /// `nearby` are the names on screen and around the rider; `others` every other stop and place.
    public init(nearby: [String], others: [String] = []) {
        var seen = Set<String>()
        func index(_ list: [String], looseFrom: Int) -> [Name] {
            list.compactMap { name in
                let characters = Array(name)
                guard characters.count >= 2, characters.count <= 12, seen.insert(name).inserted,
                      let exact = Self.syllables(characters) else { return nil }
                return Name(text: characters, exact: exact, loose: exact.map(Self.loose), looseFrom: looseFrom)
            }
        }
        self.names = (index(nearby, looseFrom: 3) + index(others, looseFrom: 4))
        // Longer names first, so 忠孝敦化站 wins over 敦化.
        .sorted { $0.text.count > $1.text.count }
    }

    /// The text with every stretch that sounds like a known name written as that name.
    public func correct(_ text: String) -> String {
        var characters = Array(text)
        let exact = characters.map { Self.syllable($0) }
        let loose = exact.map { $0.map(Self.loose) }
        var taken = [Bool](repeating: false, count: characters.count)
        var replacements: [(start: Int, name: Name)] = []
        for name in names where name.text.count <= characters.count {
            let length = name.text.count
            for start in 0...(characters.count - length) {
                // The first syllable rules out almost every name before anything else is compared.
                guard loose[start] == name.loose[0] else { continue }
                var sameText = true, sameExact = true, sameLoose = true
                for offset in 0..<length {
                    let index = start + offset
                    if taken[index] { sameLoose = false; sameExact = false; break }
                    if characters[index] != name.text[offset] { sameText = false }
                    if exact[index] != name.exact[offset] { sameExact = false }
                    if loose[index] != name.loose[offset] { sameLoose = false; break }
                }
                guard !sameText, sameExact || (sameLoose && length >= name.looseFrom) else { continue }
                replacements.append((start, name))
                for index in start..<(start + length) { taken[index] = true }
            }
        }
        for replacement in replacements.sorted(by: { $0.start > $1.start }) {
            characters.replaceSubrange(replacement.start..<(replacement.start + replacement.name.text.count), with: replacement.name.text)
        }
        return String(characters)
    }

    /// Pinyin without tones for each character, or nil when any is not a Chinese character.
    static func syllables(_ characters: [Character]) -> [String]? {
        var result: [String] = []
        for character in characters {
            guard let syllable = syllable(character) else { return nil }
            result.append(syllable)
        }
        return result
    }

    /// Pinyin with its tone mark, e.g. guǎn.
    static func syllable(_ character: Character) -> String? {
        guard character.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }),
              let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false)?.lowercased(),
              !latin.isEmpty, latin.allSatisfy(\.isLetter) else { return nil }
        return latin
    }

    /// The syllable without its tone, as an accent may say it: zh, ch, sh as z, c, s; eng, ing as en,
    /// in; l as n.
    static func loose(_ syllable: String) -> String {
        var sound = syllable.applyingTransform(.stripDiacritics, reverse: false) ?? syllable
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where sound.hasPrefix(from) {
            sound = to + sound.dropFirst(from.count)
        }
        if sound.hasPrefix("l") { sound = "n" + sound.dropFirst() }
        if sound.hasSuffix("eng") || sound.hasSuffix("ing") { sound.removeLast() }
        return sound
    }
}
