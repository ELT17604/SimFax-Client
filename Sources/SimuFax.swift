import SwiftUI
import AppKit
import CryptoKit
import Security
import UniformTypeIdentifiers
import PDFKit

struct Fax: Codable, Identifiable {
    var id: String
    var status: String
    var pages: Int?
    var received_at: String?
    var updated_at: String?
    var error: String?
    var filename: String?
    var subject: String?
    var duplicate: Bool?
}
struct ServerReply: Decodable {
    var ok: Bool?
    var id: String?
    var status: String?
    var pages: Int?
    var received_at: String?
    var updated_at: String?
    var error: String?
    var code: String?
    var duplicate: Bool?
    var service: String?
    var `protocol`: String?
    var time: String?
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
struct KeyStore {
    static let service = "uk.verstappen.simufax.macos"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        if value.isEmpty { let s = SecItemDelete(q as CFDictionary); guard s == errSecSuccess || s == errSecItemNotFound else { throw AppError.message("钥匙串错误：\(s)") }; return }
        let data = Data(value.utf8)
        let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(item as CFDictionary, nil); guard add == errSecSuccess else { throw AppError.message("钥匙串错误：\(add)") }
        } else if s != errSecSuccess { throw AppError.message("钥匙串错误：\(s)") }
    }
}
final class UploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}
@MainActor final class Model: ObservableObject {
    @Published var exchanges: [Exchange] = []
    @Published var selectedExchange: UUID?
    @Published var consoleTab = "返回值"
    @Published var prettyJSON = true
    @Published var section = "发送传真"
    @Published var confirm = false
    @Published var targeted = false
    @Published var key = KeyStore.read()
    @Published var sender = ""; @Published var recipient = ""; @Published var subject = ""; @Published var message = ""
    @Published var fileURL: URL?; @Published var bytes: Int64 = 0; @Published var hash = ""; @Published var pages: Int?
    @Published var messageID = UUID().uuidString; @Published var busy = false; @Published var progress = 0.0
    @Published var notice = ""; @Published var health = "尚未检查"; @Published var jobs: [Fax] = []
    @Published var manualID = ""; @Published var retryAfter: Date?
    private let base = URL(string: "https://fax.verstappen.uk")!
    private var pollTask: Task<Void, Never>?
    private let historyURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SimuFax", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("history.json")
    }()
    init() {
        if let data = try? Data(contentsOf: historyURL), let stored = try? JSONDecoder().decode([Fax].self, from: data) { jobs = stored }
    }
    func saveHistory() { do { try JSONEncoder().encode(jobs).write(to: historyURL, options: .atomic) } catch { notice = "本地历史保存失败：\(error.localizedDescription)" } }
    func choose(_ url: URL) {
        do {
            let allowed = ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "txt"]
            guard allowed.contains(url.pathExtension.lowercased()) else { throw AppError.message("请选择 PDF、PNG、JPEG、TIFF 或 TXT 文件。") }
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            fileURL = url; bytes = Int64(data.count); hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            pages = url.pathExtension.lowercased() == "pdf" ? PDFDocument(data: data)?.pageCount : nil
            messageID = UUID().uuidString; notice = ""
        } catch { notice = "无法读取文件：\(error.localizedDescription)" }
    }
    func saveKey() { do { try KeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = KeyStore.read(); notice = key.isEmpty ? "密钥已从钥匙串移除。" : "密钥已保存到钥匙串。" } catch { notice = error.localizedDescription } }
    func endpoint(_ suffix: String) -> URL { base.appendingPathComponent("api/v1").appendingPathComponent(suffix) }
    func check(_ data: Data, _ response: URLResponse) throws -> ServerReply {
        guard let http = response as? HTTPURLResponse else { throw AppError.message("服务器响应无效。") }
        let parsed = try? JSONDecoder().decode(ServerReply.self, from: data)
        guard (200...299).contains(http.statusCode), parsed?.ok != false else {
            var msg = "HTTP \(http.statusCode)"; if let code = parsed?.code { msg += " · \(code)" }; if let e = parsed?.error { msg += "：\(e)" }
            if http.statusCode == 429, let s = http.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(s), seconds > 0 { retryAfter = Date().addingTimeInterval(seconds); msg += "。请等待 \(Int(seconds)) 秒后重试。" }
            throw AppError.message(msg)
        }
        guard let parsed else { throw AppError.message("服务器返回了无法识别的 JSON。") }; return parsed
    }
    func healthCheck() async {
        do { let (d,r) = try await perform(URLRequest(url: endpoint("health"))); let p = try check(d,r); health = p.ok == true ? "服务正常 · \(p.service ?? "SimuFax")" : "响应缺少健康状态" } catch { health = "检查失败 · \(error.localizedDescription)" }
    }
    func perform(_ request: URLRequest, body: Data? = nil, fileName: String? = nil) async throws -> (Data, URLResponse) {
        let entry = Exchange(request: request, body: body, fileName: fileName, secret: KeyStore.read())
        exchanges.insert(entry, at: 0)
        if exchanges.count > 100 { exchanges.removeLast() }
        selectedExchange = entry.id
        let delegate = UploadDelegate { [weak self] p in Task { @MainActor in self?.progress = p } }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let result: (Data, URLResponse)
            if let body { result = try await session.upload(for: request, from: body) }
            else { result = try await session.data(for: request) }
            if let i = exchanges.firstIndex(where: { $0.id == entry.id }) { exchanges[i].finish(result.0, result.1, secret: KeyStore.read()) }
            return result
        } catch {
            if let i = exchanges.firstIndex(where: { $0.id == entry.id }) { exchanges[i].failure = error.localizedDescription; exchanges[i].duration = Date().timeIntervalSince(entry.date) }
            throw error
        }
    }
    func submit() async {
        guard !busy else { return }; guard let fileURL else { notice = "请先选择文件。"; return }
        guard !KeyStore.read().isEmpty else { notice = "请先在设置中保存密钥。"; return }
        guard sender.count <= 120, recipient.count <= 120, subject.count <= 200, message.count <= 2000 else { notice = "字段超出长度限制。"; return }
        if let retryAfter, retryAfter > Date() { notice = "服务器要求稍后重试。"; return }
        busy = true; progress = 0; defer { busy = false }
        let access = fileURL.startAccessingSecurityScopedResource(); defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let file = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let currentHash = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
            guard currentHash == hash else { throw AppError.message("文件自选择后发生变化，请重新选择文件。") }
            let boundary = "SimuFax-\(UUID().uuidString)"
            var body = Data(); func append(_ s: String) { body.append(Data(s.utf8)) }
            for (name, value) in [("sender",sender),("recipient",recipient),("subject",subject),("message",message)] where !value.isEmpty {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            let safeName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"); body.append(file); append("\r\n--\(boundary)--\r\n")
            var req = URLRequest(url: endpoint("fax")); req.httpMethod = "POST"; req.timeoutInterval = 120
            req.setValue("Bearer \(KeyStore.read())", forHTTPHeaderField: "Authorization"); req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.setValue(messageID, forHTTPHeaderField: "X-SimuFax-Message-Id"); req.setValue(hash, forHTTPHeaderField: "X-SimuFax-Sha256")
            let (data,response) = try await perform(req, body: body, fileName: fileURL.lastPathComponent)
            let p = try check(data,response); guard let id = p.id, !id.isEmpty else { throw AppError.message("服务器未返回任务编号，请保留幂等 ID 并联系管理员。") }
            let job = Fax(id: id, status: p.status ?? "unknown", pages: p.pages, received_at: p.received_at, filename: fileURL.lastPathComponent, subject: subject, duplicate: p.duplicate)
            jobs.removeAll { $0.id == id }; jobs.insert(job, at: 0); saveHistory(); notice = "已接收任务 \(id)\(p.duplicate == true ? "（已有任务）" : "")。接收不等于打印完成。"
            self.fileURL = nil; hash = ""; pages = nil; messageID = UUID().uuidString
        } catch { notice = "提交未确认：\(error.localizedDescription)\n如需重试，请保持文件和字段不变并使用当前幂等 ID。" }
    }
    func fetch(_ id: String) async {
        guard !id.isEmpty else { return }; guard !KeyStore.read().isEmpty else { notice = "请先保存密钥。"; return }
        if let retryAfter, retryAfter > Date() { return }
        do {
            var components = URLComponents(url: endpoint("fax"), resolvingAgainstBaseURL: false)!
            components.percentEncodedPath += "/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))) ?? "")
            guard let url = components.url else { throw AppError.message("任务编号无效。") }
            var req = URLRequest(url: url); req.setValue("Bearer \(KeyStore.read())", forHTTPHeaderField: "Authorization")
            let (d,r) = try await perform(req); let p = try check(d,r)
            guard let returnedID = p.id, returnedID == id, let status = p.status else { throw AppError.message("状态响应缺少有效的任务编号或状态。") }
            if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = status; jobs[i].pages = p.pages; jobs[i].updated_at = p.updated_at; jobs[i].error = p.error }
            else { jobs.insert(Fax(id: id, status: status, pages: p.pages, received_at: p.received_at, updated_at: p.updated_at, error: p.error), at: 0) }
            saveHistory()
        } catch { notice = "查询 \(id) 失败：\(error.localizedDescription)" }
    }
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 15_000_000_000); if Task.isCancelled { break }; for id in jobs.filter({ ["pending", "printing"].contains($0.status) }).map(\.id) { await fetch(id); if let retryAfter, retryAfter > Date() { break } } } }
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) { content.padding(22).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 20)) }
        else { content.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) }
    }
}
struct MainView: View {
    @ObservedObject var model: Model
    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label("发送传真", systemImage: "paperplane").tag("发送传真")
                Label("任务历史", systemImage: "clock.arrow.circlepath").tag("任务历史")
                Label("设置", systemImage: "gearshape").tag("设置")
            }.listStyle(.sidebar).navigationTitle("SimuFax")
            VStack(alignment: .leading, spacing: 10) {
                Label("SIMUFAX / NATIVE", systemImage: "shield.lefthalf.filled").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Button { ConsoleWindow.shared.show(model) } label: { Label("请求与响应", systemImage: "terminal") }.buttonStyle(.bordered).help("打开悬浮控制台 ⌘⇧D")
            }.padding(.horizontal).padding(.top, 12)
            VStack(alignment: .leading, spacing: 4) { Text("服务状态").font(.caption).foregroundStyle(.secondary); Text(model.health).font(.caption); Button("检查连接") { Task { await model.healthCheck() } }.buttonStyle(.link) }.padding()
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.section {
                    case "任务历史": history
                    case "设置": settings
                    default: compose
                    }
                    if !model.notice.isEmpty { Label(model.notice, systemImage: "info.circle").font(.callout).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
                }.padding(32).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }.background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(colors: [Color.blue.opacity(0.10), Color.cyan.opacity(0.025), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }.frame(minWidth: 960, minHeight: 720)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { ConsoleWindow.shared.show(model) } label: { Label("控制台", systemImage: "terminal") }.help("请求与响应 · ⌘⇧D")
                }
            }
            .task { model.startPolling() }
            .alert("确认提交文件？", isPresented: $model.confirm) {
                Button("提交", role: .destructive) { Task { await model.submit() } }; Button("取消", role: .cancel) {}
            } message: { Text("文件将发送到传真站，可能触发实际打印。") }
    }
    @ViewBuilder var compose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOCUMENT DELIVERY").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.blue)
            Text("一份文件，即刻投递。").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("选择文件，补充信息，随时掌握处理进度。").foregroundStyle(.secondary)
        }.padding(.vertical, 8)
        HStack(spacing: 12) {
            MetricTile(title: "文件就绪", value: model.fileURL == nil ? "待选择" : "已选择", icon: "doc.badge.checkmark", color: .blue)
            MetricTile(title: "正在处理", value: "\(model.jobs.filter { ["pending", "printing"].contains($0.status) }.count)", icon: "arrow.triangle.2.circlepath", color: .orange)
            MetricTile(title: "打印完成", value: "\(model.jobs.filter { $0.status == "printed" }.count)", icon: "checkmark.seal", color: .green)
        }
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("01  选择文件", systemImage: "doc.on.doc").font(.headline)
                Button { let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff, .plainText]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { model.choose(url) } } label: {
                    VStack(spacing: 9) { Image(systemName: model.fileURL == nil ? "arrow.up.document" : "doc.text.fill").font(.system(size: 30)).foregroundStyle(.tint); Text(model.fileURL?.lastPathComponent ?? "选择文件或拖放到这里").font(.headline); Text("PDF、PNG、JPEG、TIFF 或 TXT").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(24).background(.quaternary.opacity(model.targeted ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).disabled(model.busy)
                    .onDrop(of: [.fileURL], isTargeted: $model.targeted) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.choose(url) } } }; return true
                    }
                if model.fileURL != nil {
                    Text("\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))\(model.pages.map { " · PDF \($0) 页（本地读取）" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    Text("SHA-256  \(model.hash)").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("02  补充投递信息", systemImage: "text.alignleft").font(.headline)
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(title: "发件人", hint: "留空为未知发件人", text: $model.sender)
                    LabeledField(title: "收件人", hint: "留空使用站点默认值", text: $model.recipient)
                }
                LabeledField(title: "主题", hint: "为这份文件添加标题", text: $model.subject)
                VStack(alignment: .leading, spacing: 6) { Text("附言").font(.caption).foregroundStyle(.secondary); TextField("需要说明的事项（可选）", text: $model.message, axis: .vertical).lineLimit(3...6) }
                Divider(); Text("幂等 ID：\(model.messageID)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("若提交结果不明，请保持内容不变并重试；重新选择文件会生成新 ID。 ").font(.caption).foregroundStyle(.secondary)
                if model.busy { ProgressView(value: model.progress) { Text("正在上传") } }
                HStack { Spacer(); Button("发送传真") { model.confirm = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.fileURL == nil || model.busy) }
            }.textFieldStyle(.roundedBorder).disabled(model.busy)
        }
    }
    @ViewBuilder var history: some View {
        VStack(alignment: .leading, spacing: 6) { Text("任务历史").font(.largeTitle.bold()); Text("保存在此 Mac 上；进行中的任务每 15 秒查询一次。").foregroundStyle(.secondary) }
        GlassCard { HStack { TextField("输入任务编号", text: $model.manualID).textFieldStyle(.roundedBorder); Button("查询") { let id = model.manualID.trimmingCharacters(in: .whitespacesAndNewlines); Task { await model.fetch(id) } } } }
        if model.jobs.isEmpty { ContentUnavailableView("暂无任务", systemImage: "tray", description: Text("发送文件或输入任务编号后，任务会出现在这里。")) }
        ForEach(model.jobs) { job in
            GlassCard { HStack(alignment: .top) { VStack(alignment: .leading, spacing: 7) { Text(job.subject?.isEmpty == false ? job.subject! : (job.filename ?? "传真任务")).font(.headline); Text(job.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled); HStack { StatusPill(status: job.status); if let pages = job.pages { Text("\(pages) 页").font(.caption).foregroundStyle(.secondary) } }; if let error = job.error { Text(error).foregroundStyle(.red).font(.caption) } }; Spacer(); Button("刷新") { Task { await model.fetch(job.id) } } } }
        }
    }
    @ViewBuilder var settings: some View {
        VStack(alignment: .leading, spacing: 6) { Text("设置").font(.largeTitle.bold()); Text("连接与密钥").foregroundStyle(.secondary) }
        GlassCard { VStack(alignment: .leading, spacing: 14) {
            Text("API 密钥").font(.headline); Text("密钥保存在 macOS 钥匙串中。查询任务时需要使用发送时相同的密钥。").foregroundStyle(.secondary)
            SecureField("sfx_…", text: $model.key).textFieldStyle(.roundedBorder)
            HStack { Button("保存密钥") { model.saveKey() }.buttonStyle(.borderedProminent); Button("移除密钥") { model.key = ""; model.saveKey() } }
            Divider(); Text("服务地址").font(.headline); Text("https://fax.verstappen.uk").textSelection(.enabled); Button("检查服务健康") { Task { await model.healthCheck() } }; Text(model.health).font(.caption).foregroundStyle(.secondary)
        } }
    }
}
@main struct SimuFaxApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup { MainView(model: model) }.windowStyle(.titleBar)
            .commands { CommandGroup(after: .toolbar) { Button("显示请求与响应") { ConsoleWindow.shared.show(model) }.keyboardShortcut("d", modifiers: [.command, .shift]) } }
    }
}

struct LabeledField: View {
    let title: String
    let hint: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}
struct MetricTile: View {
    let title: String; let value: String; let icon: String; let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
struct StatusPill: View {
    let status: String
    var color: Color { switch status { case "printed": return .green; case "failed", "rejected": return .red; case "printing": return .orange; default: return .blue } }
    var title: String { ["pending": "等待处理", "printing": "正在打印", "printed": "打印完成", "rejected": "已拒绝", "failed": "处理失败"][status] ?? status }
    var body: some View { Label(title, systemImage: status == "printed" ? "checkmark.circle.fill" : "circle.fill").font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.10), in: Capsule()) }
}

/// Bounded, in-memory diagnostic records. Credentials and binary document data are excluded.
struct Exchange: Identifiable {
    let id = UUID()
    let date = Date()
    var method: String
    var url: String
    var command: String
    var requestRaw: String
    var responseRaw = "等待服务器响应…"
    var responseBody = ""
    var responseHeaders = ""
    var status: Int?
    var duration: TimeInterval?
    var failure: String?
    static func scrub(_ text: String, secret: String) -> String {
        let safe = secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "<REDACTED>")
        return safe.replacingOccurrences(of: #"sfx_[A-Za-z0-9_\-\.]+"#, with: "<REDACTED>", options: .regularExpression)
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    init(request: URLRequest, body: Data?, fileName: String?, secret: String) {
        method = request.httpMethod ?? "GET"; url = request.url?.absoluteString ?? ""
        let headers = (request.allHTTPHeaderFields ?? [:]).map { key, value in
            (key, ["authorization", "x-simufax-key", "cookie"].contains(key.lowercased()) ? "<REDACTED>" : Self.scrub(value, secret: secret))
        }.sorted { $0.0 < $1.0 }
        var lines = ["\(method) \(url) HTTP/1.1"] + headers.map { "\($0.0): \($0.1)" }
        command = "curl --request \(method) " + Self.quote(url)
        for (key, value) in headers where key.lowercased() != "content-type" || body == nil { command += " \\\n  --header " + Self.quote("\(key): \(value)") }
        if let body {
            // Preserve actual multipart delimiters and text fields, replacing only the file bytes.
            let marker = Data("Content-Type: application/octet-stream\r\n\r\n".utf8)
            if let range = body.range(of: marker) {
                let prefix = String(decoding: body[..<range.upperBound], as: UTF8.self)
                let tailMarker = Data("\r\n--SimuFax-".utf8)
                let tail = body.range(of: tailMarker, options: .backwards, in: range.upperBound..<body.endIndex)
                let end = tail?.lowerBound ?? body.endIndex
                let suffix = tail.map { String(decoding: body[$0.lowerBound...], as: UTF8.self) } ?? ""
                lines.append("\n" + prefix + "<binary file omitted: \(end - range.upperBound) bytes>" + suffix)
                // Equivalent curl command uses --form-string for safe free-text metadata.
                let boundary = (request.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: "boundary=").last ?? ""
                for part in prefix.components(separatedBy: "--" + boundary) {
                    guard let nameStart = part.range(of: "name=\""), let nameEnd = part[nameStart.upperBound...].firstIndex(of: "\"") else { continue }
                    let name = String(part[nameStart.upperBound..<nameEnd])
                    guard name != "file", let content = part.range(of: "\r\n\r\n") else { continue }
                    var value = String(part[content.upperBound...]); if value.hasSuffix("\r\n") { value.removeLast(2) }
                    command += " \\\n  --form-string " + Self.quote(name + "=" + Self.scrub(value, secret: secret))
                }
                command += " \\\n  --form " + Self.quote("file=@/path/to/" + (fileName ?? "document"))
            } else { lines.append("\n<body omitted: \(body.count) bytes>") }
        }
        requestRaw = Self.scrub(lines.joined(separator: "\r\n"), secret: secret)
        command = Self.scrub(command, secret: secret)
    }
    mutating func finish(_ data: Data, _ response: URLResponse, secret: String) {
        duration = Date().timeIntervalSince(date)
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            responseHeaders = (["HTTP \(http.statusCode)"] + http.allHeaderFields.map { key, value in
                let name = String(describing: key)
                return "\(name): \(name.lowercased() == "set-cookie" ? "<REDACTED>" : String(describing: value))"
            }.sorted()).joined(separator: "\n")
        }
        let limited = data.prefix(256 * 1024)
        responseBody = Self.scrub(String(decoding: limited, as: UTF8.self), secret: secret)
        if data.count > limited.count { responseBody += "\n[响应超过 256 KiB，显示已截断]" }
        responseHeaders = Self.scrub(responseHeaders, secret: secret)
        responseRaw = responseHeaders + "\n\n" + responseBody
    }
    var formattedResponse: String {
        guard let data = responseBody.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), let text = String(data: formatted, encoding: .utf8) else { return responseRaw }
        return responseHeaders + "\n\n" + text
    }
}

@MainActor final class ConsoleWindow {
    static let shared = ConsoleWindow()
    private var panel: NSPanel?
    func show(_ model: Model) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            p.title = "SimuFax · 请求与响应"
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.minSize = NSSize(width: 740, height: 460)
            p.contentView = NSHostingView(rootView: ConsoleView(model: model))
            p.center(); panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}
struct ConsoleView: View {
    @ObservedObject var model: Model
    var selected: Exchange? { model.exchanges.first { $0.id == model.selectedExchange } ?? model.exchanges.first }
    var displayed: String {
        guard let e = selected else { return "执行健康检查、上传或查询任务后，可在这里查看记录。" }
        switch model.consoleTab {
        case "命令": return "# 等价 cURL 命令（应用实际使用 URLSession；密钥已隐藏，文件路径需替换）\n\n" + e.command
        case "请求": return e.requestRaw
        default: return e.failure.map { "网络错误\n\n" + $0 } ?? (model.prettyJSON ? e.formattedResponse : e.responseRaw)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) { Text("网络控制台").font(.headline); Text("仅在内存中保留最近 100 条记录 · 认证信息已隐藏").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.exchanges.removeAll(); model.selectedExchange = nil } label: { Label("清空", systemImage: "trash") }.disabled(model.exchanges.isEmpty)
            }.padding(16).background(.regularMaterial)
            Divider()
            HSplitView {
                List(selection: $model.selectedExchange) {
                    ForEach(model.exchanges) { e in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(e.method).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(.blue); Spacer(); Text(e.status.map(String.init) ?? (e.failure == nil ? "…" : "失败")).font(.caption.weight(.medium)).foregroundStyle((e.status ?? 0) >= 400 || e.failure != nil ? Color.red : Color.secondary) }
                            Text(URL(string: e.url)?.path ?? e.url).font(.system(.caption, design: .monospaced)).lineLimit(2)
                            Text(e.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 6).tag(e.id)
                    }
                }.listStyle(.sidebar).frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                VStack(spacing: 0) {
                    HStack {
                        Picker("内容", selection: $model.consoleTab) { Text("命令").tag("命令"); Text("请求 RAW").tag("请求"); Text("返回值 RAW").tag("返回值") }.pickerStyle(.segmented).frame(maxWidth: 330)
                        Spacer()
                        Toggle("格式化 JSON", isOn: $model.prettyJSON).toggleStyle(.checkbox).disabled(model.consoleTab != "返回值")
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(displayed, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("复制当前内容")
                    }.padding(12)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Text(displayed).font(.system(size: 12, design: .monospaced)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                    }.background(Color(nsColor: .textBackgroundColor))
                    Divider()
                    HStack { Circle().fill(selected?.failure == nil ? Color.blue : Color.red).frame(width: 6, height: 6); Text(selected?.duration.map { String(format: "%.3f 秒", $0) } ?? "等待请求"); Spacer(); Text("正文以 UTF-8 显示 · 文件二进制不记录") }.font(.caption2).foregroundStyle(.secondary).padding(10)
                }.frame(minWidth: 510)
            }
        }
    }
}
