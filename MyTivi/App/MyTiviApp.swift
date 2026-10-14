import SwiftUI

@main
struct MyTiviApp: App {
    @StateObject private var store = Store()
    @StateObject private var engine = PlayerEngine()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, engine: engine)
                .preferredColorScheme(.dark)
        }
    }
}

/// Danh sách đang xem + vị trí kênh, để bấm ▲▼ đổi kênh trong đúng nhóm đang chọn.
struct PlaySession: Identifiable {
    let id = UUID()
    let list: [Channel]
    let index: Int
}

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: PlayerEngine

    @State private var session: PlaySession?
    @State private var showSetup: Bool
    @State private var autoStarted = false
    @Environment(\.scenePhase) private var scenePhase

    init(store: Store, engine: PlayerEngine) {
        self._store = ObservedObject(wrappedValue: store)
        self._engine = ObservedObject(wrappedValue: engine)
        self._showSetup = State(initialValue: store.playlistUrl.isEmpty)
    }

    private var browseActive: Bool { session == nil && !showSetup }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            // Màn hình chính luôn được giữ lại (nhớ nhóm đang chọn, ô tìm kiếm...)
            BrowseScreen(
                store: store,
                engine: engine,
                isActive: browseActive,
                onPlay: { list, i in startSession(list, i) },
                onSettings: openSetup
            )
            .opacity(browseActive ? 1 : 0)
            .disabled(!browseActive)

            if let s = session {
                PlayerScreen(list: s.list, startIndex: s.index, store: store, engine: engine, onClose: endSession)
                    .id(s.id)
                    .transition(.opacity)
            }

            if showSetup {
                SetupScreen(
                    initialUrl: store.playlistUrl,
                    initialEpg: store.epgUrl,
                    canCancel: !store.playlistUrl.isEmpty,
                    onSave: { url, epg in
                        if url != store.playlistUrl || epg != store.epgUrl {
                            store.savePlaylist(url: url, epgUrl: epg)
                        }
                        showSetup = false
                    },
                    onCancel: { showSetup = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session?.id)
        .animation(.easeInOut(duration: 0.25), value: showSetup)
        .onAppear(perform: autoStart)
        .onChange(of: store.revision) { autoStart() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                engine.resume()
                store.refreshIfStale()
            case .background:
                engine.suspend()    // bấm Home / tắt TV thì tự dừng tiếng
            default:
                break
            }
        }
    }

    /// Mở app là vào thẳng kênh xem gần nhất (như TiviMate)
    private func autoStart() {
        guard !autoStarted, !store.channels.isEmpty else { return }
        autoStarted = true
        guard !showSetup, session == nil,
              let i = store.channels.firstIndex(where: { $0.url == store.lastChannelUrl }) else { return }
        startSession(store.channels, i)
    }

    private func startSession(_ list: [Channel], _ i: Int) {
        guard !list.isEmpty else { return }
        engine.setPreviewMode(false)
        session = PlaySession(list: list, index: i)
    }

    private func endSession() {
        session = nil
        engine.setPreviewMode(true)
    }

    private func openSetup() {
        engine.stop()
        showSetup = true
    }
}
