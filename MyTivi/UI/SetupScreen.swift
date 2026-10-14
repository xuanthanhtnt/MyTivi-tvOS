import SwiftUI

/// Cài đặt: link playlist (.m3u / .m3u8) và link EPG.
struct SetupScreen: View {
    let initialUrl: String
    let initialEpg: String
    let canCancel: Bool
    let onSave: (_ url: String, _ epg: String) -> Void
    let onCancel: () -> Void

    enum Field: Hashable { case url, epg, save, cancel }

    @State private var url = ""
    @State private var epg = ""
    @State private var err: String?
    @FocusState private var field: Field?

    var body: some View {
        VStack(spacing: 26) {
            Text("Cài đặt MyTivi")
                .font(.system(size: 56, weight: .bold))
            Text("Phiên bản \(Fmt.appVersion)")
                .font(.system(size: 24))
                .foregroundStyle(Theme.dim)
            Text("Dán link danh sách kênh (.m3u) hoặc một luồng .m3u8")
                .font(.system(size: 28))
                .foregroundStyle(Theme.dim)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 10) {
                Text("Link playlist (.m3u) hoặc luồng .m3u8")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.dim)
                TextField("http://…", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .url)
            }
            .frame(width: 1200)

            VStack(alignment: .leading, spacing: 10) {
                Text("Link EPG – lịch phát sóng XMLTV (không bắt buộc)")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.dim)
                TextField("http://… (.xml hoặc .xml.gz)", text: $epg)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .epg)
            }
            .frame(width: 1200)

            if let err {
                Text(err)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.error)
            }

            HStack(spacing: 30) {
                Button("Lưu", action: save)
                    .buttonStyle(TvPillButtonStyle())
                    .focused($field, equals: .save)
                if canCancel {
                    Button("Hủy", action: onCancel)
                        .buttonStyle(TvPillButtonStyle())
                        .focused($field, equals: .cancel)
                }
            }
            .padding(.top, 10)

            Text("Mẹo: có thể dán link từ iPhone bằng bàn phím trên điện thoại (thông báo \"Bàn phím Apple TV\").")
                .font(.system(size: 20))
                .foregroundStyle(Theme.dim)
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            url = initialUrl
            epg = initialEpg
            DispatchQueue.main.async { field = .url }
        }
        .onExitCommand(perform: canCancel ? onCancel : nil)
    }

    private func save() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = epg.trimmingCharacters(in: .whitespacesAndNewlines)
        func isHttp(_ s: String) -> Bool {
            let l = s.lowercased()
            return l.hasPrefix("http://") || l.hasPrefix("https://")
        }
        if !isHttp(u) {
            err = "Link playlist phải bắt đầu bằng http:// hoặc https://"
        } else if !e.isEmpty && !isHttp(e) {
            err = "Link EPG phải bắt đầu bằng http:// hoặc https://"
        } else {
            err = nil
            onSave(u, e)
        }
    }
}
