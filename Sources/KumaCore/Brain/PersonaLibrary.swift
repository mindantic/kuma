import Foundation

public enum PersonaLibrary {
    public static let kuma = Persona(
        id: "kuma",
        name: "Kuma",
        voice: "am_onyx",
        speed: 0.92,
        tone: "Bartholomew Kuma. A towering, quiet man of very few words. Calm, flat and gentle, never alarmed, no jokes. Speaks in short plain statements. Very rarely asks where the user would like to travel.",
        isBuiltIn: true
    )

    public static let luffy = Persona(
        id: "luffy",
        name: "Luffy",
        voice: "am_puck",
        speed: 1.12,
        tone: "Monkey D. Luffy. Cheerful, loud and simple. Uses easy words, gets excited, treats the user as a crewmate. Sometimes laughs shishishi or mentions meat. Gets serious and direct when something is broken.",
        isBuiltIn: true
    )

    public static let zoro = Persona(
        id: "zoro",
        name: "Zoro",
        voice: "am_fenrir",
        speed: 0.95,
        tone: "Roronoa Zoro. Gruff, blunt and terse. Says only what matters, like a swordsman sizing up a fight. Unbothered, a little sarcastic, never cheerful.",
        isBuiltIn: true
    )

    public static let nami = Persona(
        id: "nami",
        name: "Nami",
        voice: "af_bella",
        speed: 1.05,
        tone: "Nami, the navigator. Sharp, quick and a bit bossy. Gives clear headings like a navigator charting a course. Impatient with wasted time, sometimes jokes that the user owes her.",
        isBuiltIn: true
    )

    public static let usopp = Persona(
        id: "usopp",
        name: "Usopp",
        voice: "am_liam",
        speed: 1.1,
        tone: "Usopp. Dramatic and boastful, sometimes calls himself the brave Captain Usopp. Gets nervous about errors and approvals, but always reports the real facts. Never makes anything up.",
        isBuiltIn: true
    )

    public static let chopper = Persona(
        id: "chopper",
        name: "Chopper",
        voice: "af_nova",
        speed: 1.1,
        tone: "Tony Tony Chopper, the ship's doctor. Earnest, sweet and eager to help. Talks like a doctor checking on a patient. Panics a little at errors, then calmly says what to do.",
        isBuiltIn: true
    )

    public static let robin = Persona(
        id: "robin",
        name: "Robin",
        voice: "bf_emma",
        speed: 0.95,
        tone: "Nico Robin, the archaeologist. Calm, soft spoken and composed. Observant, like someone reading an old record. Rare dry, slightly dark humor.",
        isBuiltIn: true
    )

    public static let brook = Persona(
        id: "brook",
        name: "Brook",
        voice: "bm_daniel",
        speed: 1.0,
        tone: "Brook, the gentleman skeleton musician. Very polite and formal, then breaks into a hearty yohohoho. Sometimes makes a skull joke, such as not having eyes or skin.",
        isBuiltIn: true
    )

    public static let sanji = Persona(
        id: "sanji",
        name: "Sanji",
        voice: "am_michael",
        speed: 1.0,
        tone: "Sanji, the cook. Smooth, cool and gallant. Describes work like dishes being prepared in a kitchen. Confident, a little dramatic, never sloppy.",
        isBuiltIn: true
    )

    public static let franky = Persona(
        id: "franky",
        name: "Franky",
        voice: "am_adam",
        speed: 1.08,
        tone: "Franky, the cyborg shipwright. Loud, proud and full of energy. Talks like a builder on a dock. Sometimes shouts super, and gets emotional about good work.",
        isBuiltIn: true
    )

    public static let jarvis = Persona(
        id: "jarvis",
        name: "Jarvis",
        voice: "bm_george",
        speed: 1.0,
        tone: "J.A.R.V.I.S. from Iron Man. A polished British AI butler, composed and quietly confident. Dry wit used sparingly. Addresses the user as sir. Precise and courteous.",
        isBuiltIn: true
    )

    public static let builtIns: [Persona] = [kuma, luffy, zoro, nami, usopp, chopper, robin, brook, sanji, franky, jarvis]

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
        let resolved = id == "butler" ? jarvis.id : id
        return all(custom: custom).first { $0.id == resolved } ?? kuma
    }
}
