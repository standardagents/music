import Foundation

/// What each genre actually sounds like on record. The writer otherwise drifts every artist toward
/// the listener's own taste (an indie-folk listener gets "intimate, tactile" electropop with nylon
/// guitar), and the music model only hears the tags, so an electropop song tagged like a folk song
/// comes out as a folk song. These references keep each genre's defining sound in the prompts.
public enum GenreSound {
    struct Reference {
        /// Lowercased keywords matched against an artist's genres; the first entry is the label.
        let keys: [String]
        /// The genre as the music model hears it: genre names first, then its defining instruments and
        /// energy, in short canonical tags. YuE2 follows these far more reliably than descriptive phrases.
        let tags: String
        let instruments: String
        let production: String
        let vocals: String
        /// Things the genre almost never has, which the writer tends to add anyway.
        let avoid: String
    }

    // Ordered most specific first: "electropop" must match before "pop", "folk rock" before "rock".
    static let references: [Reference] = [
        Reference(keys: ["electropop", "electro-pop", "electro pop", "synth-pop", "synthpop", "synth pop", "dance-pop", "dance pop", "hyperpop"],
                  tags: "electropop, synth-pop, dance pop, synthesizer, synth bass, drum machine, electronic, upbeat, catchy",
                  instruments: "analog and digital synthesizers, synth bass, drum machine, programmed claps, arpeggiators, vocoder or vocal chops",
                  production: "glossy, compressed, sidechained, bright, quantized beats, big polished chorus",
                  vocals: "processed or layered lead, auto-tune or doubled vocals, hooky and confident, bright",
                  avoid: "acoustic guitar, nylon guitar, upright piano, felt piano, brushed drums, room tone, folk instruments"),
        Reference(keys: ["synthwave", "retrowave", "outrun"],
                  tags: "synthwave, retrowave, 80s, analog synthesizer, synth bass, gated drums, electronic, nostalgic",
                  instruments: "analog polysynths, gated reverb drums, synth bass arpeggio, electric guitar lead, saxophone",
                  production: "1980s retro, neon, wide chorus effects, punchy, reverb-heavy",
                  vocals: "emotive, reverb-drenched, soaring",
                  avoid: "acoustic instruments, lo-fi room sound"),
        Reference(keys: ["house", "deep house", "disco house"],
                  tags: "house, dance, electronic, four-on-the-floor, synth, piano chords, deep bass, groovy",
                  instruments: "four-on-the-floor kick, open hi-hats, synth stabs, piano chords, deep bass, claps",
                  production: "club mix, groovy, sidechained, long builds, polished",
                  vocals: "soulful diva hooks or chopped vocal samples",
                  avoid: "acoustic guitar, live room drums, folk instruments"),
        Reference(keys: ["techno", "trance", "edm", "drum and bass", "dnb", "dubstep", "electro", "electronic dance", "rave"],
                  tags: "edm, electronic dance, techno, drum machine, synth bass, heavy kick, energetic, driving",
                  instruments: "drum machine, synth bass, sequenced synths, risers, heavy kick",
                  production: "club-loud, driving, hypnotic, sidechained, high energy",
                  vocals: "sparse chopped vocals or short repeated hooks",
                  avoid: "acoustic guitar, piano ballad, folk instruments"),
        Reference(keys: ["arena rock", "stadium rock", "glam metal", "hair metal", "aor", "hard rock"],
                  tags: "arena rock, hard rock, 80s rock, distorted electric guitar, power chords, guitar solo, loud drums, anthemic, powerful",
                  instruments: "distorted electric guitars, power chords, big guitar solo, bass guitar, huge drums",
                  production: "stadium-sized, loud, wide, big reverb on drums, anthemic, polished 80s rock mix",
                  vocals: "powerful belted lead, high-register, gang vocal chorus, soaring",
                  avoid: "synth, drum machine, harmonium, nylon guitar, spoon or found-object percussion, intimate room recording, whispered vocals"),
        Reference(keys: ["metal", "metalcore", "thrash", "doom", "black metal", "death metal", "sludge"],
                  tags: "metal, heavy metal, distorted guitar, heavy riffs, double kick drums, aggressive, intense",
                  instruments: "heavily distorted downtuned guitars, double-kick drums, bass guitar, riffs",
                  production: "crushing, loud, aggressive, tight, heavy",
                  vocals: "screamed, growled or soaring clean metal vocals",
                  avoid: "acoustic folk instruments, soft piano, gentle"),
        Reference(keys: ["punk", "hardcore", "pop-punk", "pop punk", "garage rock", "garage"],
                  tags: "punk rock, punk, distorted electric guitar, bass, fast drums, energetic, raw",
                  instruments: "fast distorted electric guitars, bass guitar, loud drums",
                  production: "raw, fast, loud, energetic, short",
                  vocals: "shouted, snotty, urgent, gang vocals",
                  avoid: "strings, harmonium, gentle, polished ballad"),
        Reference(keys: ["shoegaze", "noise pop", "dream pop"],
                  tags: "shoegaze, dream pop, reverb guitar, fuzz guitar, synth pads, dreamy, hazy",
                  instruments: "washed-out reverb guitars, fuzz pedals, synth pads, bass, steady drums",
                  production: "hazy, layered walls of sound, reverb-soaked, dreamy",
                  vocals: "airy, buried in the mix, ethereal",
                  avoid: "dry close-mic sound, folk instruments"),
        Reference(keys: ["post-punk", "post punk", "new wave", "darkwave", "coldwave", "goth"],
                  tags: "post-punk, new wave, chorus guitar, melodic bass, tight drums, dark, driving",
                  instruments: "chorus-drenched guitar, prominent melodic bass, drum machine or tight drums, synths",
                  production: "cold, angular, driving, reverb, 1980s",
                  vocals: "deadpan, baritone or detached, dramatic",
                  avoid: "folk instruments, warm acoustic sound"),
        Reference(keys: ["hip hop", "hip-hop", "rap", "trap", "drill", "boom bap"],
                  tags: "hip hop, rap, trap, 808 bass, hi-hats, drum machine, sampled beat, rapping, hard-hitting",
                  instruments: "programmed drums, 808 bass, samples, hi-hat rolls, synth or sampled loops",
                  production: "hard-hitting, punchy low end, modern mix",
                  vocals: "rapped verses, rhythmic flow, hooky chorus",
                  avoid: "acoustic guitar, upright bass, harmonium, brushed drums, strings"),
        Reference(keys: ["r&b", "rnb", "neo-soul", "neo soul", "contemporary r&b"],
                  tags: "r&b, contemporary r&b, soul, rhodes, smooth bass, groove drums, smooth, sensual",
                  instruments: "smooth keys, rhodes, deep bass, programmed or live groove drums, lush pads",
                  production: "silky, polished, warm low end, groove-forward",
                  vocals: "smooth, melismatic, layered harmonies",
                  avoid: "folk instruments, distorted guitars"),
        Reference(keys: ["soul", "motown", "funk", "disco"],
                  tags: "soul, funk, horn section, bass guitar, electric piano, live drums, groovy",
                  instruments: "horn section, bass guitar groove, rhythm guitar, organ or electric piano, live drums, strings",
                  production: "groovy, warm analog, tight band, danceable",
                  vocals: "powerful soulful lead, backing vocal harmonies",
                  avoid: "folk instruments, ambient haze"),
        Reference(keys: ["k-pop", "kpop", "j-pop", "jpop", "city pop", "bubblegum", "teen pop"],
                  tags: "pop, dance pop, synthesizer, punchy drums, synth bass, bright, catchy",
                  instruments: "synthesizers, slap or synth bass, punchy drums, bright guitars, polished hooks",
                  production: "glossy, highly polished, dynamic sections, bright",
                  vocals: "bright, layered group or lead vocals, catchy",
                  avoid: "lo-fi, folk instruments, room tone"),
        Reference(keys: ["country", "americana", "bluegrass", "honky-tonk", "outlaw"],
                  tags: "country, americana, acoustic guitar, steel guitar, fiddle, banjo, twang, heartfelt",
                  instruments: "steel guitar, telecaster twang, fiddle, acoustic guitar, banjo, bass, drums",
                  production: "Nashville or roots, warm, clear",
                  vocals: "twangy, storytelling, heartfelt",
                  avoid: "synthesizers, drum machine"),
        Reference(keys: ["jazz", "bebop", "swing", "bossa nova", "bossa"],
                  tags: "jazz, swing, upright bass, piano, saxophone, ride cymbal, smooth",
                  instruments: "upright bass, ride cymbal, piano, saxophone or trumpet, brushes, nylon guitar for bossa",
                  production: "live, acoustic, warm, small-group",
                  vocals: "jazz phrasing, smoky, scat",
                  avoid: "distorted guitar, drum machine, synths"),
        Reference(keys: ["reggae", "dub", "dancehall", "ska"],
                  tags: "reggae, dub, offbeat guitar, heavy bass, one drop drums, organ, laid-back",
                  instruments: "offbeat skank guitar, heavy bass, one-drop drums, organ bubble, horns",
                  production: "deep bass, echo and delay, laid-back",
                  vocals: "patois-inflected, rhythmic",
                  avoid: "folk instruments, stadium rock"),
        Reference(keys: ["latin", "reggaeton", "salsa", "cumbia", "bachata"],
                  tags: "latin, reggaeton, dembow, percussion, bass, brass, danceable",
                  instruments: "dembow or clave rhythm, percussion, bass, brass or synths, guitar",
                  production: "danceable, rhythmic, bright",
                  vocals: "passionate, rhythmic",
                  avoid: "folk harmonium, ambient"),
        Reference(keys: ["ambient", "drone", "new age"],
                  tags: "ambient, atmospheric, synth pads, drones, textures, spacious, calm",
                  instruments: "synth pads, textures, field recordings, slow evolving tones",
                  production: "spacious, floating, slow, atmospheric",
                  vocals: "wordless or sparse",
                  avoid: "loud drums, guitar solos"),
        Reference(keys: ["trip-hop", "trip hop", "downtempo", "chillwave", "lo-fi hip hop"],
                  tags: "trip hop, downtempo, breakbeat, deep bass, rhodes, samples, moody",
                  instruments: "breakbeat drums, deep bass, samples, rhodes, turntable scratches, strings",
                  production: "moody, dusty, slow groove",
                  vocals: "sultry, detached",
                  avoid: "stadium rock, bluegrass"),
        Reference(keys: ["indie rock", "alternative rock", "alt rock", "grunge", "britpop", "post-grunge"],
                  tags: "indie rock, alternative rock, electric guitar, bass guitar, live drums, energetic",
                  instruments: "electric guitars, bass guitar, live drums, occasional keys",
                  production: "band in a room, guitar-driven, energetic",
                  vocals: "expressive, earnest or sneering",
                  avoid: "harmonium, chamber strings on every song"),
        // No harmonica or "warm" in the tags: with a live band they read to YuE2 as upbeat country, which
        // drowned out the song's own mood (a brooding folk-rock record came out sounding like Americana).
        Reference(keys: ["folk rock", "folk-rock"],
                  tags: "folk rock, acoustic guitar, electric guitar, bass guitar, live drums",
                  instruments: "acoustic and electric guitars, bass guitar, live drums; harmonica or organ only as occasional color",
                  production: "a band in a room; the mood follows the record, from spare and brooding to driving",
                  vocals: "earnest or weathered lead, harmonies",
                  avoid: "fiddle, banjo, pedal steel, twang, country, bluegrass, honky-tonk, drum machine, synth bass"),
        Reference(keys: ["folk", "singer-songwriter", "chamber folk", "acoustic"],
                  tags: "folk, indie folk, acoustic guitar, fingerpicked, piano, strings, warm, gentle",
                  instruments: "acoustic guitar, piano, strings, light percussion",
                  production: "intimate, warm, natural",
                  vocals: "close, conversational",
                  avoid: "heavy distortion, club beats"),
        Reference(keys: ["pop"],
                  tags: "pop, synthesizer, punchy drums, bass, catchy, polished",
                  instruments: "synthesizers, punchy drums, bass, guitars or piano supporting a big hook",
                  production: "polished radio-ready mix, big chorus",
                  vocals: "confident, catchy, upfront",
                  avoid: "lo-fi room tone, folk instruments"),
        Reference(keys: ["rock"],
                  tags: "rock, electric guitar, bass guitar, drums, energetic",
                  instruments: "electric guitars, bass guitar, drums, solos",
                  production: "loud, driving band mix",
                  vocals: "strong, gritty",
                  avoid: "harmonium, felt piano"),
    ]

    /// The reference for an artist's genres (primary genre first), or nil for genres not covered.
    static func reference(for genres: [String]) -> Reference? {
        let lowered = genres.map { $0.lowercased() }
        for genre in lowered {
            if let hit = references.first(where: { ref in ref.keys.contains { genre.contains($0) } }) { return hit }
        }
        return nil
    }

    /// A prompt paragraph describing the genre's real sound, or "" when nothing matches.
    public static func guide(for genres: [String]) -> String {
        guard let r = reference(for: genres) else { return "" }
        let name = genres.first ?? r.keys[0]
        return """
            What \(name) sounds like on real records (stay true to it, whatever the listener's other tastes): \
            instruments: \(r.instruments). Production: \(r.production). Vocals: \(r.vocals). \
            Rarely has: \(r.avoid).
            """
    }
}

extension GenreSound {
    /// Song-specific tags kept after the genre's own tags: the writer puts mood and tempo last.
    static let maxSongTags = 4
    /// Tags longer than this are descriptive phrases ("polished 1980s stadium production") that YuE2
    /// mostly ignores or misreads; canonical tags are one to three words.
    static let maxTagWords = 3
    /// Production-feel descriptors ("glossy 2020s production", "live-room mix") that dilute the genre.
    static let productionWords: Set<String> = ["production", "produced", "mix", "mixed", "recording", "recorded", "master", "mastered"]
    static let languages: Set<String> = [
        "english", "spanish", "french", "german", "italian", "portuguese", "japanese", "korean", "chinese",
        "mandarin", "cantonese", "swedish", "norwegian", "danish", "finnish", "icelandic", "dutch", "polish",
        "russian", "turkish", "arabic", "hindi", "greek", "catalan", "irish", "welsh", "hebrew", "czech",
    ]

    /// The genre part of the style prompt, in the order YuE2 follows best: the artist's genre and the
    /// reference's canonical tags first, then a few short song-specific tags (mood, tempo, a featured
    /// instrument). Off-genre instruments and long descriptive phrases are dropped. In listening tests
    /// this moved arena rock that the model rendered as synth-pop back to arena rock, and made
    /// genres measurably further apart.
    /// A listener's own style (Create › Custom), cleaned but not rewritten: their genre and
    /// instruments stay first and nothing is dropped for being "off-genre".
    public static func customRecordingTags(tags: String) -> String {
        var seen = Set<String>()
        return tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(14).joined(separator: ", ")
    }

    public static func recordingTags(tags: String, genres: [String]) -> String {
        let ref = reference(for: genres)
        let avoid = (ref?.avoid ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        func split(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var head: [String] = []
        func add(_ tag: String) {
            let lower = tag.lowercased()
            if !head.contains(where: { $0.lowercased() == lower }) { head.append(tag) }
        }
        if let primary = genres.first?.trimmingCharacters(in: .whitespaces), !primary.isEmpty { add(primary.lowercased()) }
        split(ref?.tags ?? "").forEach(add)

        var language: String?
        var song: [String] = []
        for tag in split(tags) {
            let lower = tag.lowercased()
            if languages.contains(lower) {
                if lower != "english" { language = tag }  // the lyrics already carry English
                continue
            }
            let words = lower.split(whereSeparator: { $0 == " " || $0 == "-" })
            if tag.split(separator: " ").count > maxTagWords || words.contains(where: { productionWords.contains(String($0)) }) { continue }
            if avoid.contains(where: { lower.contains($0) }) { continue }
            // Genre names the head already has, and plain repeats.
            if head.contains(where: { $0.lowercased() == lower }) || genres.contains(where: { $0.lowercased() == lower }) { continue }
            if song.contains(where: { $0.lowercased() == lower }) { continue }
            song.append(tag)
        }
        if ref == nil {
            // Unknown genre: keep the writer's own instruments, just in the canonical order and length.
            return (head + song.prefix(8 + maxSongTags) + [language].compactMap { $0 }).joined(separator: ", ")
        }
        return (head + song.suffix(maxSongTags) + [language].compactMap { $0 }).joined(separator: ", ")
    }
}
