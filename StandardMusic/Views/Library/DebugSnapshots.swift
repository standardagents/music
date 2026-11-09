#if DEBUG
import AppKit
import StandardKit
import SwiftUI

/// Development aid: with `SM_SNAPSHOT_DIR` set, reads commands from `<dir>/commands` (one per line)
/// and renders the main window to `<dir>/<name>.png` — works without screen-recording permission.
///   nav <home|browse|create|recentlyAdded|artists|albums|songs|favorites|search>
///   album|artist|genre|shelf <value> · playalbum <albumID> · search <text> · queue · lyrics · close
///   size <w> <h> · dark · light · wait <seconds> · shot <name> · action <selector:>
@MainActor
enum DebugSnapshots {
    static func run(model: AppModel, library: LibraryState) async {
        guard let dir = ProcessInfo.processInfo.environment["SM_SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let file = root.appending(path: "commands")
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: file)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let arg = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "nav":
                    let items: [String: SidebarItem] = [
                        "home": .home, "browse": .browse, "create": .create, "recentlyAdded": .recentlyAdded,
                        "artists": .artists, "albums": .albums, "songs": .songs, "favorites": .favorites, "search": .search,
                    ]
                    model.selection = items[arg] ?? .home
                case "album": model.show(.album(arg))
                case "artist": model.show(.artist(arg))
                case "genre": model.show(.genre(arg))
                case "shelf": model.show(.shelf(arg))
                case "playalbum": model.player.play(albumID: arg)
                case "search": model.searchText = arg
                case "queue": model.showsLyrics = false; model.showsQueue = true
                case "lyrics": model.showsQueue = false; model.showsLyrics = true
                case "next": model.player.next()
                case "songsfilter": UserDefaults.standard.set(arg, forKey: "songsFilter")
                case "favorite":
                    if let id = model.player.currentEntry?.trackID { model.toggleFavorite(track: id) }
                case "taste":
                    try? model.taste.promptContext.write(to: root.appending(path: "\(arg).txt"), atomically: true, encoding: .utf8)
                case "np": model.showsNowPlaying = true
                case "npclose": model.showsNowPlaying = false
                case "close": model.showsQueue = false; model.showsLyrics = false
                case "toast": model.toast = arg
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "size":
                    let n = arg.split(separator: " ").compactMap { Double($0) }
                    if n.count == 2, let w = mainWindow { w.setContentSize(NSSize(width: n[0], height: n[1])) }
                case "dump":
                    var out = "close=\(mainWindow?.standardWindowButton(.closeButton).map { "hidden:\($0.isHidden) frame:\($0.frame) superHidden:\($0.superview?.isHidden ?? true) alpha:\($0.superview?.superview?.alphaValue ?? -1)" } ?? "none") titlebar=\(mainWindow?.titlebarAppearsTransparent ?? false) toolbar=\(mainWindow?.toolbar?.isVisible ?? false)\n" + "occlusion=\(mainWindow?.occlusionState.contains(.visible) ?? false) screens=\(NSScreen.screens.count) phase=\(model.phase) selection=\(String(describing: model.selection))\n"
                    func walk(_ v: NSView, _ depth: Int) {
                        guard depth < 60 else { return }
                        out += String(repeating: " ", count: depth) + "\(type(of: v)) \(v.frame.integral) layer=\(v.layer.map { "\(type(of: $0))" } ?? "-")\n"
                        v.subviews.forEach { walk($0, depth + 1) }
                    }
                    if let v = mainWindow?.contentView?.superview { walk(v, 0) }
                    try? out.write(to: root.appending(path: "\(arg).txt"), atomically: true, encoding: .utf8)
                case "ax":
                    var out = ""
                    func walk(_ e: Any, _ depth: Int) {
                        guard depth < 40, let el = e as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
                        let o = el as AnyObject
                        let role = (o.accessibilityRole?() ?? nil)?.rawValue ?? "?"
                        let label = [o.accessibilityLabel?(), o.accessibilityTitle?(), (o.accessibilityValue?() ?? nil).map { "\($0)" }]
                            .compactMap { $0 ?? nil }.filter { !$0.isEmpty }.joined(separator: " | ")
                        let frame = el.accessibilityFrame()
                        if !label.isEmpty || role != "AXGroup" {
                            out += String(repeating: " ", count: depth) + "\(role) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))] \(label)\n"
                        }
                        for child in (o.accessibilityChildren?() ?? nil) ?? [] { walk(child, depth + 1) }
                    }
                    if let w = mainWindow { walk(w, 0) }
                    try? out.write(to: root.appending(path: "\(arg).txt"), atomically: true, encoding: .utf8)
                case "queries":
                    var out = ""
                    do { out += "artists: \(try await model.services.db.reader.read { try LibraryQuery.visibleArtists($0) }.count)\n" } catch { out += "artists error: \(error)\n" }
                    let ids = Array(Set(model.player.queue.map(\.trackID)))
                    do { out += "queue: \(try await model.services.db.reader.read { try AppDatabase.trackInfos().filter(keys: ids).fetchAll($0) }.count) of \(ids.count)\n" } catch { out += "queue error: \(error)\n" }
                    try? out.write(to: root.appending(path: "\(arg).txt"), atomically: true, encoding: .utf8)
                case "chain":
                    var out = ""
                    var v: NSView? = mainWindow?.standardWindowButton(.closeButton)
                    while let view = v {
                        out += "\(type(of: view)) hidden=\(view.isHidden) alpha=\(view.alphaValue) frame=\(view.frame) layerHidden=\(view.layer?.isHidden ?? false) layerOpacity=\(view.layer?.opacity ?? -1)\n"
                        v = view.superview
                    }
                    try? out.write(to: root.appending(path: "\(arg).txt"), atomically: true, encoding: .utf8)
                case "scrollperf":
                    // Scrolls the tallest scroll view in steps, timing a synchronous display of each.
                    guard let window = mainWindow, let root = window.contentView else { break }
                    func scrollViews(_ v: NSView) -> [NSScrollView] {
                        (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews)
                    }
                    guard let scroll = scrollViews(root).filter({ ($0.documentView?.frame.height ?? 0) > $0.frame.height * 1.5 })
                        .max(by: { $0.frame.width < $1.frame.width }) else { break }
                    var times: [Double] = []
                    let clip = scroll.contentView
                    let origin = clip.bounds.origin
                    for i in 1 ... 60 {
                        let start = CACurrentMediaTime()
                        clip.scroll(to: NSPoint(x: origin.x, y: origin.y + Double(i) * 120))
                        scroll.reflectScrolledClipView(clip)
                        window.displayIfNeeded()
                        CATransaction.flush()
                        times.append((CACurrentMediaTime() - start) * 1000)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    let sorted = times.sorted()
                    let line = String(format: "%@: steps=%d avg=%.1fms p95=%.1fms max=%.1fms doc=%.0f\n", arg, times.count,
                        times.reduce(0, +) / Double(times.count), sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0,
                        scroll.documentView?.frame.height ?? 0)
                    let url = self.root(root: root).appending(path: "perf.txt")
                    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try? (old + line).write(to: url, atomically: true, encoding: .utf8)
                case "navtime":
                    // Time from selection change until the main thread is free again.
                    let start = CACurrentMediaTime()
                    let items: [String: SidebarItem] = ["home": .home, "albums": .albums, "songs": .songs, "artists": .artists, "browse": .browse]
                    model.selection = items[arg] ?? .home
                    await Task.yield()
                    mainWindow?.displayIfNeeded()
                    let ms = (CACurrentMediaTime() - start) * 1000
                    let url = self.root(root: nil).appending(path: "perf.txt")
                    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try? (old + String(format: "nav %@: %.1fms\n", arg, ms)).write(to: url, atomically: true, encoding: .utf8)
                case "share":
                    if let info = try? model.services.db.albumInfo(arg) { model.share(album: info) }
                case "shareartist":
                    if let artist = try? await model.services.db.reader.read({ try Artist.fetchOne($0, key: arg) }) { model.share(artist: artist) }
                case "import": model.openShareFile(URL(fileURLWithPath: arg))
                case "confirmimport": if let p = model.pendingImport { model.confirmImport(p) }
                case "dismiss": model.shareRequest = nil; model.cancelImport()
                case "pref":
                    // pref <key> <value>: string value; "-" removes the key.
                    let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
                    if kv.count == 2 { kv[1] == "-" ? UserDefaults.standard.removeObject(forKey: kv[0]) : UserDefaults.standard.set(kv[1], forKey: kv[0]) }
                    model.refreshModelState()
                case "settings":
                    UserDefaults.standard.set(arg, forKey: "settingsTab")
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                case "shotsheet":
                    try? await Task.sleep(for: .seconds(1.2))
                    if let sheet = mainWindow?.attachedSheet { capture(sheet, to: root.appending(path: "\(arg).png")) }
                case "shotsettings":
                    try? await Task.sleep(for: .seconds(1.2))
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }) {
                        capture(w, to: root.appending(path: "\(arg).png"))
                    }
                case "scrollsettings":
                    // scrollsettings <points>: scrolls the Settings window's form.
                    if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }),
                        let content = w.contentView
                    {
                        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
                        if let scroll = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: Double(arg) ?? 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                case "action": NSApp.sendAction(Selector(arg), to: nil, from: nil)  // e.g. action toggleSidebar:
                case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                case "shot":
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(to: root.appending(path: "\(arg).png"))
                default: break
                }
            }
        }
    }

    static func root(root _: NSView?) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SM_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.frame.height > 400 } }

    static func capture(to url: URL) {
        if let window = mainWindow { capture(window, to: url) }
    }

    static func capture(_ window: NSWindow, to url: URL) {
        // With the screen locked the window server hands back blank images; drawing the view
        // hierarchy ourselves works regardless (glass materials render flat).
        if ProcessInfo.processInfo.environment["SM_SNAPSHOT_DRAW"] != nil, let view = window.contentView?.superview {
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            return
        }
        // CGWindowListCreateImage is unavailable in the SDK but still present; own windows need no permission.
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage"),
            let image = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
