import Foundation

/// The words the speech recogniser should expect, most useful first: what is on screen and nearby, the
/// rider's own places, then the city's best-known destinations and the app's own words. iOS weighs
/// a limited list, so later groups only fill what room is left.
public enum VoiceVocabulary {
    /// The recogniser's list is kept to this many names.
    public static let limit = 100

    /// Places riders name by voice that are not stop names, in Chinese and English.
    public static let landmarks: [(chinese: String, english: String)] = [
        ("台北101", "Taipei 101"), ("西門町", "Ximending"), ("淡水老街", "Tamsui Old Street"),
        ("士林夜市", "Shilin Night Market"), ("饒河夜市", "Raohe Night Market"), ("寧夏夜市", "Ningxia Night Market"),
        ("師大夜市", "Shida Night Market"), ("故宮博物院", "National Palace Museum"),
        ("中正紀念堂", "Chiang Kai-shek Memorial Hall"), ("國父紀念館", "Sun Yat-sen Memorial Hall"),
        ("龍山寺", "Longshan Temple"), ("象山", "Elephant Mountain"), ("貓空纜車", "Maokong Gondola"),
        ("北投溫泉", "Beitou Hot Spring"), ("陽明山", "Yangmingshan"), ("大稻埕", "Dadaocheng"),
        ("迪化街", "Dihua Street"), ("華山文創園區", "Huashan 1914 Creative Park"),
        ("松山文創園區", "Songshan Cultural and Creative Park"), ("台北車站", "Taipei Main Station"),
        ("松山機場", "Songshan Airport"), ("桃園機場", "Taoyuan Airport"), ("台北小巨蛋", "Taipei Arena"),
        ("南港展覽館", "Nangang Exhibition Center"), ("台北市立動物園", "Taipei Zoo"), ("信義商圈", "Xinyi"),
        ("大安森林公園", "Daan Forest Park"), ("公館", "Gongguan"), ("碧潭", "Bitan"), ("九份", "Jiufen"),
        ("漁人碼頭", "Fisherman's Wharf"), ("圓山大飯店", "Grand Hotel"), ("台北市立美術館", "Taipei Fine Arts Museum"),
        ("光華商場", "Guanghua Digital Plaza"), ("台大醫院", "NTU Hospital"), ("台灣大學", "National Taiwan University"),
    ]

    /// Words of the app itself, said in almost every conversation.
    public static func appWords(english: Bool) -> [String] {
        english ? ["YouBike", "MRT", "bus", "I'm on the bus", "get off", "navigation"]
            : ["YouBike", "捷運", "公車", "我上車了", "下車", "開始導航", "結束導航"]
    }

    /// The groups in order, each name once, up to `limit`.
    public static func hints(_ groups: [[String]], limit: Int = limit) -> [String] {
        var seen = Set<String>(), hints: [String] = []
        for name in groups.joined() {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 40, seen.insert(name).inserted else { continue }
            hints.append(name)
            if hints.count == limit { break }
        }
        return hints
    }
}
