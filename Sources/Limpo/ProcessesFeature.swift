import SwiftUI
import AppKit
import Darwin

// MARK: - Processos (lista completa via `ps`)

struct ProcessInfoRow: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let memoryBytes: Int64
    let cpu: Double
    let user: String
    let path: String
    let name: String
    var id: Int32 { pid }

    var isApp: Bool { path.contains(".app/") }

    /// Pacote .app mais externo (o app "dono" dos helpers aninhados dentro dele).
    var bundlePath: String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

/// O que um processo e um grupo de processos têm em comum (para ordenar os dois do mesmo jeito).
protocol ProcessMetrics {
    var pid: Int32 { get }
    var memoryBytes: Int64 { get }
    var cpu: Double { get }
    var name: String { get }
}

extension ProcessInfoRow: ProcessMetrics {}

/// Processos somados pelo app a que pertencem (ex.: Google Chrome + todos os "Google Chrome Helper").
/// Fora de um .app, junta os processos do mesmo executável.
struct ProcessGroup: Identifiable, ProcessMetrics {
    let key: String
    let name: String
    /// Processo principal: usado no ícone, no PID e nas ações.
    let main: ProcessInfoRow
    let members: [ProcessInfoRow]
    let memoryBytes: Int64
    let cpu: Double
    var id: String { key }
    var pid: Int32 { main.pid }
    var count: Int { members.count }

    init(key: String, members: [ProcessInfoRow]) {
        let byMemory = members.sorted { $0.memoryBytes > $1.memoryBytes }
        let pids = Set(byMemory.map(\.pid))
        let main = byMemory.first { $0.path.hasPrefix(key + "/Contents/MacOS/") }
            ?? byMemory.first { !pids.contains($0.ppid) }
            ?? byMemory[0]
        self.key = key
        self.name = key.hasSuffix(".app") ? ((key as NSString).lastPathComponent as NSString).deletingPathExtension : main.name
        self.main = main
        self.members = byMemory
        self.memoryBytes = byMemory.reduce(0) { $0 + $1.memoryBytes }
        self.cpu = byMemory.reduce(0) { $0 + $1.cpu }
    }

    init(single p: ProcessInfoRow) {
        self.init(key: "pid:\(p.pid)", members: [p])
    }

    var killWarning: String {
        count > 1
            ? "Encerra \(name) e os \(count) processos dele. Alterações não salvas podem ser perdidas."
            : "Alterações não salvas nesse app podem ser perdidas."
    }
}

@MainActor
@Observable
final class ProcessModel {
    enum Sort: String { case memory, cpu, name, pid }

    var all: [ProcessInfoRow] = []
    var sort: Sort = .memory
    var ascending = false
    var query = ""
    var onlyMine = false
    var error: String?
    /// Detalhes de "Por que está em execução?" abertos na janela (no monitor vira um NSAlert).
    var info: ProcessDetails?
    /// Grupos abertos na lista (mostram cada processo do app).
    var expanded: Set<String> = []

    func topByMemory(_ n: Int) -> [ProcessGroup] {
        Array(Self.group(all).sorted { $0.memoryBytes > $1.memoryBytes }.prefix(n))
    }

    private var viewers = 0
    private var loop: Task<Void, Never>?
    private var iconCache: [Int32: NSImage] = [:]

    var totalMemory: Int64 { all.reduce(0) { $0 + $1.memoryBytes } }

    var visible: [ProcessGroup] {
        var list = all
        if onlyMine {
            let me = NSUserName()
            list = list.filter { $0.user == me }
        }
        var groups = Self.group(list)
        if !query.isEmpty {
            groups = groups.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.members.contains(where: matches) }
        }
        return sorted(groups)
    }

    /// Processos mostrados ao abrir um grupo; numa busca que não bate com o nome do app, só os que batem.
    func children(of g: ProcessGroup) -> [ProcessInfoRow] {
        guard !query.isEmpty, !g.name.localizedCaseInsensitiveContains(query) else { return sorted(g.members) }
        return sorted(g.members.filter(matches))
    }

    func isExpanded(_ g: ProcessGroup) -> Bool {
        g.count > 1 && (expanded.contains(g.id) || (!query.isEmpty && !g.name.localizedCaseInsensitiveContains(query)))
    }

    func toggleExpanded(_ g: ProcessGroup) {
        if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
    }

    private func matches(_ p: ProcessInfoRow) -> Bool {
        p.name.localizedCaseInsensitiveContains(query) || "\(p.pid)" == query
    }

    private func sorted<T: ProcessMetrics>(_ list: [T]) -> [T] {
        let sorted: [T]
        switch sort {
        case .memory: sorted = list.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu: sorted = list.sorted { $0.cpu > $1.cpu }
        case .name: sorted = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: sorted = list.sorted { $0.pid < $1.pid }
        }
        let defaultAscending = sort == .name || sort == .pid
        return ascending == defaultAscending ? sorted : sorted.reversed()
    }

    /// Junta os processos pelo .app mais externo do caminho; fora de apps, pelo executável.
    nonisolated static func group(_ list: [ProcessInfoRow]) -> [ProcessGroup] {
        Dictionary(grouping: list) { p in p.bundlePath ?? (p.path.isEmpty ? "pid:\(p.pid)" : p.path) }
            .map { ProcessGroup(key: $0.key, members: $0.value) }
    }

    func toggleSort(_ s: Sort) {
        if sort == s {
            ascending.toggle()
        } else {
            sort = s
            ascending = (s == .name || s == .pid)
        }
    }

    func attach() {
        viewers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() async {
        do {
            let output = try await Shell.run("/bin/ps", ["-axww", "-o", "pid=,ppid=,rss=,%cpu=,user=,comm="])
            all = Self.parse(output)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func parse(_ text: String) -> [ProcessInfoRow] {
        text.split(separator: "\n").compactMap { raw in
            let fields = raw.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let rss = Int64(fields[2]) else { return nil }
            let cpu = Double(fields[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            let path = String(fields[5]).trimmingCharacters(in: .whitespaces)
            return ProcessInfoRow(
                pid: pid,
                ppid: ppid,
                memoryBytes: footprint(pid) ?? rss * 1024,
                cpu: cpu,
                user: String(fields[4]),
                path: path,
                name: displayName(pid: pid, path: path)
            )
        }
    }

    /// Memória como o Monitor de Atividade mostra (phys_footprint): não conta de novo a memória compartilhada,
    /// por isso a soma por app fica certa. Processos de outros usuários (root) não permitem a leitura e ficam com o RSS do `ps`.
    nonisolated static func footprint(_ pid: Int32) -> Int64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    nonisolated static func displayName(pid: Int32, path: String) -> String {
        // Para apps, usa o nome do pacote .app (ex.: "Google Chrome Helper (Renderer)" continua com o próprio nome).
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "PID \(pid)" : last
    }

    func icon(for p: ProcessInfoRow) -> NSImage? {
        if let cached = iconCache[p.pid] { return cached }
        var image: NSImage?
        if let app = NSRunningApplication(processIdentifier: p.pid), let icon = app.icon {
            image = icon
        } else if let bundle = p.bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundle)
        }
        if let image { iconCache[p.pid] = image }
        return image
    }

    // MARK: Ações

    func copyPID(_ p: ProcessInfoRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(p.pid)", forType: .string)
    }

    func reveal(_ p: ProcessInfoRow) {
        let target = p.bundlePath ?? p.path
        guard FileManager.default.fileExists(atPath: target) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    enum CloseOutcome { case closed, stillRunning, needsAdmin }

    /// Pergunta antes de encerrar e confere o resultado. NSAlert funciona igual na janela e no monitor da barra.
    func confirmTerminate(_ g: ProcessGroup) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Encerrar \(g.name)?"
            alert.informativeText = g.killWarning
            alert.addButton(withTitle: "Encerrar")
            alert.addButton(withTitle: "Forçar encerramento")
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            guard answer != .alertThirdButtonReturn else { return }
            await terminate(g, force: answer == .alertSecondButtonReturn)
        }
    }

    func terminate(_ g: ProcessGroup, force: Bool) async {
        switch await close(g, force: force) {
        case .closed:
            return
        case .stillRunning:
            if force {
                inform("\(g.name) não fechou", "O macOS não deixou encerrar o processo.")
            } else if ask("\(g.name) ainda está aberto",
                          "Ele pode estar esperando você salvar algo ou não respondeu ao pedido para fechar. Forçar o encerramento? Alterações não salvas serão perdidas.",
                          button: "Forçar encerramento") {
                await terminate(g, force: true)
            }
        case .needsAdmin:
            let owner = g.members.first { $0.user != NSUserName() }?.user ?? "root"
            guard ask("\(g.name) é um processo do sistema",
                      "Ele roda como \(owner) e só fecha com a senha de administrador. O macOS pode abri-lo de novo. Encerrar mesmo assim?",
                      button: "Encerrar com senha…") else { return }
            killAsAdmin(g.members.map(\.pid))
            await refresh()
        }
    }

    /// Manda o grupo fechar e espera até 4 s para conferir se fechou.
    func close(_ g: ProcessGroup, force: Bool) async -> CloseOutcome {
        let pids = g.members.map(\.pid)
        if pids.contains(where: { kill($0, 0) != 0 && errno == EPERM }) { return .needsAdmin }
        var watched = pids
        if force {
            NSRunningApplication(processIdentifier: g.main.pid)?.forceTerminate()
            for pid in pids { kill(pid, SIGKILL) }
        } else if let app = NSRunningApplication(processIdentifier: g.main.pid), app.activationPolicy == .regular {
            // App com ícone no Dock: fecha como ⌘Q e os auxiliares saem junto; basta conferir o principal.
            app.terminate()
            watched = [g.main.pid]
        } else {
            // Auxiliares e processos sem janela ignoram o pedido de "sair" do macOS: vai sinal direto.
            for pid in pids { kill(pid, SIGTERM) }
        }
        var waited = 0
        while waited < 20, watched.contains(where: Self.isAlive) {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        await refresh()
        return watched.contains(where: Self.isAlive) ? .stillRunning : .closed
    }

    nonisolated static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Processos de outro usuário (root) só fecham com a senha de administrador, pedida pelo próprio macOS.
    private func killAsAdmin(_ pids: [Int32]) {
        let list = pids.map(String.init).joined(separator: " ")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/bin/kill -9 \(list)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error, error[NSAppleScript.errorNumber] as? Int != -128 {
            inform("Não foi possível encerrar", error[NSAppleScript.errorMessage] as? String ?? "Erro desconhecido.")
        }
    }

    private func ask(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func explain(_ g: ProcessGroup) async {
        let p = g.main
        let parent = all.first { $0.pid == p.ppid }
        let started = (try? await Shell.run("/bin/ps", ["-o", "lstart=", "-p", "\(p.pid)"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        info = ProcessDetails(group: g, parent: parent, started: started)
    }

    /// "Por que está em execução?" no monitor da barra: um NSAlert em vez da folha da janela.
    func explainInAlert(_ g: ProcessGroup) async {
        await explain(g)
        guard let d = info else { return }
        info = nil
        let count = g.count > 1 ? " · \(g.count) processos" : ""
        let alert = NSAlert()
        alert.messageText = g.name
        alert.informativeText = "\(d.reason)\n\nPID \(d.process.pid) · \(Bytes.mem(g.memoryBytes))\(count)\(d.parent.map { " · pai: \($0.name)" } ?? "")\n\(d.process.path)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copiar PID")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { copyPID(d.process) }
    }
}

struct ProcessDetails: Identifiable {
    let group: ProcessGroup
    let parent: ProcessInfoRow?
    let started: String
    var process: ProcessInfoRow { group.main }
    var id: Int32 { process.pid }

    var reason: String {
        let helpers = group.count > 1 ? " Junto com ele rodam \(group.count - 1) processos auxiliares; o uso mostrado é a soma de todos." : ""
        return mainReason + helpers
    }

    private var mainReason: String {
        let p = process
        if NSRunningApplication(processIdentifier: p.pid)?.activationPolicy == .regular {
            return "É um app aberto por você (aparece no Dock)."
        }
        if p.path.contains("/Contents/Frameworks/") || p.path.contains("Helper") {
            let owner = p.path.components(separatedBy: "/").first { $0.hasSuffix(".app") }?.replacingOccurrences(of: ".app", with: "")
            return "É um processo auxiliar\(owner.map { " do \($0)" } ?? "") — some quando o app principal é fechado."
        }
        if p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/libexec") || p.path.hasPrefix("/usr/sbin") {
            return "Serviço do macOS. Encerrar pode causar instabilidade; o sistema costuma reabri-lo."
        }
        if p.ppid == 1 {
            return "Iniciado pelo launchd (item de início, agente em segundo plano ou serviço de um app)."
        }
        if let parent {
            return "Iniciado por \(parent.name) (PID \(parent.pid))."
        }
        return "Iniciado por outro processo."
    }
}

// MARK: - Lista de processos (tela Status)

struct ProcessListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.processes

        VStack(spacing: 0) {
            toolbar(model)
            Divider().overlay(Theme.hairline)
            header(model)
            Divider().overlay(Theme.hairline)
            let groups = model.visible
            let maxMemory = groups.map(\.memoryBytes).max() ?? 1
            LazyVStack(spacing: 0) {
                ForEach(groups) { g in
                    ProcessRowView(group: g, model: model, maxMemory: maxMemory)
                    if model.isExpanded(g) {
                        ForEach(model.children(of: g)) { p in
                            ProcessRowView(group: ProcessGroup(single: p), model: model, maxMemory: maxMemory, isChild: true)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .sheet(item: Binding(get: { model.info }, set: { model.info = $0 })) { details in
            ProcessDetailsSheet(details: details) { model.info = nil }
        }
    }

    private func toolbar(_ model: ProcessModel) -> some View {
        HStack(spacing: 12) {
            Text("Processos")
                .font(.system(size: 15, weight: .semibold))
            let groups = model.visible
            Text("\(groups.count) apps e serviços · \(groups.reduce(0) { $0 + $1.count }) processos · \(Bytes.mem(model.totalMemory)) em uso")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            if let zombies = store.status.snapshot?.zombie_count, zombies > 0 {
                Chip(text: "\(zombies) zumbi\(zombies > 1 ? "s" : "")", strong: true)
                    .help("Processos encerrados que o processo pai ainda não recolheu. Somem quando o app pai é fechado.")
            }
            Spacer()
            Toggle("Só meus", isOn: Binding(get: { model.onlyMine }, set: { model.onlyMine = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Buscar processo", text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.black.opacity(0.25)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func header(_ model: ProcessModel) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 10, height: 1)
            Color.clear.frame(width: 24, height: 1)
            sortButton("NOME", .name, model).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("MEMÓRIA", .memory, model).frame(width: 220, alignment: .trailing)
            sortButton("% CPU", .cpu, model).frame(width: 150, alignment: .trailing)
            sortButton("PID", .pid, model).frame(width: 64, alignment: .trailing)
            Color.clear.frame(width: 24, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func sortButton(_ title: String, _ sort: ProcessModel.Sort, _ model: ProcessModel) -> some View {
        Button {
            model.toggleSort(sort)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if model.sort == sort {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(model.sort == sort ? Theme.text : Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ordenar por \(title.lowercased())")
    }
}

private struct ProcessRowView: View {
    let group: ProcessGroup
    let model: ProcessModel
    let maxMemory: Int64
    /// Processo de um grupo aberto (linha recuada, sem seta).
    var isChild = false

    var body: some View {
        let p = group
        let expandable = !isChild && p.count > 1
        HStack(spacing: 12) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(model.isExpanded(p) ? 90 : 0))
                .frame(width: 10)
                .opacity(expandable ? 1 : 0)

            Group {
                if let icon = model.icon(for: p.main) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape")
                        .font(.system(size: isChild ? 11 : 13))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(width: isChild ? 16 : 22, height: isChild ? 16 : 22)
            .padding(.leading, isChild ? 14 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).lineLimit(1)
                    .foregroundStyle(isChild ? Theme.muted : Theme.text)
                let subtitle = [
                    p.count > 1 ? "\(p.count) processos" : nil,
                    p.main.user != NSUserName() ? p.main.user : nil
                ].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Meter(fraction: Double(p.memoryBytes) / Double(max(maxMemory, 1)), color: Palette.memory)
                    .frame(width: 110)
                Text(Bytes.mem(p.memoryBytes))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            .frame(width: 220, alignment: .trailing)

            HStack(spacing: 10) {
                Meter(fraction: min(p.cpu, 100) / 100, color: Palette.cpu)
                    .frame(width: 70)
                Text(Fmt.dec(p.cpu))
                    .monospacedDigit()
                    .foregroundStyle(p.cpu > 50 ? Palette.warm : Theme.text)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)

            Text("\(p.pid)")
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 64, alignment: .trailing)

            ProcessActionsMenu(group: p, model: model)
                .frame(width: 24)
        }
        .font(.system(size: isChild ? 12.5 : 13.5))
        .padding(.horizontal, 20)
        .frame(height: isChild ? 32 : 40)
        .background(isChild ? Color.black.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(p) }
        }
        .help(expandable ? "Clique para ver cada processo de \(p.name)" : "")
        .contextMenu { ProcessActions(group: p, model: model) }
    }
}

struct ProcessActionsMenu: View {
    let group: ProcessGroup
    let model: ProcessModel
    var origin = "window"

    var body: some View {
        Menu {
            ProcessActions(group: group, model: model, origin: origin)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ProcessActions: View {
    let group: ProcessGroup
    let model: ProcessModel
    var origin = "window"

    var body: some View {
        Button {
            Task { origin == "monitor" ? await model.explainInAlert(group) : await model.explain(group) }
        } label: { Label("Por que está em execução?", systemImage: "lightbulb") }
        Button { model.copyPID(group.main) } label: { Label("Copiar PID", systemImage: "doc.on.doc") }
        Button { model.reveal(group.main) } label: { Label("Mostrar no Finder", systemImage: "folder") }
        Divider()
        Button { model.confirmTerminate(group) } label: { Label("Encerrar…", systemImage: "xmark.circle") }
    }
}

private struct ProcessDetailsSheet: View {
    let details: ProcessDetails
    let close: () -> Void

    var body: some View {
        let p = details.process
        let g = details.group
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.memory)
                Text(g.name).font(.system(size: 20, weight: .semibold))
            }
            Text(details.reason)
                .font(.system(size: 14))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("PID", "\(p.pid)")
                row("Processo pai", details.parent.map { "\($0.name) (\($0.pid))" } ?? "PID \(p.ppid)")
                row("Usuário", p.user)
                if g.count > 1 { row("Processos", "\(g.count) (o principal e os auxiliares)") }
                row(g.count > 1 ? "Memória total" : "Memória", Bytes.mem(g.memoryBytes))
                row(g.count > 1 ? "CPU total" : "CPU", "\(Fmt.dec(g.cpu))%")
                if !details.started.isEmpty { row("Iniciado em", details.started) }
                row("Caminho", p.path)
            }
            .font(.system(size: 12.5))
            HStack {
                Spacer()
                Button("Fechar", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.muted)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}
