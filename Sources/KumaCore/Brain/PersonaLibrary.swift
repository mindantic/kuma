import Foundation

public enum PersonaLibrary {
    public static let kuma = Persona(
        id: "kuma",
        name: "Kuma",
        voice: "am_onyx",
        speed: 0.95,
        tone: "Calm and gentle. Use very few words. No jokes. Never say sir. State the outcome first, then what is needed from the user.",
        isBuiltIn: true
    )

    public static let butler = Persona(
        id: "butler",
        name: "Butler",
        voice: "bm_george",
        speed: 1.0,
        tone: "A polished British AI butler, composed and quietly confident. Dry wit, used sparingly. Address the user as sir. Precise and courteous.",
        isBuiltIn: true
    )

    public static let neutral = Persona(
        id: "neutral",
        name: "Neutral",
        voice: "af_heart",
        speed: 1.0,
        tone: "Plain and factual. No personality, no filler.",
        isBuiltIn: true
    )

    public static let builtIns: [Persona] = [kuma, butler, neutral]

    public static func all(custom: [Persona]) -> [Persona] {
        let builtInIds = Set(builtIns.map(\.id))
        let presets = builtIns.map { preset in
            guard var edited = custom.first(where: { $0.id == preset.id }) else { return preset }
            edited.isBuiltIn = true
            return edited
        }
        return presets + custom.filter { !builtInIds.contains($0.id) }
    }

    public static func persona(id: String?, custom: [Persona]) -> Persona {
        guard let id else { return kuma }
        return all(custom: custom).first { $0.id == id } ?? kuma
    }
}
