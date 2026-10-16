import Foundation

public struct KokoroVoiceInfo: Identifiable, Hashable, Sendable {
    public enum Accent: String, Sendable { case american, british }
    public enum Gender: String, Sendable { case male, female }

    public let id: String
    public let name: String
    public let accent: Accent
    public let gender: Gender
    public let preferred: Bool

    public init(id: String, name: String, accent: Accent, gender: Gender, preferred: Bool = false) {
        self.id = id
        self.name = name
        self.accent = accent
        self.gender = gender
        self.preferred = preferred
    }

    public var displayName: String {
        let accentLabel = accent == .american ? "American" : "British"
        let genderLabel = gender == .male ? "male" : "female"
        return "\(name) (\(accentLabel) \(genderLabel))"
    }

    public var lang: String { accent == .british ? "en-gb" : "en-us" }
}

public enum KokoroVoices {
    public static let defaultVoice = "am_onyx"

    public static let catalog: [KokoroVoiceInfo] = [
        KokoroVoiceInfo(id: "am_onyx", name: "Onyx", accent: .american, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "am_michael", name: "Michael", accent: .american, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "bm_george", name: "George", accent: .british, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "bm_lewis", name: "Lewis", accent: .british, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "bm_daniel", name: "Daniel", accent: .british, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "bm_fable", name: "Fable", accent: .british, gender: .male, preferred: true),
        KokoroVoiceInfo(id: "af_heart", name: "Heart", accent: .american, gender: .female, preferred: true),
        KokoroVoiceInfo(id: "am_adam", name: "Adam", accent: .american, gender: .male),
        KokoroVoiceInfo(id: "am_eric", name: "Eric", accent: .american, gender: .male),
        KokoroVoiceInfo(id: "am_fenrir", name: "Fenrir", accent: .american, gender: .male),
        KokoroVoiceInfo(id: "am_liam", name: "Liam", accent: .american, gender: .male),
        KokoroVoiceInfo(id: "am_puck", name: "Puck", accent: .american, gender: .male),
        KokoroVoiceInfo(id: "af_bella", name: "Bella", accent: .american, gender: .female),
        KokoroVoiceInfo(id: "af_nicole", name: "Nicole", accent: .american, gender: .female),
        KokoroVoiceInfo(id: "af_sarah", name: "Sarah", accent: .american, gender: .female),
        KokoroVoiceInfo(id: "af_nova", name: "Nova", accent: .american, gender: .female),
        KokoroVoiceInfo(id: "bf_emma", name: "Emma", accent: .british, gender: .female),
        KokoroVoiceInfo(id: "bf_isabella", name: "Isabella", accent: .british, gender: .female),
        KokoroVoiceInfo(id: "bf_alice", name: "Alice", accent: .british, gender: .female),
        KokoroVoiceInfo(id: "bf_lily", name: "Lily", accent: .british, gender: .female),
    ]

    public static var preferred: [KokoroVoiceInfo] { catalog.filter(\.preferred) }

    public static func info(for id: String) -> KokoroVoiceInfo? {
        catalog.first { $0.id == id }
    }

    public static func isKnown(_ id: String) -> Bool { info(for: id) != nil }
}
