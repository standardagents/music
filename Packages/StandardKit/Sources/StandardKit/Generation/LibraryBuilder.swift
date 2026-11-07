import Foundation
import GRDB
import OSLog

let buildLog = Logger(subsystem: "com.standardmusic", category: "builder")

/// What a generation batch should produce.
public struct BuildRequest: Codable, Sendable, Hashable {
    public var artistCount: Int
    /// Free-text brief from the Create page ("90s Icelandic shoegaze").
    public var prompt: String?
    /// Existing artist to riff on ("More like this").
    public var seedArtistID: ID?
    /// Share of core / adjacent / wildcard artists.
    public var coreShare: Double
    public var adjacentShare: Double

    public init(artistCount: Int, prompt: String? = nil, seedArtistID: ID? = nil, coreShare: Double = 0.6,
        adjacentShare: Double = 0.3)
    {
        self.artistCount = artistCount
        self.prompt = prompt
        self.seedArtistID = seedArtistID
        self.coreShare = coreShare
        self.adjacentShare = adjacentShare
    }
}

public struct BuildStatus: Sendable, Equatable {
    public enum Phase: String, Sendable { case idle, planning, writing, waiting, finished, failed }
    public var batchID: ID?
    public var title: String
    public var phase: Phase
    public var artistsReady: Int
    public var artistsTotal: Int
    /// Finished work measured in artists, counting partly written artists fractionally
    /// (story, each album's writing, portrait, each cover).
    public var progress: Double = 0
    /// Artists currently being written or painted.
    public var artistsInProgress: Int = 0
    public var activity: String
    public var waitingUntil: Date?
    public var error: String?

    public static let idle = BuildStatus(
        batchID: nil, title: "", phase: .idle, artistsReady: 0, artistsTotal: 0, activity: "")

    public var fraction: Double {
        artistsTotal > 0 ? min(1, max(Double(artistsReady), progress) / Double(artistsTotal)) : 0
    }
}

/// Writes artists, discographies, souls and artwork with ChatGPT, persisting every step so a batch
/// survives quitting the app. Artists become visible (status `.ready`) one by one as they complete.
public actor LibraryBuilder {
    let db: AppDatabase
    let client: ChatGPTClient
    let catalog: Catalog?
    let artwork: ArtworkStore
    let textLimit = AsyncSemaphore(16)
    let imageLimit = AsyncSemaphore(16)
    let artistLimit = AsyncSemaphore(16)
    private var running: [ID: Task<Void, Never>] = [:]
    private var status = BuildStatus.idle
    private var observers: [UUID: @Sendable (BuildStatus) -> Void] = [:]
    private var activity: [ID: String] = [:]

    public init(db: AppDatabase, client: ChatGPTClient, catalog: Catalog?, artwork: ArtworkStore) {
        self.db = db
        self.client = client
        self.catalog = catalog
        self.artwork = artwork
    }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (BuildStatus) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(status)
        return id
    }

    public var currentStatus: BuildStatus { status }

    private func publish(_ change: (inout BuildStatus) -> Void) {
        change(&status)
        let snapshot = status
        for o in observers.values { o(snapshot) }
    }

    // MARK: Batches

    /// Starts a new batch and returns its id. Work continues in the background.
    @discardableResult
    public func start(kind: BatchKind, title: String, request: BuildRequest) throws -> ID {
        let raw = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let batch = GenerationBatch(kind: kind, title: title, request: raw, targetArtists: request.artistCount)
        try db.writer.write { try batch.insert($0) }
        launch(batch)
        return batch.id
    }

    /// Picks up unfinished batches after launch. With `retryFailed`, failed batches and artists get
    /// another go (the "Try Again" button).
    public func resumeUnfinished(retryFailed: Bool = false) throws {
        var statuses = [BatchStatus.planning.rawValue, BatchStatus.running.rawValue]
        if retryFailed { statuses.append(BatchStatus.failed.rawValue) }
        let batches = try db.writer.write { db in
            let batches = try GenerationBatch.filter(statuses.contains(Column("status"))).order(Column("createdAt")).fetchAll(db)
            if retryFailed {
                for batch in batches where batch.status == .failed {
                    try db.execute(
                        sql: "UPDATE artist SET status = CASE WHEN soul = '' THEN 'planned' ELSE 'written' END WHERE batchID = ? AND status = 'failed'",
                        arguments: [batch.id])
                    try db.execute(sql: "UPDATE generationBatch SET status = 'running', error = NULL WHERE id = ?", arguments: [batch.id])
                }
            }
            return batches
        }
        for batch in batches where running[batch.id] == nil { launch(batch) }
        resumeOrphanedReleases()
    }

    /// New releases interrupted by quitting: finish their tracklist and cover.
    private func resumeOrphanedReleases() {
        guard let orphans = try? db.reader.read({ db in
            try Album.filter(Column("status") != ItemStatus.ready.rawValue)
                .joining(required: Album.artist.filter(Column("status") == ItemStatus.ready.rawValue))
                .fetchAll(db)
        }), !orphans.isEmpty else { return }
        Task {
            for album in orphans {
                guard let artist = try? await db.reader.read({ try Artist.fetchOne($0, key: album.artistID) }) else { continue }
                do {
                    var album = album
                    if album.notes.isEmpty || album.status == .planned { album = try await writeAlbum(album, artist: artist) }
                    if album.coverPath == nil { try await paintCover(album, artist: artist) }
                    _ = try db.modifyAlbum(album.id) { $0.status = .ready }
                } catch {
                    buildLog.error("Couldn't finish release \(album.title): \(error.localizedDescription)")
                }
            }
        }
    }

    public func cancel(batchID: ID) throws {
        running[batchID]?.cancel()
        running[batchID] = nil
        try db.writer.write { db in
            try db.execute(sql: "UPDATE generationBatch SET status = 'cancelled' WHERE id = ?", arguments: [batchID])
        }
        publish { $0.phase = .idle }
    }

    private func launch(_ batch: GenerationBatch) {
        running[batch.id] = Task { [weak self] in
            await self?.run(batch)
        }
    }

    private func run(_ batch: GenerationBatch) async {
        let request = (try? JSONDecoder().decode(BuildRequest.self, from: Data(batch.request.utf8)))
            ?? BuildRequest(artistCount: batch.targetArtists)
        publish {
            $0 = BuildStatus(
                batchID: batch.id, title: batch.title, phase: .planning, artistsReady: readyCount(batch.id),
                artistsTotal: request.artistCount, activity: "Scouting artists")
        }
        do {
            while true {
                do {
                    try await plan(batch: batch, request: request)
                    break
                } catch ChatGPTError.rateLimited(let retryAfter, let message) {
                    await waitForUsage(retryAfter: retryAfter, message: message)
                }
            }
            try setBatchStatus(batch.id, .running)
            publish { $0.phase = .writing }
            try await writeAll(batch: batch)
            let failures = try await db.reader.read { db in
                try Artist.filter(Column("batchID") == batch.id && Column("status") != ItemStatus.ready.rawValue).fetchCount(db)
            }
            // The UI shows `error` when a build fails; without it a partial failure read "Something went wrong."
            let message = failures == 0 ? nil : Self.unfinishedMessage(failures)
            try setBatchStatus(batch.id, failures == 0 ? .finished : .failed, error: message)
            publish {
                $0.phase = failures == 0 ? .finished : .failed
                $0.error = message
                $0.activity = message ?? "Your library is ready"
                $0.artistsReady = readyCount(batch.id)
                $0.progress = Double($0.artistsReady)
                $0.artistsInProgress = 0
            }
        } catch is CancellationError {
            buildLog.notice("Batch \(batch.id) cancelled")
        } catch {
            buildLog.error("Batch failed: \(error.localizedDescription)")
            try? setBatchStatus(batch.id, .failed, error: error.localizedDescription)
            publish {
                $0.phase = .failed
                $0.error = error.localizedDescription
            }
        }
        running[batch.id] = nil
    }

    private func setBatchStatus(_ id: ID, _ status: BatchStatus, error: String? = nil) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE generationBatch SET status = ?, error = ?, finishedAt = ? WHERE id = ?",
                arguments: [status.rawValue, error, status == .finished || status == .failed ? Date() : nil, id])
        }
    }

    /// Sums each artist's completed steps over its total steps.
    private nonisolated func progress(_ batchID: ID) -> Double {
        let rows = (try? db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT a.status, a.imagePath IS NOT NULL AS portrait, a.plannedAlbumCount AS planned,
                        COUNT(al.id) AS albums,
                        COALESCE(SUM(al.status IN ('written', 'ready')), 0) AS written,
                        COALESCE(SUM(al.coverPath IS NOT NULL), 0) AS covers
                    FROM artist a LEFT JOIN album al ON al.artistID = a.id
                    WHERE a.batchID = ?
                    GROUP BY a.id
                    """, arguments: [batchID])
        }) ?? []
        return rows.reduce(0) { total, row in
            let status: String = row["status"]
            if status == ItemStatus.ready.rawValue { return total + 1 }
            let albums = max(row["albums"] as Int, row["planned"] as Int, 1)
            let steps = 2 + 2 * albums
            var done = (row["portrait"] as Bool ? 1 : 0) + (row["written"] as Int) + (row["covers"] as Int)
            if status == ItemStatus.written.rawValue || (row["albums"] as Int) > 0 { done += 1 }
            return total + min(0.95, Double(done) / Double(steps))
        }
    }

    private func publishProgress(_ batchID: ID) {
        let value = progress(batchID)
        let active = activity.count
        publish {
            $0.progress = value
            $0.artistsInProgress = active
        }
    }

    private nonisolated func readyCount(_ batchID: ID) -> Int {
        (try? db.reader.read { db in
            try Artist.filter(Column("batchID") == batchID && Column("status") == ItemStatus.ready.rawValue).fetchCount(db)
        }) ?? 0
    }

    private func profile() -> TasteProfile {
        db.value(TasteProfile.self, forKey: TasteProfile.storageKey) ?? TasteProfile()
    }

    // MARK: Planning (roster)

    struct Slot: Sendable {
        var tier: TasteTier
        var genre: String
    }

    func slots(for request: BuildRequest, profile: TasteProfile, count: Int) -> [Slot] {
        if request.prompt != nil || request.seedArtistID != nil {
            return (0 ..< count).map { i in Slot(tier: i % 5 == 4 ? .adjacent : .core, genre: "") }
        }
        let core = profile.coreGenres.isEmpty ? profile.selectedGenres : profile.coreGenres
        let adjacent = profile.adjacentGenres.isEmpty ? core : profile.adjacentGenres
        let wild = profile.wildcardGenres.isEmpty ? adjacent : profile.wildcardGenres
        let nCore = Int((Double(count) * request.coreShare).rounded())
        let nAdj = Int((Double(count) * request.adjacentShare).rounded())
        let nWild = max(0, count - nCore - nAdj)
        func spread(_ genres: [String], _ n: Int, _ tier: TasteTier) -> [Slot] {
            guard !genres.isEmpty else { return [] }
            return (0 ..< n).map { Slot(tier: tier, genre: genres[$0 % genres.count]) }
        }
        // Interleave so core artists arrive first but the stream stays varied.
        var out: [Slot] = []
        var c = spread(core, nCore, .core)[...]
        var a = spread(adjacent, nAdj, .adjacent)[...]
        var w = spread(wild, nWild, .wildcard)[...]
        while !(c.isEmpty && a.isEmpty && w.isEmpty) {
            for _ in 0 ..< 3 { if let s = c.popFirst() { out.append(s) } }
            if let s = a.popFirst() { out.append(s) }
            if out.count % 10 == 9, let s = w.popFirst() { out.append(s) }
            if c.isEmpty, let s = w.popFirst() { out.append(s) }
        }
        return out
    }

    struct RosterPayload: Decodable, Sendable {
        struct Concept: Decodable, Sendable {
            var name: String
            var primaryGenre: String
            var genres: [String]
            var tags: [String]
            var origin: String
            var formedYear: Int
            var tagline: String
            var albumCount: Int
            var touchstones: [String]
        }
        var artists: [Concept]
    }

    private func plan(batch: GenerationBatch, request: BuildRequest) async throws {
        let existing = try await db.reader.read { db in
            try Artist.filter(Column("batchID") == batch.id).fetchCount(db)
        }
        var missing = request.artistCount - existing
        guard missing > 0 else { return }
        let profile = profile()
        var seedArtist: Artist?
        if let seed = request.seedArtistID { seedArtist = try await db.reader.read { try Artist.fetchOne($0, key: seed) } }
        var allSlots = slots(for: request, profile: profile, count: request.artistCount)
        allSlots = Array(allSlots.suffix(missing))
        let seed = seedArtist
        var attempts = 0
        while missing > 0, attempts < 6 {
            attempts += 1
            let chunks = stride(from: 0, to: allSlots.count, by: 10).map { Array(allSlots[$0 ..< min($0 + 10, allSlots.count)]) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for chunk in chunks {
                    group.addTask {
                        try await self.rosterChunk(chunk, batch: batch, profile: profile, request: request, seed: seed)
                    }
                }
                try await group.waitForAll()
            }
            let have = try await db.reader.read { try Artist.filter(Column("batchID") == batch.id).fetchCount($0) }
            missing = request.artistCount - have
            allSlots = Array(slots(for: request, profile: profile, count: request.artistCount).suffix(max(0, missing)))
        }
    }

    private func rosterChunk(
        _ chunk: [Slot], batch: GenerationBatch, profile: TasteProfile, request: BuildRequest, seed: Artist?
    ) async throws {
        try Task.checkCancellation()
        let taken = try await db.reader.read { db in try String.fetchAll(db, sql: "SELECT name FROM artist") }
        let concepts = try await db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT primaryGenre || ': ' || tagline FROM artist ORDER BY RANDOM() LIMIT 40")
        }
        let slotLines = chunk.enumerated().map { i, s in
            "\(i + 1). \(s.tier.rawValue)\(s.genre.isEmpty ? "" : " — \(s.genre)")"
        }
        var brief = ""
        if let prompt = request.prompt { brief = "The listener asked for: \"\(prompt)\". Every artist must fit this brief.\n" }
        if let seed {
            brief = """
                Create artists for fans of \(seed.name) (\(seed.genres.joined(separator: ", ")); \(seed.tagline)).
                Their sound: \(seed.soul.prefix(600))
                They should feel like the same scene, labelmates or influences/descendants — related but distinct.

                """
        }
        let schema = Schema.object([
            "artists": Schema.array(
                Schema.object([
                    "name": Schema.string(),
                    "primaryGenre": Schema.string("Specific genre, e.g. 'dream pop'"),
                    "genres": Schema.array(Schema.string(), min: 2, max: 4),
                    "tags": Schema.array(Schema.string("Scene/sound/era keyword"), min: 3, max: 6),
                    "origin": Schema.string("City, Country"),
                    "formedYear": Schema.integer(),
                    "tagline": Schema.string("≤ 60 chars, like a streaming service's artist subtitle"),
                    "albumCount": Schema.integer("1–10"),
                    "touchstones": Schema.array(Schema.string("Real artist they resemble"), min: 2, max: 3),
                ]), min: chunk.count, max: chunk.count),
        ])
        let prompt = """
            \(brief)Invent \(chunk.count) fictional recording artists for this listener's personal music library.

            \(profile.promptContext)

            Slots (tier — genre). Core = squarely in their taste. Adjacent = a neighboring style. Wildcard = a tasteful surprise:
            \(slotLines.joined(separator: "\n"))

            Rules:
            - Names must be original and must NOT be the name of any real artist, band or alias. Mix naming styles: personal names, band names, one-word names, "The …", producer aliases, non-English names where the origin suggests it.
            - Feel like real careers: varied countries and cities, formation years from the 1960s to 2025 shaped by the genre and the listener's eras.
            - The listener profile decides WHICH genres and artists to include, not how they sound. Each artist must sound authentically like its slot's genre as real fans know it; don't carry the listener's sonic preferences (e.g. "intimate", "warm", "acoustic") into other genres. An arena rock band is loud and huge; an electropop act is synthetic and glossy.
            - albumCount: mostly 2–4; some 1 (newcomers or one-album wonders); a few long careers of 6–10.
            - Every artist needs its own world — distinct settings, subjects, eras, personas and visual identity. Don't repeat concepts already in the library:
            \(concepts.isEmpty ? "(none yet)" : concepts.joined(separator: "\n"))
            - Never reuse a distinctive word from an existing name (e.g. if "Mara Venn" exists, no other "Mara" or "Venn"). Avoid these names already in the library: \(taken.suffix(400).joined(separator: ", "))
            """
        let payload = try await textLimit.run {
            try await self.client.json(
                RosterPayload.self, schemaName: "artist_roster", schema: schema,
                instructions: "You are an A&R visionary and music historian inventing a believable alternate-universe music scene.",
                prompt: prompt, effort: "low")
        }
        // Re-read: sibling chunks run concurrently and may have added names meanwhile.
        let current = try await db.reader.read { db in try String.fetchAll(db, sql: "SELECT name FROM artist") }
        var names = Set(current.map { $0.lowercased() })
        var words = Set(current.flatMap(Self.distinctiveWords))
        for (i, concept) in payload.artists.enumerated() {
            let name = concept.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !names.contains(name.lowercased()) else { continue }
            let nameWords = Self.distinctiveWords(name)
            if !words.isDisjoint(with: nameWords) {
                buildLog.info("Skipping \(name): echoes an existing artist name")
                continue
            }
            words.formUnion(nameWords)
            if catalog?.isRealArtistName(name) == true {
                buildLog.info("Skipping real artist name \(name)")
                continue
            }
            names.insert(name.lowercased())
            let slot = chunk[min(i, chunk.count - 1)]
            let artist = Artist(
                name: name, primaryGenre: concept.primaryGenre, genres: concept.genres, tags: concept.tags,
                origin: concept.origin, formedYear: min(max(concept.formedYear, 1950), 2025), tagline: concept.tagline,
                tier: slot.tier, plannedAlbumCount: min(max(concept.albumCount, 1), 10),
                touchstones: concept.touchstones, batchID: batch.id)
            try db.save(artist: artist)
        }
    }

    static let commonWords: Set<String> = [
        "the", "and", "of", "los", "las", "les", "el", "la", "le", "de", "del", "der", "die", "das", "band",
        "trio", "quartet", "orchestra", "ensemble", "collective", "club", "project", "experience", "featuring",
    ]

    /// Lower-cased words that make a name recognizable (no articles, connectors or group nouns).
    static func distinctiveWords(_ name: String) -> [String] {
        name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !commonWords.contains($0) }
    }

    // MARK: Writing

    private func writeAll(batch: GenerationBatch) async throws {
        let pending = try await db.reader.read { db in
            try Artist.filter(Column("batchID") == batch.id && Column("status") != ItemStatus.ready.rawValue)
                .order(Column("createdAt")).fetchAll(db)
        }
        // Core first so the listener's favorites land early.
        var ordered = Array(pending.filter { $0.tier == .core }.prefix(16) + pending.filter { a in
            !pending.filter { $0.tier == .core }.prefix(16).contains(where: { $0.id == a.id })
        })
        // The "while you wait" artist goes first of all.
        let openerID = batch.kind == .initialLibrary ? (try? chooseOpener(batch: batch)) ?? nil : nil
        if let openerID, let i = ordered.firstIndex(where: { $0.id == openerID }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishProgress(batch.id)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { ticker.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for artist in ordered {
                group.addTask {
                    await self.artistLimit.wait(first: artist.id == openerID)
                    defer { Task { await self.artistLimit.signal() } }
                    var attempt = 0
                    while true {
                        try Task.checkCancellation()
                        do {
                            try await self.complete(artistID: artist.id)
                            break
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch ChatGPTError.rateLimited(let retryAfter, let message) {
                            // Out of plan usage: pause until it resets instead of burning through artists.
                            await self.waitForUsage(retryAfter: retryAfter, message: message)
                        } catch {
                            attempt += 1
                            buildLog.error("Artist \(artist.name) failed (attempt \(attempt)): \(error.localizedDescription)")
                            if attempt >= 3 {
                                _ = try? self.db.modifyArtist(artist.id) { $0.status = .failed }
                                break
                            }
                            try await Task.sleep(for: .seconds(5 * attempt))
                        }
                    }
                    await self.setActivity(artist.id, nil)
                    await self.publishReady(batch.id)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Picks the artist for the first song the listener hears (once per library; a relaunch keeps it).
    /// Returns the opener artist's id when it still needs writing in this batch.
    private func chooseOpener(batch: GenerationBatch) throws -> ID? {
        if let state = db.openerState {
            // Already chosen (relaunch): keep it unless that artist is gone or couldn't be written.
            if let id = state.artistID,
                let artist = try db.reader.read({ try Artist.fetchOne($0, key: id) }), artist.status != .failed
            {
                return artist.id
            }
            if state.trackID != nil { return nil }
        }
        guard let genre = Opener.favoriteGenre(profile()) else { return nil }
        let roster = try db.reader.read { db in
            try Artist.filter(Column("batchID") == batch.id).order(Column("createdAt")).fetchAll(db)
        }
        guard let artist = Opener.pickArtist(roster, genre: genre) else { return nil }
        try db.setOpenerState(OpenerState(genre: genre, artistID: artist.id))
        buildLog.info("Opener: \(artist.name) for \(genre)")
        return artist.id
    }

    private var waitingUntil: Date?

    private func waitForUsage(retryAfter: TimeInterval?, message: String) async {
        let until = waitingUntil.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(min(retryAfter ?? 300, 6 * 3600))
        waitingUntil = until
        publish {
            $0.phase = .waiting
            $0.waitingUntil = until
            $0.activity = message
        }
        try? await Task.sleep(for: .seconds(max(5, until.timeIntervalSinceNow)))
        if waitingUntil == until { waitingUntil = nil }
        publish {
            $0.phase = .writing
            $0.waitingUntil = nil
        }
    }

    private func publishReady(_ batchID: ID) {
        let ready = readyCount(batchID)
        publish {
            $0.artistsReady = ready
            $0.activity = activity.values.first ?? $0.activity
        }
        publishProgress(batchID)
    }

    func setActivity(_ artistID: ID, _ text: String?) {
        activity[artistID] = text
        if let text { publish { $0.activity = text } }
    }

    /// Brings one artist from concept to fully ready, skipping steps already persisted.
    public func complete(artistID: ID) async throws {
        guard var artist = try await db.reader.read({ try Artist.fetchOne($0, key: artistID) }) else { return }
        let profile = profile()
        // The opener artist's story, lead release and its cover jump the line: the listener hears
        // that song while everything else is written.
        let opener = db.openerState.flatMap { $0.artistID == artistID && $0.trackID == nil ? $0 : nil }
        if artist.status == .planned || artist.status == .failed && artist.soul.isEmpty {
            setActivity(artistID, "Writing \(artist.name)'s story")
            artist = try await writeArtist(artist, profile: profile, urgent: opener != nil)
        }
        let albums = try await db.reader.read { db in
            try Album.filter(Column("artistID") == artistID).order(Column("releaseYear")).fetchAll(db)
        }
        var leadID: ID?
        if var state = opener {
            leadID = albums.first { $0.id == state.albumID }?.id ?? Opener.leadAlbum(albums)?.id
            if state.albumID != leadID {
                state.albumID = leadID
                try? db.setOpenerState(state)
            }
        }
        let snapshot = artist
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                if snapshot.imagePath == nil { try await self.paintPortrait(snapshot) }
            }
            for album in albums {
                let urgent = album.id == leadID
                group.addTask {
                    var album = album
                    if album.status == .planned || album.notes.isEmpty {
                        album = try await self.writeAlbum(album, artist: snapshot, urgent: urgent)
                    }
                    if album.coverPath == nil { try await self.paintCover(album, artist: snapshot, urgent: urgent) }
                    _ = try self.db.modifyAlbum(album.id) { $0.status = .ready }
                }
            }
            try await group.waitForAll()
        }
        _ = try db.modifyArtist(artistID) { $0.status = .ready }
        setActivity(artistID, nil)
    }

    struct ArtistPayload: Decodable, Sendable {
        struct AlbumOutline: Decodable, Sendable {
            var title: String
            var year: Int
            var kind: String
            var label: String
            var soul: String
            var coverConcept: String
            var trackCount: Int
        }
        var bio: String
        var soul: String
        var voice: String
        var members: [String]
        var disbandedYear: Int?
        var portraitConcept: String
        var albums: [AlbumOutline]
    }

    private func writeArtist(_ artist: Artist, profile: TasteProfile, urgent: Bool = false) async throws -> Artist {
        let usedTitles = try await db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM album ORDER BY RANDOM() LIMIT 60")
        }
        let schema = Schema.object([
            "bio": Schema.string(),
            "soul": Schema.string(),
            "voice": Schema.string(),
            "members": Schema.array(Schema.string()),
            "disbandedYear": Schema.nullable(Schema.integer()),
            "portraitConcept": Schema.string(),
            "albums": Schema.array(
                Schema.object([
                    "title": Schema.string(),
                    "year": Schema.integer(),
                    "kind": Schema.enumeration(AlbumKind.allCases.map(\.rawValue)),
                    "label": Schema.string("Record label (fictional or plausible indie)"),
                    "soul": Schema.string(),
                    "coverConcept": Schema.string(),
                    "trackCount": Schema.integer(),
                ]), min: artist.plannedAlbumCount, max: artist.plannedAlbumCount),
        ])
        let coverApproaches = CoverDirection.assign(count: artist.plannedAlbumCount, genres: [artist.primaryGenre] + artist.genres + artist.tags)
        let prompt = """
            Write the full dossier for this fictional artist.

            Name: \(artist.name)
            Genre: \(artist.primaryGenre) (\(artist.genres.joined(separator: ", ")))
            Tags: \(artist.tags.joined(separator: ", "))
            Origin: \(artist.origin). Formed/debuted: \(artist.formedYear).
            Tagline: \(artist.tagline)
            Sounds a bit like (never mention these): \(artist.touchstones.joined(separator: ", "))
            Releases to plan: \(artist.plannedAlbumCount)

            \(GenreSound.guide(for: [artist.primaryGenre] + artist.genres))
            Write this artist as a true, idiomatic \(artist.primaryGenre) act: their soul, voice and every release should sound like the genre does on real records, not softened toward any other style.
            Album titles already used by other artists in this library — don't reuse their words or imagery: \(usedTitles.joined(separator: "; "))

            Fields:
            - bio: 170–260 words, encyclopedic and vivid like a great streaming-service artist bio. Two or three paragraphs separated by blank lines. Cover origins, members or persona, breakthrough, how the sound evolved, and name several releases exactly as titled below. Never mention real artists, AI or that they are fictional.
            - soul (private, never shown): 150–250 words defining their sonic DNA — instrumentation, production, vocal timbre and delivery, harmonic and rhythmic habits, lyrical themes, and how all of this changes across their career, release by release.
            - \(Voice.fieldGuidance)
            - members: for groups "Name — role"; for solo artists list collaborators or leave empty.
            - disbandedYear: null if still active.
            - portraitConcept: art direction for their press photo, 60–110 words, built on the direction assigned below (keep its framing, look, setting, light and casting; make each concrete and specific to this artist, their era and their scene). Describe the people as individuals: age, build, hair, clothes with real color, expression. People must be fictional. No text.
            Portrait direction:
            \(PortraitDirection.assign(genres: [artist.primaryGenre] + artist.genres + artist.tags, isGroup: nil))
            - albums: exactly \(artist.plannedAlbumCount), chronological, years between \(artist.formedYear) and 2026 and plausible for the arc. kind: mostly "album"; use "ep", "single", "live" or "compilation" only where it makes the discography feel real. trackCount: album 8–12, ep 4–6, single 1–3, live 10–13, compilation 10–14.
              - soul (private): 90–160 words: the concept, the production approach and the sequence — map the tone, tempo and energy of the songs from opener to closer.
              - coverConcept: specific art direction for the cover, built on the visual approach assigned to that release below (keep its medium — don't turn a photo into a still life or a painting into a document). Say what is pictured, the palette, and the typography (or no text). True to the era and the genre's real sleeve conventions.
            Visual approach for each release, in order:
            \(coverApproaches.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """
        let p = try await textLimit.run(first: urgent) {
            try await self.client.json(
                ArtistPayload.self, schemaName: "artist_dossier", schema: schema,
                instructions: "You are a music historian writing the canonical record of an alternate-universe artist. Be specific, sensory and consistent.",
                prompt: prompt, effort: "low")
        }
        var updated = artist
        updated.bio = p.bio
        updated.soul = p.soul
        updated.voice = p.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.members = p.members
        updated.disbandedYear = p.disbandedYear
        updated.imagePrompt = p.portraitConcept
        updated.status = .written
        let artistID = artist.id
        let final = updated
        try await db.writer.write { db in
            try final.update(db)
            try AppDatabase.index(db, artist: final)
            // Replace any stale outlines from an interrupted run.
            try Album.filter(Column("artistID") == artistID).deleteAll(db)
            for o in p.albums {
                let kind = AlbumKind(rawValue: o.kind) ?? .album
                let album = Album(
                    artistID: artistID, title: o.title, releaseYear: min(max(o.year, artist.formedYear), 2026),
                    kind: kind, label: o.label, primaryGenre: artist.primaryGenre, genres: artist.genres, soul: o.soul,
                    coverPrompt: o.coverConcept, trackCount: Self.clampTracks(o.trackCount, kind))
                try album.insert(db)
                try AppDatabase.index(db, album: album, artistName: artist.name)
            }
        }
        return updated
    }

    static func clampTracks(_ n: Int, _ kind: AlbumKind) -> Int {
        switch kind {
        case .single: min(max(n, 1), 3)
        case .ep: min(max(n, 3), 7)
        case .album: min(max(n, 7), 14)
        case .live, .compilation: min(max(n, 8), 16)
        }
    }

    struct AlbumPayload: Decodable, Sendable {
        struct Song: Decodable, Sendable {
            var title: String
            var details: String
            var styleTags: String
            var vocal: String
            var bpm: Int
            var mood: String
        }
        var notes: String
        var genres: [String]
        var tracks: [Song]
    }

    private func writeAlbum(_ album: Album, artist: Artist, urgent: Bool = false) async throws -> Album {
        setActivity(artist.id, "Writing songs for \(album.title)")
        let siblings = try await db.reader.read { db in
            try Album.filter(Column("artistID") == artist.id).order(Column("releaseYear")).fetchAll(db)
        }
        let schema = Schema.object([
            "notes": Schema.string(),
            "genres": Schema.array(Schema.string(), min: 1, max: 3),
            "tracks": Schema.array(
                Schema.object([
                    "title": Schema.string(),
                    "details": Schema.string(),
                    "styleTags": Schema.string(),
                    "vocal": Schema.enumeration(["male", "female", "duet", "group"]),
                    "bpm": Schema.integer(),
                    "mood": Schema.string("One or two words"),
                ]), min: album.trackCount, max: album.trackCount),
        ])
        let prompt = """
            Artist: \(artist.name) — \(artist.primaryGenre), from \(artist.origin)
            Artist soul: \(artist.soul)
            Lead voice (fixed for every song): \(artist.voice.isEmpty ? "as described in the soul" : artist.voice)

            Discography: \(siblings.map { "\($0.releaseYear) \($0.title) (\($0.kind.label))" }.joined(separator: "; "))

            \(GenreSound.guide(for: [artist.primaryGenre] + artist.genres))

            Now write the \(album.kind.label.lowercased()) "\(album.title)" (\(album.releaseYear), \(album.label)).
            Album soul: \(album.soul)

            Fields:
            - notes: 70–130 words of editorial notes like a streaming service's editors' blurb: what it sounds like, where it sits in their story, standout tracks by title. Never mention real artists or that anything is fictional.
            - genres: the album's specific genres.
            - tracks: exactly \(album.trackCount), in sequence order. Titles must feel like real songs by this artist in this era (vary length and style; no numbering).
              - details (private): 40–80 words: arrangement, instrumentation, groove, vocal approach, emotional arc and the lyric's mood (a feeling, an image or two, never a plot or a list of objects), plus structure (e.g. slow intro, double chorus, outro fade).
              - styleTags: a tag line for a music generation model: 8–12 short comma-separated tags of one to three words each, in this order: genre/subgenre, 3–5 defining instruments in plain words, then the song's mood and a tempo word. Add a language only if the song is not in English. No production or era phrases, no sentences. Never describe the singer — the artist's fixed voice is added automatically. Must reflect this specific song, and must sound like the artist's genre: name the genre and use its defining instruments (a ballad by a rock band is still a rock ballad, with electric guitars). Leave out instruments and textures from other genres (synths on a rock song, acoustic guitar on electropop, "tactile", "felt", "intimate").
              - bpm: realistic tempo.
            """
        let p = try await textLimit.run(first: urgent) {
            try await self.client.json(
                AlbumPayload.self, schemaName: "album_tracks", schema: schema,
                instructions: "You are a producer and A&R writing the definitive notes for a record. Be specific and musical.",
                prompt: prompt, effort: "low")
        }
        guard !p.tracks.isEmpty else { throw ChatGPTError.malformed("album_tracks: no tracks") }
        var updated = album
        updated.notes = p.notes
        if !p.genres.isEmpty {
            updated.genres = p.genres
            updated.primaryGenre = p.genres[0]
        }
        updated.status = .written
        updated.trackCount = p.tracks.count
        let tracks = p.tracks.enumerated().map { i, s in
            Track(
                albumID: album.id, artistID: artist.id, trackNumber: i + 1, title: s.title, details: s.details,
                styleTags: s.styleTags, vocal: s.vocal, bpm: s.bpm, mood: s.mood)
        }
        let final = updated
        try await db.writer.write { db in
            try Track.filter(Column("albumID") == album.id).deleteAll(db)
            try final.update(db)
            try AppDatabase.index(db, album: final, artistName: artist.name)
            for t in tracks {
                try t.insert(db)
                try AppDatabase.index(db, track: t, artistName: artist.name, albumTitle: final.title)
            }
        }
        return updated
    }

    // MARK: Artwork

    func paintPortrait(_ artist: Artist) async throws {
        setActivity(artist.id, "Photographing \(artist.name)")
        let prompt = """
            Square artist photo for a fictional \(artist.primaryGenre) \(artist.members.count > 1 ? "group of \(artist.members.count)" : "solo artist") called "\(artist.name)" from \(artist.origin), circa \(artist.formedYear + 2).
            Art direction: \(artist.imagePrompt ?? PortraitDirection.assign(genres: [artist.primaryGenre] + artist.genres, isGroup: artist.members.count > 1) + "\n" + artist.tagline)
            Follow the art direction's framing, look, setting and light exactly; it must not look like a generic band press shot. Photorealistic (unless the art direction asks for a painting), natural skin texture, authentic to the era's camera technology. Fictional people only. Absolutely no text, logos or watermarks.
            """
        let fallback = """
            Square artist photo for a fictional \(artist.primaryGenre) act called "\(artist.name)" from \(artist.origin), circa \(artist.formedYear + 2).
            A wide environmental shot: the \(artist.members.count > 1 ? "musicians stand" : "musician stands") small in the frame, fully clothed in everyday street clothes, in a place that fits the music, with natural light. Photorealistic, authentic to the era's camera technology. Fictional people only. Absolutely no text, logos or watermarks.
            """
        let data = try await imageLimit.run {
            try await Self.paint(prompt, fallback: fallback) { try await self.client.image(prompt: $0) }
        }
        let path = try artwork.save(data, kind: .artist, id: artist.id)
        let accent = ArtworkStore.palette(from: data).first
        _ = try db.modifyArtist(artist.id) {
            $0.imagePath = path
            $0.accentHex = accent
        }
    }

    func paintCover(_ album: Album, artist: Artist, urgent: Bool = false) async throws {
        setActivity(artist.id, "Designing the cover of \(album.title)")
        let prompt = """
            Square album cover art for "\(album.title)" by \(artist.name), a \(album.releaseYear) \(album.primaryGenre) \(album.kind.label.lowercased()).
            Art direction: \(album.coverPrompt)
            It must look like a real, professionally designed \(album.primaryGenre) release from \(album.releaseYear), following the art direction's medium faithfully (a photo stays a photo, a painting stays a painting). Avoid aged-paper textures, archival documents and muted still lifes unless the art direction asks for them. If typography is used, spell "\(artist.name)" and "\(album.title)" exactly. No watermarks, no parental advisory labels, no real brands.
            """
        let fallback = Self.safeCoverPrompt(
            title: album.title, artist: artist.name, year: album.releaseYear, genre: album.primaryGenre,
            kind: album.kind.label.lowercased())
        let data = try await imageLimit.run(first: urgent) {
            try await Self.paint(prompt, fallback: fallback) { try await self.client.image(prompt: $0) }
        }
        let path = try artwork.save(data, kind: .album, id: album.id)
        let palette = ArtworkStore.palette(from: data)
        _ = try db.modifyAlbum(album.id) {
            $0.coverPath = path
            $0.palette = palette
        }
    }

    /// Generates art from `prompt`; if the safety system blocks it, tries once more with `fallback`,
    /// a prompt with no people in it. Without this, one blocked cover fails the whole artist.
    static func paint(
        _ prompt: String, fallback: String, generate: @Sendable (String) async throws -> Data
    ) async throws -> Data {
        do {
            return try await generate(prompt)
        } catch ChatGPTError.moderationBlocked(let categories) {
            buildLog.notice("Image blocked by moderation (\(categories.joined(separator: ","))); using the fallback prompt")
            return try await generate(fallback)
        }
    }

    /// A cover that keeps the release's identity but drops the art direction (the usual cause of a
    /// moderation block) in favor of a people-free graphic design.
    static func safeCoverPrompt(title: String, artist: String, year: Int, genre: String, kind: String) -> String {
        """
        Square album cover art for "\(title)" by "\(artist)", a \(year) \(genre) \(kind).
        A bold graphic design: typography, color and abstract shapes that capture the mood of \(genre) in \(year). No people, faces or bodies anywhere. Spell "\(artist)" and "\(title)" exactly. It must look like a real, professionally designed release. No watermarks, no parental advisory labels, no real brands.
        """
    }

    static func unfinishedMessage(_ failures: Int) -> String {
        "\(failures) \(failures == 1 ? "artist" : "artists") couldn’t be finished."
    }

    struct ReleasePayload: Decodable, Sendable {
        var title: String
        var year: Int
        var kind: String
        var label: String
        var soul: String
        var coverConcept: String
        var trackCount: Int
        var bioAddendum: String
    }

    /// Writes a brand-new release that continues an artist's story. Returns the album id.
    public func newRelease(artistID: ID, brief: String? = nil) async throws -> ID {
        guard var artist = try await db.reader.read({ try Artist.fetchOne($0, key: artistID) }) else {
            throw ChatGPTError.failed("Unknown artist")
        }
        setActivity(artistID, "\(artist.name) is back in the studio")
        defer { setActivity(artistID, nil) }
        let albums = try await db.reader.read { db in
            try Album.filter(Column("artistID") == artistID).order(Column("releaseYear")).fetchAll(db)
        }
        let schema = Schema.object([
            "title": Schema.string(),
            "year": Schema.integer(),
            "kind": Schema.enumeration(AlbumKind.allCases.map(\.rawValue)),
            "label": Schema.string(),
            "soul": Schema.string(),
            "coverConcept": Schema.string(),
            "trackCount": Schema.integer(),
            "bioAddendum": Schema.string("One or two sentences to append to the bio about this release"),
        ])
        let prompt = """
            \(artist.name) (\(artist.primaryGenre), \(artist.origin)) is releasing something new.
            Artist soul: \(artist.soul)
            Discography so far: \(albums.map { "\($0.releaseYear) \($0.title) (\($0.kind.label)): \($0.soul.prefix(220))" }.joined(separator: "\n"))
            \(brief.map { "The listener asked for: \($0)\n" } ?? "")\(GenreSound.guide(for: [artist.primaryGenre] + artist.genres))

            Plan their next release, dated \(max(2026, (albums.last?.releaseYear ?? 2025) + 1)) or later. It should feel like the natural next chapter — evolve the sound in a believable direction.
            soul (private): 90–160 words mapping concept, production and the tone/tempo/energy of the sequence. coverConcept: specific art direction distinct from earlier covers. trackCount: album 8–12, ep 4–6, single 1–3.
            """
        let p = try await textLimit.run {
            try await self.client.json(
                ReleasePayload.self, schemaName: "new_release", schema: schema,
                instructions: "You are a music historian and A&R planning an artist's next record. Be specific and consistent.",
                prompt: prompt, effort: "low")
        }
        let kind = AlbumKind(rawValue: p.kind) ?? .album
        var album = Album(
            artistID: artistID, title: p.title, releaseYear: max(p.year, albums.last?.releaseYear ?? 2026), kind: kind,
            label: p.label, primaryGenre: artist.primaryGenre, genres: artist.genres, soul: p.soul,
            coverPrompt: p.coverConcept, trackCount: Self.clampTracks(p.trackCount, kind))
        try db.save(album: album)
        if !p.bioAddendum.isEmpty {
            artist = try db.modifyArtist(artistID) { $0.bio += "\n\n" + p.bioAddendum } ?? artist
        }
        album = try await writeAlbum(album, artist: artist)
        try await paintCover(album, artist: artist)
        _ = try db.modifyAlbum(album.id) { $0.status = .ready }
        return album.id
    }

    /// Regenerates artwork for an album (user request).
    public func repaintCover(albumID: ID) async throws {
        guard let info = try db.albumInfo(albumID) else { return }
        try await paintCover(info.album, artist: info.artist)
    }
}
