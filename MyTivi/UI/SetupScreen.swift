import SwiftUI

/// Cài đặt (điều khiển bằng Siri Remote):
///  - NHIỀU danh sách kênh (M3U / luồng .m3u8) và NHIỀU link lịch phát sóng (EPG, XMLTV).
///  - Mỗi nguồn 1 hàng: chọn tên để sửa · Đang bật/Đang tắt · ▲ Lên · Xóa.
///  - Mọi thay đổi chỉ áp dụng khi bấm "Lưu" (Back / "Hủy" là bỏ).
struct SetupScreen: View {
    let initialPlaylists: [Source]
    let initialEpgs: [Source]
    let initialUseAutoEpg: Bool
    let canCancel: Bool
    let onSave: (_ playlists: [Source], _ epgs: [Source], _ useAutoEpg: Bool) -> Void
    let onCancel: () -> Void

    enum Kind { case playlist, epg }

    /// Hộp thoại đang mở: thêm (source = nil) hoặc sửa / xóa một nguồn.
    struct Editing: Identifiable {
        let id = UUID()
        let kind: Kind
        let source: Source?
    }

    enum Focus: Hashable { case row(String), add(Kind), save }

    @State private var playlists: [Source] = []
    @State private var epgs: [Source] = []
    @State private var useAutoEpg = true
    @State private var err: String?
    @State private var editing: Editing?
    @State private var deleting: Editing?
    @State private var loaded = false
    @FocusState private var focus: Focus?

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cài đặt MyTivi")
                            .font(.system(size: 56, weight: .bold))
                        Text("Phiên bản \(Fmt.appVersion)")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.dim)
                    }

                    section(.playlist)
                    section(.epg)

                    Button { useAutoEpg.toggle() } label: {
                        HStack {
                            Text("Tự dùng EPG ghi sẵn trong playlist (url-tvg)")
                            Spacer(minLength: 20)
                            Text(useAutoEpg ? "BẬT" : "TẮT")
                                .fontWeight(.bold)
                                .foregroundStyle(useAutoEpg ? Theme.accent : Theme.dim)
                        }
                        .font(.system(size: 28))
                    }
                    .buttonStyle(TvRowButtonStyle())

                    if let err {
                        Text(err)
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.error)
                    }

                    HStack(spacing: 30) {
                        Button("Lưu", action: save)
                            .buttonStyle(TvPillButtonStyle())
                            .focused($focus, equals: .save)
                        if canCancel {
                            Button("Hủy", action: onCancel)
                                .buttonStyle(TvPillButtonStyle())
                        }
                    }

                    Text("Mẹo: có thể dán link từ iPhone bằng bàn phím trên điện thoại (thông báo \"Bàn phím Apple TV\").")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.dim)
                }
                .frame(width: 1500, alignment: .leading)
                .padding(.vertical, 60)
                .frame(maxWidth: .infinity)
            }
            .disabled(editing != nil)
            .onExitCommand(perform: canCancel ? onCancel : nil)

            if let e = editing {
                SourceEditor(
                    editing: e,
                    onSave: { name, url in commit(e, name: name, url: url) },
                    onCancel: { closeEditor() }
                )
                .id(e.id)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editing?.id)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            guard !loaded else { return }
            loaded = true
            playlists = initialPlaylists
            epgs = initialEpgs
            useAutoEpg = initialUseAutoEpg
            if initialPlaylists.isEmpty {
                // Lần đầu dùng: mở luôn hộp thoại thêm danh sách kênh
                editing = Editing(kind: .playlist, source: nil)
            } else {
                DispatchQueue.main.async { focus = .row(initialPlaylists[0].id) }
            }
        }
        .alert(
            "Xóa “\(deleting?.source?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { d in
            Button("Xóa", role: .destructive) { remove(d) }
            Button("Hủy", role: .cancel) { deleting = nil }
        } message: { d in
            Text(d.kind == .playlist
                 ? "Kênh của danh sách này sẽ không còn trong app sau khi bấm Lưu."
                 : "Lịch phát sóng từ link này sẽ không còn dùng sau khi bấm Lưu.")
        }
    }

    // MARK: - Một mục: danh sách kênh hoặc EPG

    @ViewBuilder
    private func section(_ kind: Kind) -> some View {
        let items = kind == .playlist ? playlists : epgs
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .playlist ? "Danh sách kênh (M3U)" : "Lịch phát sóng (EPG)")
                .font(.system(size: 36, weight: .bold))
            Text(kind == .playlist
                 ? "Thêm được nhiều danh sách. Kênh của các danh sách đang bật được gộp lại; ngăn nhóm kênh chia mục theo từng danh sách."
                 : "Không bắt buộc. Thêm được nhiều link XMLTV (.xml, .xml.gz); link ở trên được ưu tiên khi nhiều EPG có cùng kênh.")
                .font(.system(size: 22))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if items.isEmpty {
                Text(kind == .playlist ? "Chưa có danh sách kênh nào." : "Chưa thêm link EPG nào.")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.dim)
                    .padding(.vertical, 6)
            }

            ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 18) {
                    Button { editing = Editing(kind: kind, source: s) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.name)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(s.enabled ? Color.white : Theme.dim)
                                .lineLimit(1)
                            Text(s.url)
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .buttonStyle(TvRowButtonStyle())
                    .focused($focus, equals: .row(s.id))

                    Button(s.enabled ? "✓ Đang bật" : "Đang tắt") { toggle(kind, s) }
                        .buttonStyle(TvPillButtonStyle(compact: true))
                    if i > 0 {
                        Button("▲ Lên") { moveUp(kind, s) }
                            .buttonStyle(TvPillButtonStyle(compact: true))
                    }
                    Button("Xóa") { deleting = Editing(kind: kind, source: s) }
                        .buttonStyle(TvPillButtonStyle(compact: true))
                }
            }

            Button(kind == .playlist ? "+ Thêm danh sách kênh" : "+ Thêm link EPG") {
                editing = Editing(kind: kind, source: nil)
            }
            .buttonStyle(TvPillButtonStyle(compact: true))
            .focused($focus, equals: .add(kind))
        }
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: 0x0F1A2E)))
        .focusSection()
    }

    // MARK: - Sửa danh sách (chỉ trong màn hình này, bấm Lưu mới áp dụng)

    private func update(_ kind: Kind, _ change: (inout [Source]) -> Void) {
        if kind == .playlist { change(&playlists) } else { change(&epgs) }
    }

    private func toggle(_ kind: Kind, _ s: Source) {
        update(kind) { list in
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i].enabled.toggle() }
        }
    }

    private func moveUp(_ kind: Kind, _ s: Source) {
        update(kind) { list in
            if let i = list.firstIndex(where: { $0.id == s.id }), i > 0 { list.swapAt(i, i - 1) }
        }
    }

    private func remove(_ d: Editing) {
        guard let s = d.source else { return }
        update(d.kind) { list in list.removeAll { $0.id == s.id } }
        deleting = nil
        DispatchQueue.main.async { focus = .add(d.kind) }
    }

    private func commit(_ e: Editing, name: String, url: String) {
        update(e.kind) { list in
            if let s = e.source, let i = list.firstIndex(where: { $0.id == s.id }) {
                list[i].url = url
                if !name.isEmpty { list[i].name = name }
            } else {
                let fallback = e.kind == .playlist ? "Danh sách \(list.count + 1)" : "EPG \(list.count + 1)"
                list.append(Source(id: Store.newSourceId(), name: name.isEmpty ? fallback : name, url: url))
            }
        }
        err = nil
        closeEditor()
    }

    private func closeEditor() {
        editing = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = .save }
    }

    private func save() {
        if playlists.isEmpty {
            err = "Thêm ít nhất 1 danh sách kênh (.m3u)."
        } else if !playlists.contains(where: { $0.enabled }) {
            err = "Bật ít nhất 1 danh sách kênh."
        } else {
            err = nil
            onSave(playlists, epgs, useAutoEpg)
        }
    }
}

/// Hộp thoại thêm / sửa một nguồn: link + tên hiển thị.
private struct SourceEditor: View {
    let editing: SetupScreen.Editing
    let onSave: (_ name: String, _ url: String) -> Void
    let onCancel: () -> Void

    enum Field: Hashable { case url, name, save, cancel }

    @State private var url = ""
    @State private var name = ""
    @State private var err: String?
    @FocusState private var field: Field?

    private var isPlaylist: Bool { editing.kind == .playlist }
    private var isNew: Bool { editing.source == nil }

    private var title: String {
        switch (isNew, isPlaylist) {
        case (true, true): return "Thêm danh sách kênh"
        case (true, false): return "Thêm link EPG"
        case (false, true): return "Sửa danh sách kênh"
        case (false, false): return "Sửa link EPG"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.system(size: 46, weight: .bold))
                Text(isPlaylist
                     ? "Link file .m3u (danh sách kênh) hoặc một luồng .m3u8."
                     : "Link lịch phát sóng XMLTV (.xml hoặc .xml.gz).")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.dim)

                VStack(alignment: .leading, spacing: 10) {
                    Text(isPlaylist ? "Link danh sách kênh" : "Link EPG")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.dim)
                    TextField("http://…", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($field, equals: .url)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Tên hiển thị (không bắt buộc)")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.dim)
                    TextField(isPlaylist ? "Ví dụ: Danh sách gia đình" : "Ví dụ: Lịch phát sóng", text: $name)
                        .autocorrectionDisabled()
                        .focused($field, equals: .name)
                }

                if let err {
                    Text(err)
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.error)
                }

                HStack(spacing: 30) {
                    Button(isNew ? "Thêm" : "Lưu", action: submit)
                        .buttonStyle(TvPillButtonStyle())
                        .focused($field, equals: .save)
                    Button("Hủy", action: onCancel)
                        .buttonStyle(TvPillButtonStyle())
                        .focused($field, equals: .cancel)
                }
                .padding(.top, 6)
            }
            .padding(50)
            .frame(width: 1300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(hex: 0x0F1A2E)))
            .focusSection()
        }
        .onAppear {
            url = editing.source?.url ?? ""
            name = editing.source?.name ?? ""
            DispatchQueue.main.async { field = .url }
        }
        .onExitCommand(perform: onCancel)    // Back: đóng hộp thoại, không thoát Cài đặt
    }

    private func submit() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = u.lowercased()
        guard l.hasPrefix("http://") || l.hasPrefix("https://") else {
            err = "Link phải bắt đầu bằng http:// hoặc https://"
            return
        }
        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), u)
    }
}
