import Foundation
import TransitCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads a one-sentence trip ("從公司到台大醫院，少走路") with Apple's on-device language model
/// (iOS 26 with Apple Intelligence). The sentence never leaves the phone. The model only splits it
/// into fields; TripIntent.validated keeps places the rider actually wrote, the ordinary place
/// search finds them, and the rider still picks every place.
enum TripSentenceReader {
    static var isAvailable: Bool {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
#endif
        return false
    }

    /// Nil when the model is unavailable, gives up, or proposes nothing the sentence supports.
    static func read(_ sentence: String, savedTitles: [String]) async -> TripIntent? {
#if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try? await withThrowingTaskGroup(of: TripIntent?.self) { group in
                group.addTask { try await TripSentenceModel.read(sentence, savedTitles: savedTitles) }
                // The rider is waiting on the search sheet; a slow first load is not worth more.
                group.addTask { try await Task.sleep(for: .seconds(10)); return nil }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
#endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
enum TripSentencePreference {
    case balanced, faster, lessWalking, fewerTransfers
}

@available(iOS 26.0, *)
@Generable
struct TripSentenceFields {
    @Guide(description: "要去的地方，逐字抄自原句的地名、地址或站名；沒有提到則為空字串")
    var destination: String
    @Guide(description: "出發地，逐字抄自原句；沒有提到，或說這裡、目前位置時為空字串")
    var origin: String
    @Guide(description: "路線偏好：趕時間或要最快為 faster；少走路、不想走路為 lessWalking；少轉乘、不想換車、直達為 fewerTransfers；其他為 balanced")
    var preference: TripSentencePreference
    @Guide(description: "提到的出發或抵達時間，逐字抄自原句；沒有則為空字串")
    var time: String
    @Guide(description: "句子指的常用行程名稱，必須是清單中的其中一個；沒有則為空字串")
    var savedTrip: String
}

@available(iOS 26.0, *)
private enum TripSentenceModel {
    static func read(_ sentence: String, savedTitles: [String]) async throws -> TripIntent? {
        let titles = savedTitles.prefix(20).map { $0.replacingOccurrences(of: "\n", with: " ") }
        let instructions = """
        你把一句在台北搭公車的需求拆成欄位。地名只能逐字抄自使用者的句子，不可改寫、補全、翻譯或猜測；句子沒有提到的欄位一律留空字串。
        使用者的常用行程：\(titles.isEmpty ? "（無）" : titles.joined(separator: "、"))
        例：「從台北車站到臺大醫院，不想走太多路」→ destination 臺大醫院，origin 台北車站，preference lessWalking。
        例：「明天早上9點前到市政府」→ destination 市政府，time 明天早上9點前。
        例："fastest way from Ximen to Taipei 101" → destination Taipei 101, origin Ximen, preference faster.
        """
        let session = LanguageModelSession(instructions: instructions)
        let fields = try await session.respond(to: sentence, generating: TripSentenceFields.self,
                                               options: GenerationOptions(sampling: .greedy)).content
        return TripIntent.validated(sentence: sentence, destination: fields.destination, origin: fields.origin,
                                    preference: "\(fields.preference)", time: fields.time,
                                    savedJourney: fields.savedTrip, savedTitles: Array(titles))
    }
}
#endif
