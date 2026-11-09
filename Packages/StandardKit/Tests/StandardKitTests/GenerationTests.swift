import Foundation
import Testing
@testable import StandardKit

@Suite struct GenerationTests {
    @Test func voiceReplacesSingerTags() {
        let style = Voice.recordingStyle(
            tags: "English, dream pop, 1990s, reverb guitar, warm husky male vocal, slow",
            voice: "female alto vocal, smoky, intimate", isInstrumental: false)
        #expect(style == "English, dream pop, 1990s, reverb guitar, slow, female alto vocal, smoky, intimate")
    }

    @Test func instrumentalsGetNoVoice() {
        let tags = "ambient, synth pads, breathy vocal, calm"
        #expect(Voice.recordingStyle(tags: tags, voice: "male tenor vocal", isInstrumental: true) == "ambient, synth pads, calm, instrumental")
        #expect(Voice.recordingStyle(tags: tags, voice: "instrumental", isInstrumental: false) == "ambient, synth pads, calm, instrumental")
    }

    @Test func missingVoiceLeavesTagsAlone() {
        #expect(Voice.recordingStyle(tags: "rock, male vocal", voice: "", isInstrumental: false) == "rock, male vocal")
    }

    @Test func coverApproachesAreDistinctPerArtist() {
        let picked = CoverDirection.assign(count: 8, genres: ["shoegaze", "dream pop"], seed: 42)
        #expect(picked.count == 8)
        #expect(Set(picked).count == 8)
        // Even past the size of the catalog, every release gets an approach.
        #expect(CoverDirection.assign(count: 30, genres: ["metal"], seed: 7).count == 30)
    }
}

@Suite struct TasteTests {
    @Test func favoritesReachGenerationPrompts() {
        var taste = TasteProfile()
        taste.coreGenres = ["shoegaze"]
        taste.signals = [
            ListeningSignal(kind: .favoriteTrack, artistName: "Velvet Static", genres: ["dream pop"], styleTags: "reverb guitar, hazy", title: "Glass Rain"),
            ListeningSignal(kind: .skip, artistName: "Loud Men", genres: ["metal"], styleTags: "", title: "Skipped Song"),
        ]
        let context = taste.promptContext
        #expect(context.contains("Glass Rain by Velvet Static [reverb guitar, hazy]"))
        #expect(!context.contains("Skipped Song"))
    }
}

@Suite struct GenreGroupTests {
    /// The primary genres of a real 110-artist library.
    static let library: [String: Int] = ["acoustic folk-pop": 24, "acoustic pop": 5, "acoustic rock": 3, "acoustic singer-songwriter": 19, "acoustic singer-songwriter pop": 8, "acoustic sophisti-pop": 2, "adult alternative": 1, "alternative pop": 4, "alternative pop rock": 1, "alternative rock": 1, "anthemic pop rock": 33, "arena rock": 80, "argentine acoustic folk-pop": 1, "art rock": 1, "cinematic dream pop": 16, "french piano pop rock": 3, "french piano rock": 1, "heartland rock": 2, "indie pop": 12, "italian acoustic singer-songwriter": 1, "italian arena rock": 1, "italian rock": 1, "jangle pop": 3, "melodic alternative pop": 42, "melodic alternative rock": 23, "norwegian acoustic folk-pop": 2, "piano pop": 3, "piano pop rock": 11, "piano rock": 33, "piano-driven pop rock": 9, "piano-led alternative pop": 1, "pop rock francophone": 1, "pop rock française": 1, "portuguese acoustic folk-pop": 6, "portuguese pop rock": 4, "progressive rock": 1, "roots rock": 1, "soft rock": 1, "sophisti-pop": 45, "spanish-language pop rock": 2, "swedish alternative pop": 1, "symphonic rock": 1, "theatrical arena rock": 1, "theatrical rock": 1,]

    @Test func nearDuplicatesShareAShelf() {
        let map = GenreGroups.make(Self.library)
        #expect(map["piano-driven pop rock"] == map["piano rock"])
        #expect(map["portuguese acoustic folk-pop"] == map["acoustic folk-pop"])
        #expect(map["acoustic singer-songwriter pop"] == map["acoustic singer-songwriter"])
        #expect(map["sophisti-pop"] == "Sophisti-Pop")
        #expect(map["arena rock"] != map["sophisti-pop"])
        let shelves = Set(map.values)
        print("shelves:", shelves.count, shelves.sorted())
        #expect(shelves.count <= 20)
        #expect(shelves.count >= 6)
    }
}

@Suite struct GenreSoundTests {
    @Test func electropopStartsWithItsCanonicalTagsAndLosesFolkInstruments() {
        let tags = "English, electropop, tactile 2020s production, nylon guitar, felt piano, soft kick, tender, midtempo"
        let out = GenreSound.recordingTags(tags: tags, genres: ["electropop"])
        #expect(out.hasPrefix("electropop, synth-pop, dance pop, synthesizer, synth bass, drum machine"))
        #expect(!out.contains("nylon guitar"))
        #expect(!out.contains("felt piano"))
        #expect(!out.contains("production"))
        #expect(!out.contains("English"))
        #expect(out.hasSuffix("soft kick, tender, midtempo"))
    }

    /// The listening test's failure: synth pads on an arena rock song made YuE2 play synth-pop.
    @Test func arenaRockDropsSynthsAndKeepsItsLanguage() {
        let tags = "Spanish, arena rock, polished 1980s stadium production, electric guitars, synth pads, harmonium, toms, urgent, fast"
        let out = GenreSound.recordingTags(tags: tags, genres: ["arena rock", "hard rock"])
        #expect(out.hasPrefix("arena rock, hard rock, 80s rock, distorted electric guitar, power chords"))
        #expect(!out.contains("synth"))
        #expect(!out.contains("harmonium"))
        #expect(!out.contains("stadium production"))
        #expect(out.hasSuffix("electric guitars, toms, urgent, fast, Spanish"))
        // Each tag appears once even when the writer repeats the genre.
        let parts = out.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(parts.count == Set(parts).count)
    }

    @Test func primaryGenreLeadsTheReferenceTags() {
        let out = GenreSound.recordingTags(tags: "English, folk-inflected indie rock, picked guitars, watchful, brisk", genres: ["Folk-Inflected Indie Rock", "indie folk"])
        #expect(out.hasPrefix("folk-inflected indie rock, indie rock, alternative rock, electric guitar"))
        #expect(out.hasSuffix("picked guitars, watchful, brisk"))
    }

    /// Harmonica, fiddle and "warm" on every song made brooding folk rock come out as upbeat country.
    @Test func folkRockKeepsTheSongsMoodAndLosesCountrySignals() {
        let out = GenreSound.recordingTags(tags: "English, folk rock, acoustic guitar, fiddle, pedal steel, harmonica, brooding, slow", genres: ["folk rock"])
        #expect(out == "folk rock, acoustic guitar, electric guitar, bass guitar, live drums, harmonica, brooding, slow")
        #expect(!GenreSound.guide(for: ["folk rock"]).contains("warm"))
    }

    @Test func unknownGenresKeepTheirOwnTagsInCanonicalForm() {
        #expect(GenreSound.recordingTags(tags: "English, polka, accordion, tuba, a very lively village dance production, jolly", genres: ["polka"])
            == "polka, accordion, tuba, jolly")
    }

    @Test func everyReferenceLeadsWithAGenreName() {
        for ref in GenreSound.references {
            let tags = ref.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(tags.count >= 5 && tags.count <= 10, "\(ref.keys[0])")
            #expect(tags.allSatisfy { $0.split(separator: " ").count <= GenreSound.maxTagWords }, "\(ref.keys[0])")
            #expect(!tags.contains { tag in ref.avoid.lowercased().split(separator: ",").contains { tag.lowercased().contains($0.trimmingCharacters(in: .whitespaces)) } }, "\(ref.keys[0])")
        }
    }

    @Test func specificGenresMatchBeforeBroadOnes() {
        #expect(GenreSound.reference(for: ["electropop"])?.keys.first == "electropop")
        #expect(GenreSound.reference(for: ["indie folk-rock"])?.keys.first == "folk rock")
        #expect(GenreSound.reference(for: ["polka"]) == nil)
    }

    @Test func lyricModesAreStableAndVaried() {
        let a = LyricMode.brief(albumID: "album-1", trackNumber: 3, trackCount: 10, genres: ["indie"])
        #expect(a == LyricMode.brief(albumID: "album-1", trackNumber: 3, trackCount: 10, genres: ["indie"]))
        let picks = LyricMode.assign(count: 10, genres: ["indie"], seed: 42).map(\.name)
        #expect(zip(picks, picks.dropFirst()).allSatisfy { $0 != $1 })
    }
}

@Suite(.serialized) struct ContentRatingTests {
    func withExplicit<T>(_ allowed: Bool, _ body: () -> T) -> T {
        let key = ContentRating.allowExplicitKey
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(allowed, forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        return body()
    }

    func share(_ genres: [String]) -> Double {
        let n = 4000
        let hits = (0 ..< n).filter {
            ContentRating.mayBeExplicit(trackID: "track-\($0)", genres: genres, isInstrumental: false)
        }.count
        return Double(hits) / Double(n)
    }

    @Test func explicitSongsStayAMinorityAndDependOnGenre() {
        withExplicit(true) {
            #expect(abs(share(["hip hop"]) - 0.3) < 0.04)
            #expect(share(["arena rock"]) < 0.12)
            #expect(share(["chamber folk"]) < 0.07)
            #expect(share(["gospel"]) == 0)
            #expect(!ContentRating.mayBeExplicit(trackID: "track-1", genres: ["hip hop"], isInstrumental: true))
        }
    }

    @Test func nothingIsExplicitWhenNotAllowed() {
        withExplicit(false) { #expect(share(["hip hop"]) == 0) }
    }

    @Test func detectsStrongLanguageButNotInnocentWords() {
        #expect(ContentRating.containsExplicitLanguage("[Verse]\nWhat the Fuck is this"))
        #expect(ContentRating.containsExplicitLanguage("bullshit"))
        #expect(ContentRating.containsExplicitLanguage("you dumb bitch"))
        #expect(!ContentRating.containsExplicitLanguage("Dickens on the cocktail shelf, passing glasses"))
        #expect(!ContentRating.containsExplicitLanguage("A quiet song about the sea"))
    }
}
