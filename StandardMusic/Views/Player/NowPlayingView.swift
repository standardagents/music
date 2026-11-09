import AppKit
import StandardKit
import SwiftUI

/// Full-window Now Playing. While the current song is still in the studio it becomes a calm
/// "recording" room: breathing artwork, the stage timeline, lyrics as soon as they're written,
/// liner notes and what's next.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var showsLyrics = true

    var body: some View {
        let player = model.player
        ZStack {
            if let info = player.current {
                NowPlayingBackground(album: info.album)
                content(info)
                    .transition(.opacity)
            } else {
                Color.black.opacity(0.85)
                ContentUnavailableView("Nothing playing", systemImage: "music.note", description: Text("Play an album and it appears here."))
            }
            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 14)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .background(TrafficLightKeeper())
        .background {
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.smooth(duration: 0.8), value: player.isWaiting)
        .animation(.smooth(duration: 0.6), value: player.current?.id)
    }

    private func close() {
        withAnimation(.smooth(duration: 0.45)) { model.showsNowPlaying = false }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if model.player.current?.track.isInstrumental == false {
                Button { withAnimation(.smooth) { showsLyrics.toggle() } } label: {
                    Image(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble").frame(width: 30, height: 30)
                }
                .help(showsLyrics ? "Show liner notes" : "Show lyrics")
                .accessibilityLabel("Lyrics")
                .accessibilityValue(showsLyrics ? "Showing lyrics" : "Showing liner notes")
                .accessibilityAddTraits(showsLyrics ? .isSelected : [])
            }
            Button(action: close) {
                Image(systemName: "chevron.down").frame(width: 30, height: 30)
            }
            .help("Close (Esc)")
            .accessibilityLabel("Close Now Playing")
        }
        .buttonStyle(NowPlayingChromeButtonStyle())
        .padding(.top, 14)
        .padding(.trailing, 18)
    }

    private func content(_ info: TrackInfo) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width > 900
            let art = min(wide ? geo.size.width * 0.32 : geo.size.width * 0.5, geo.size.height * 0.5, 460)
            HStack(spacing: wide ? 64 : 0) {
                PlayerColumn(info: info, artworkSize: art)
                    .frame(width: max(art, 320))
                if wide {
                    SidePanel(info: info, showsLyrics: showsLyrics)
                        .frame(maxWidth: 560)
                        .frame(height: geo.size.height * 0.78)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 30)
        }
    }
}

private struct NowPlayingChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.14), in: Circle())
            .contentShape(Circle())
    }
}

/// Hides the window's toolbar while Now Playing is up but keeps the titlebar (and its traffic
/// lights) floating transparently over the backdrop, like Music. SwiftUI's own toolbar hiding
/// would hide the traffic lights too.
///
/// SwiftUI shows the toolbar again whenever it rebuilds it (a track change, toggling the sidebar),
/// which left the toolbar sitting on top of Now Playing and its close button. So the toolbar's
/// visibility is watched and held hidden for as long as Now Playing is up.
private struct TrafficLightKeeper: NSViewRepresentable {
    final class Probe: NSView {
        private weak var managed: NSWindow?
        private var wasTransparent = false
        private var watches: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return restore() }
            if managed !== window {
                restore()
                managed = window
                wasTransparent = window.titlebarAppearsTransparent
                watch(window)
            }
            enforce()
        }

        /// Hides the toolbar and keeps the titlebar transparent, now and whenever something undoes it.
        func enforce() {
            guard let window = managed else { return }
            if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        }

        private func watch(_ window: NSWindow) {
            watches = [
                window.observe(\.toolbar) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.watchToolbar(); self?.enforce() }
                },
                window.observe(\.titlebarAppearsTransparent) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.enforce() }
                },
            ]
            watchToolbar()
        }

        private var toolbarWatch: NSKeyValueObservation?
        private func watchToolbar() {
            toolbarWatch = managed?.toolbar?.observe(\.isVisible) { [weak self] _, _ in
                DispatchQueue.main.async { self?.enforce() }
            }
        }

        func restore() {
            watches = []
            toolbarWatch = nil
            guard let window = managed else { return }
            window.toolbar?.isVisible = true
            window.titlebarAppearsTransparent = wasTransparent
            managed = nil
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.enforce() }
    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.restore() }
}

// MARK: - Background

/// Slow mesh of the album palette over a heavily blurred cover; nudged by the output level.
struct NowPlayingBackground: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible
    let album: Album
    @State private var cover: NSImage?

    var body: some View {
        let colors = paletteColors
        ZStack {
            Color.black
            // Reduce Motion: the mesh holds still (a single frame) instead of drifting. It also holds
            // still while nothing plays and while the window can't be seen: a full-window blur redrawn
            // 30 times a second for hours is the costliest thing the app can do.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !windowIsVisible || !model.player.isPlaying)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let energy = reduceMotion ? 0 : Double(model.player.level)
                let amp = 0.06 + energy * 0.08
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [Float(0.5 + 0.2 * sin(t * 0.13)), 0], [1, 0],
                        [0, Float(0.5 + 0.2 * cos(t * 0.11))],
                        [Float(0.5 + amp * sin(t * 0.37)), Float(0.5 + amp * cos(t * 0.29))],
                        [1, Float(0.5 + 0.2 * sin(t * 0.17))],
                        [0, 1], [Float(0.5 + 0.2 * cos(t * 0.19)), 1], [1, 1],
                    ],
                    colors: colors, smoothsColors: true)
            }
            .opacity(0.9)
            Color.clear
                .overlay {
                    if let cover {
                        Image(nsImage: cover)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 90, opaque: true)
                            .opacity(0.45)
                            .blendMode(.softLight)
                            .transition(.opacity)
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            // Reduce Transparency / Increase Contrast: a solid dark scrim keeps white text legible.
            LegibilityScrim(opacity: 0.6)
        }
        .drawingGroup()
        .accessibilityHidden(true)
        .task(id: album.coverPath) {
            guard let path = album.coverPath else { cover = nil; return }
            let loaded = await ImageCache.shared.load(model.services.artwork.thumbnailURL(for: path))
            withAnimation(.easeOut(duration: 0.6)) { cover = loaded }
        }
    }

    private var paletteColors: [Color] {
        var base = album.colors
        if base.isEmpty { base = ArtworkView.seeded(album.id) }
        // 9 mesh points: cycle the palette, darkening the edges so text stays readable.
        return (0 ..< 9).map { i in
            let c = base[(i * 2 + i / 3) % base.count]
            return i == 4 ? c : c.mix(with: .black, by: 0.35)
        }
    }
}

// MARK: - Player column

private struct PlayerColumn: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    let artworkSize: CGFloat

    var body: some View {
        let player = model.player
        VStack(spacing: 22) {
            BreathingArtwork(album: info.album, artistName: info.artist.name, size: artworkSize, breathing: player.isWaiting)
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.track.title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                        .explicitBadge(info.track.isExplicit, size: 15)
                    Spacer(minLength: 8)
                    FavoriteButton(isFavorite: info.track.isFavorite) { model.toggleFavorite(track: info.id) }
                        .font(.system(size: 17))
                }
                HStack(spacing: 0) {
                    Button(info.artist.name) { go(.artist(info.artist.id)) }
                        .accessibilityHint("Goes to the artist")
                    Text(" — ").accessibilityHidden(true)
                    Button(info.album.title) { go(.album(info.album.id)) }
                        .accessibilityHint("Goes to the album")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            }
            .frame(width: artworkSize)
            Group {
                if player.isWaiting {
                    StudioProgressBar(trackID: info.id)
                } else {
                    PlaybackScrubber(showsTimes: true, height: 5)
                }
            }
            .frame(width: artworkSize)
            HStack(spacing: 34) {
                Button { player.shuffle.toggle() } label: {
                    Image(systemName: "shuffle").opacity(player.shuffle ? 1 : 0.5)
                }
                .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffle ? "On" : "Off")
                .accessibilityAddTraits(player.shuffle ? .isSelected : [])
                TransportControls(size: 26, spacing: 34)
                Button { player.repeatMode = player.repeatMode.next } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .opacity(player.repeatMode == .off ? 0.5 : 1)
                }
                .help(player.repeatMode.help)
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.spokenValue)
                .accessibilityAddTraits(player.repeatMode == .off ? [] : .isSelected)
            }
            .font(.system(size: 17, weight: .semibold))
            .buttonStyle(.plain)
            VolumeControl()
                .frame(width: min(artworkSize, 280))
        }
        .foregroundStyle(.white)
    }

    private func go(_ route: Route) {
        withAnimation(.smooth(duration: 0.45)) { model.showsNowPlaying = false }
        model.show(route)
    }
}

/// Large artwork with a soft colored shadow; breathes slowly while the song is being recorded.
private struct BreathingArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible
    let album: Album
    var artistName: String? = nil
    let size: CGFloat
    let breathing: Bool

    var body: some View {
        // Reduce Motion: keep the smaller, desaturated "in the studio" pose without the pulse.
        let animate = breathing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate || !windowIsVisible)) { context in
            let phase = animate ? sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 6) : 0
            ArtworkView(source: .album(album), size: size, cornerRadius: 12, highResolution: true, shadow: false,
                        accessibilityDescription: Spoken.albumCover(album.title, by: artistName))
                .scaleEffect(breathing ? 0.94 + 0.02 * phase : 1)
                .shadow(color: (album.colors.first ?? .black).opacity(0.55), radius: 40 + 10 * phase, y: 24)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                .saturation(breathing ? 0.85 : 1)
        }
        .animation(.smooth(duration: 1.2), value: breathing)
    }
}

/// Progress for a song in the studio: stage, percentage, time left.
private struct StudioProgressBar: View {
    @Environment(AppModel.self) private var model
    let trackID: ID

    var body: some View {
        let active = model.recording.active
        let mine = active?.trackID == trackID
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * (mine ? active?.fraction ?? 0 : 0))
                        .animation(.smooth, value: active?.fraction)
                }
            }
            .frame(height: 5)
            HStack {
                Text(mine ? active?.stageLabel ?? "Recording" : studioBusyLine)
                Spacer()
                if mine, let active {
                    Text([active.fraction > 0.01 ? "\(Int(active.fraction * 100))%" : nil, Format.remaining(active.remaining)].compactMap { $0 }.joined(separator: " · "))
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording progress")
        .accessibilityValue(mine && active != nil
            ? Spoken.recording(fraction: active!.fraction, stage: active!.stageLabel, remaining: active!.remaining)
            : studioBusyLine)
    }

    private var studioBusyLine: String {
        if let active = model.recording.active { return "Up next in the studio, after “\(active.title)”" }
        return "Waiting for the studio"
    }
}

// MARK: - Side panel

private struct SidePanel: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo
    let showsLyrics: Bool

    var body: some View {
        Group {
            if model.player.isWaiting {
                WaitingPanel(info: info)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if showsLyrics, let lyrics = info.track.lyrics, !lyrics.isEmpty, !info.track.isInstrumental {
                TimedLyrics(lyrics: lyrics, trackID: info.id)
                    .transition(.opacity)
            } else {
                ScrollView {
                    LinerNotes(info: info).padding(.vertical, 40)
                }
                .scrollIndicators(.never)
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Lyrics without timing data: sections are highlighted in proportion to playback time,
/// weighted by their line counts.
private struct TimedLyrics: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: String
    let trackID: ID

    struct Section: Identifiable {
        var id: Int
        var title: String?
        var lines: [String]
    }

    var body: some View {
        let sections = Self.sections(lyrics)
        let player = model.player
        let fraction = player.duration > 0 ? player.time / player.duration : 0
        let current = Self.current(sections, fraction: fraction)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1)
                                    .opacity(0.5)
                            }
                            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 26, weight: .bold))
                            }
                        }
                        .opacity(section.id == current ? 1 : 0.38)
                        .blur(radius: section.id == current ? 0 : 0.4)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(section.id == current ? "Now singing" : "")
                        .id(section.id)
                    }
                }
                .padding(.vertical, 120)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .animation(.smooth(duration: 0.9), value: current)
            .onChange(of: current) { _, section in
                withAnimation(reduceMotion ? nil : .smooth(duration: 1.2)) { proxy.scrollTo(section, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
            .onAppear { proxy.scrollTo(current, anchor: UnitPoint(x: 0, y: 0.3)) }
        }
    }

    static func sections(_ lyrics: String) -> [Section] {
        var result: [Section] = []
        for line in LyricsView.parse(lyrics) {
            switch line {
            case .section(let name):
                result.append(Section(id: result.count, title: name, lines: []))
            case .text(let text):
                if result.isEmpty { result.append(Section(id: 0, title: nil, lines: [])) }
                result[result.count - 1].lines.append(text)
            case .gap:
                break
            }
        }
        return result.filter { !$0.lines.isEmpty }.enumerated().map { Section(id: $0.offset, title: $0.element.title, lines: $0.element.lines) }
    }

    /// Songs open and close with a little instrumental, so vocals span roughly 8%…92% of the track.
    static func current(_ sections: [Section], fraction: Double) -> Int {
        let total = Double(sections.reduce(0) { $0 + $1.lines.count + 1 })
        guard total > 0 else { return 0 }
        let position = min(max((fraction - 0.08) / 0.84, 0), 0.999) * total
        var running = 0.0
        for section in sections {
            running += Double(section.lines.count + 1)
            if position < running { return section.id }
        }
        return sections.last?.id ?? 0
    }
}

/// Everything shown while the song is being recorded.
private struct WaitingPanel: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                StudioCard(info: info)
                if let lyrics = info.track.lyrics, !lyrics.isEmpty, !info.track.isInstrumental {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeading(title: "Lyrics", subtitle: "Fresh from the songwriter")
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(LyricsView.parse(lyrics).enumerated()), id: \.offset) { _, line in
                                switch line {
                                case .section(let name):
                                    Text(name.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).opacity(0.5)
                                        .padding(.top, 12)
                                case .text(let text):
                                    Text(text).font(.system(size: 17, weight: .semibold)).opacity(0.9)
                                case .gap:
                                    EmptyView()
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !info.track.details.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelHeading(title: "About this song", subtitle: songTraits)
                        Text(info.track.details)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .opacity(0.85)
                    }
                }
                LinerNotes(info: info, title: "Liner notes while you wait")
                UpNextTeaser()
            }
            .padding(.vertical, 40)
            .animation(.smooth, value: info.track.lyrics != nil)
        }
        .scrollIndicators(.never)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }

    private var songTraits: String? {
        let t = info.track
        let parts = [t.mood.isEmpty ? nil : t.mood.capitalized, t.isInstrumental ? "Instrumental" : (t.vocal.isEmpty ? nil : t.vocal.capitalized), t.bpm.map { "\($0) BPM" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Ring, stage and the five-step timeline.
private struct StudioCard: View {
    @Environment(AppModel.self) private var model
    let info: TrackInfo

    static let steps = ["Writing lyrics", "Writing the score", "Laying down the tracks", "Mixing", "Mastering"]

    var body: some View {
        let active = model.recording.active
        let mine = active?.trackID == info.id
        let (step, stepFraction) = mine ? Self.step(active!) : (-1, 0.0)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                ZStack {
                    RecordingRing(fraction: mine ? active?.fraction ?? 0 : 0, lineWidth: 5, tint: .white)
                    Text(mine && (active?.fraction ?? 0) > 0.01 ? "\(Int((active?.fraction ?? 0) * 100))%" : "")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                .frame(width: 70, height: 70)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("IN THE STUDIO").font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.6)
                    Text(mine ? active?.stageLabel ?? "Recording" : model.recording.isStopped ? "Recording stopped" : "Waiting its turn")
                        .font(.system(size: 24, weight: .bold))
                        .contentTransition(.opacity)
                    Text(subtitle(active: active, mine: mine))
                        .font(.system(size: 13)).opacity(0.7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("In the studio")
            .accessibilityValue(mine && active != nil
                ? Spoken.recording(fraction: active!.fraction, stage: active!.stageLabel, remaining: active!.remaining)
                : subtitle(active: active, mine: mine))
            .accessibilityAddTraits(.updatesFrequently)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if model.recording.hasWork {
                Button { model.stopRecording() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .background(Circle().fill(.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .help("Stop recording (⌘.)")
                .accessibilityLabel("Stop recording")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(.white.opacity(i < step ? 0.9 : 0.12)).frame(width: 18, height: 18)
                            if i < step {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                            } else if i == step {
                                RecordingRing(fraction: stepFraction, lineWidth: 2, tint: .white).frame(width: 18, height: 18)
                            }
                        }
                        Text(name)
                            .font(.system(size: 14, weight: i == step ? .semibold : .regular))
                            .opacity(i == step ? 1 : i < step ? 0.75 : 0.4)
                        Spacer()
                    }
                    .frame(minHeight: 30)
                    .overlay(alignment: .topLeading) {
                        if i > 0 {
                            Rectangle().fill(.white.opacity(i <= step ? 0.6 : 0.12)).frame(width: 1.5, height: 12).offset(x: 8.25, y: -6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(i + 1) of \(Self.steps.count), \(name)")
                    .accessibilityValue(i < step ? "Done" : i == step ? "In progress, \(Spoken.percent(stepFraction))" : "Not started")
                }
            }
            .animation(.smooth, value: step)
        }
        .padding(22)
        // Not .glassEffect: this card lives inside the panel's faded scroll mask, where Liquid Glass
        // can't sample the backdrop and smears dark patches across the corners. The backdrop is
        // already a blurred artwork wash, so a translucent panel reads the same.
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            shape.fill(.black.opacity(0.18))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
        .background(LegibilityScrim(shape: RoundedRectangle(cornerRadius: 20), opacity: 0.6))
        .accessibilityElement(children: .contain)
    }

    private func subtitle(active: RecordingQueue.Activity?, mine: Bool) -> String {
        guard mine, let active else {
            if model.recording.isStopped { return "Press play to start recording it again." }
            if let active { return "Finishing “\(active.title)” first. This song starts as soon as it’s recorded." }
            return "This song starts as soon as it’s recorded."
        }
        let elapsed = Date().timeIntervalSince(active.startedAt)
        let left = Format.remaining(active.remaining) ?? "Estimating time left…"
        return "\(left) · started \(Format.duration(elapsed)) ago"
    }

    /// Maps the engine phase onto the five visible steps (plus progress within the step).
    static func step(_ activity: RecordingQueue.Activity) -> (Int, Double) {
        switch activity.phase {
        case .writingLyrics: return (0, 0)
        case .waitingForModel: return (1, 0)
        case .recording(let p):
            switch p.stage {
            case "loading": return (1, 0)
            case "planning": return (1, p.stageFraction)
            case "composing": return (2, p.stageFraction)
            case "rendering": return (3, p.stageFraction)
            default: return (4, p.stageFraction)
            }
        }
    }
}

private struct PanelHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.6)
                .accessibilityLabel(title)
                .accessibilityHeading()
            if let subtitle { Text(subtitle).font(.system(size: 12)).opacity(0.5) }
        }
    }
}

/// Album notes and an artist bio excerpt.
private struct LinerNotes: View {
    let info: TrackInfo
    var title = "Liner notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeading(title: title, subtitle: "\(info.album.title) · \(info.album.releaseYear)")
            if !info.album.notes.isEmpty {
                Text(info.album.notes).font(.system(size: 15)).lineSpacing(4).opacity(0.88)
            }
            if !info.artist.bio.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.artist.name.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).opacity(0.5)
                    Text(Self.excerpt(info.artist.bio)).font(.system(size: 14)).lineSpacing(3).opacity(0.75)
                }
            }
        }
        .textSelection(.enabled)
    }

    static func excerpt(_ bio: String) -> String {
        let paragraphs = bio.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return paragraphs.prefix(2).joined(separator: "\n\n")
    }
}

/// The next song in the queue and its studio state.
private struct UpNextTeaser: View {
    @Environment(AppModel.self) private var model
    @State private var next: TrackInfo?

    var body: some View {
        let entry = model.player.upNext.first
        Group {
            if let next {
                VStack(alignment: .leading, spacing: 10) {
                    PanelHeading(title: "Next in line")
                    HStack(spacing: 12) {
                        ArtworkView(source: .album(next.album), size: 44, cornerRadius: 5, shadow: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.track.title).font(.system(size: 14, weight: .semibold))
                            Text(nextLine(next)).font(.system(size: 12)).opacity(0.6)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .task(id: entry?.trackID) {
            next = entry.flatMap { try? model.services.db.trackInfo($0.trackID) }
        }
    }

    private func nextLine(_ info: TrackInfo) -> String {
        if info.track.isPlayable { return "\(info.artist.name) · Recorded, ready to play" }
        if let p = model.recording.position(of: info.id) { return "\(info.artist.name) · \(p <= 1 ? "Records next" : "In the studio queue")" }
        return "\(info.artist.name) · Records when it’s up"
    }
}
