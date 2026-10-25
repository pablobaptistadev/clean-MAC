import SwiftUI
import AppKit

// MARK: - JSON do `mo status --json`

struct StatusSnapshot: Decodable {
    struct Hardware: Decodable {
        let model: String?
        let cpu_model: String?
        let total_ram: String?
        let disk_size: String?
        let os_version: String?
    }
    struct CPU: Decodable {
        let usage: Double?
        let per_core: [Double]?
        let load1: Double?
        let logical_cpu: Int?
        let core_count: Int?
    }
    struct GPU: Decodable {
        let name: String?
        let usage: Double?
        let note: String?
    }
    struct Memory: Decodable {
        let used: UInt64?
        let total: UInt64?
        let used_percent: Double?
        let swap_used: UInt64?
        let pressure: String?
    }
    struct Disk: Decodable {
        let mount: String?
        let used: UInt64?
        let total: UInt64?
        let used_percent: Double?
        let external: Bool?
    }
    struct DiskIO: Decodable {
        let read_rate: Double?
        let write_rate: Double?
    }
    struct Network: Decodable {
        let name: String?
        let rx_rate_mbs: Double?
        let tx_rate_mbs: Double?
    }
    struct NetworkHistory: Decodable {
        let rx_history: [Double]?
        let tx_history: [Double]?
    }
    struct Thermal: Decodable {
        let cpu_temp: Double?
        let gpu_temp: Double?
        let fan_speed: Int?
        let fan_count: Int?
        let system_power: Double?
    }
    struct Bluetooth: Decodable, Identifiable {
        let name: String
        let connected: Bool?
        let battery: String?
        var id: String { name }
    }
    struct Proc: Decodable, Identifiable {
        let pid: Int
        let name: String?
        let cpu: Double?
        let memory: Double?
        let memory_bytes: UInt64?
        var id: Int { pid }
    }

    let host: String?
    let uptime: String?
    let procs: UInt64?
    let hardware: Hardware?
    let health_score: Int?
    let health_score_msg: String?
    let cpu: CPU?
    let gpu: [GPU]?
    let memory: Memory?
    let disks: [Disk]?
    let disk_io: DiskIO?
    let network: [Network]?
    let network_history: NetworkHistory?
    let thermal: Thermal?
    let bluetooth: [Bluetooth]?
    let top_processes: [Proc]?
    let batteries: [Battery]?
    let sensors: [Sensor]?
    let proxy: Proxy?
    let zombie_count: Int?
    let process_alerts: [Alert]?
    let trash_size: UInt64?

    struct Battery: Decodable {
        let percent: Double?
        let status: String?
        let time_left: String?
        let health: String?
        let cycle_count: Int?
        let capacity: Int?
    }
    struct Sensor: Decodable, Identifiable {
        let label: String
        let value: Double?
        let unit: String?
        var id: String { label }
    }
    struct Proxy: Decodable {
        let enabled: Bool?
        let type: String?
        let host: String?
    }
    struct Alert: Decodable, Identifiable {
        let pid: Int
        let name: String?
        let cpu: Double?
        let threshold: Double?
        let window: String?
        let triggered_at: String?
        let status: String?
        var id: String { "\(pid)-\(triggered_at ?? "")" }
    }

    var activeAlerts: [Alert] { (process_alerts ?? []).filter { ($0.status ?? "active") != "resolved" } }

    var mainDisk: Disk? { disks?.first(where: { $0.mount == "/" }) ?? disks?.first(where: { $0.external != true }) }
    var gpuUsage: Double? { gpu?.compactMap(\.usage).first { $0 >= 0 } }
    var rxMBs: Double { network?.reduce(0) { $0 + ($1.rx_rate_mbs ?? 0) } ?? 0 }
    var txMBs: Double { network?.reduce(0) { $0 + ($1.tx_rate_mbs ?? 0) } ?? 0 }
    var primaryInterface: String {
        guard let name = network?.max(by: { ($0.rx_rate_mbs ?? 0) < ($1.rx_rate_mbs ?? 0) })?.name else { return "Rede" }
        return name.hasPrefix("en0") ? "Wi‑Fi" : name
    }
    var connectedBluetooth: [Bluetooth] {
        (bluetooth ?? []).filter { ($0.connected ?? true) && !($0.battery ?? "").isEmpty }
    }
    var healthLabel: String {
        let s = health_score ?? 0
        return s >= 90 ? "Ótima" : s >= 75 ? "Boa" : s >= 60 ? "Regular" : "Ruim"
    }
}

// MARK: - Modelo com histórico (para os gráficos)

@MainActor
@Observable
final class StatusModel {
    var snapshot: StatusSnapshot?
    var error: String?
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var rxHistory: [Double] = []
    var txHistory: [Double] = []

    var onAlert: ((StatusSnapshot.Alert) -> Void)?

    private var viewers = 0
    private var watch: Process?
    private var buffer = ""
    private var fallback: Task<Void, Never>?
    private var notified = Set<String>()

    static var watchArgs: [String] {
        let d = UserDefaults.standard
        var args = ["status", "--watch", "--interval", "2s"]
        let threshold = d.double(forKey: "cpuAlertThreshold")
        let minutes = d.integer(forKey: "cpuAlertMinutes")
        if d.object(forKey: "cpuAlertsEnabled") as? Bool == false {
            args += ["--proc-cpu-alerts=false"]
        } else {
            if threshold > 0 { args += ["--proc-cpu-threshold", String(format: "%.0f", threshold)] }
            if minutes > 0 { args += ["--proc-cpu-window", "\(minutes)m"] }
        }
        return args
    }

    /// Cada tela que mostra status chama `attach` ao aparecer e `detach` ao sumir.
    /// Usa `mo status --watch` (um processo só, JSON por linha); se não der, cai para consultas a cada 2s.
    func attach() {
        viewers += 1
        guard watch == nil, fallback == nil else { return }
        startWatch()
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        watch?.terminate()
        watch = nil
        fallback?.cancel()
        fallback = nil
    }

    func restart() {
        guard viewers > 0 else { return }
        watch?.terminate()
        watch = nil
        startWatch()
    }

    private func startWatch() {
        guard let mo = MoleCLI.locate() else {
            error = MoleError.notFound.localizedDescription
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mo)
        process.arguments = Self.watchArgs
        process.environment = MoleCLI.environment(tty: false)
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let started = Date()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        process.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.watch === process else { return }
                self.watch = nil
                guard self.viewers > 0 else { return }
                if Date().timeIntervalSince(started) < 5 {
                    self.startPolling()          // versão antiga do Mole sem --watch
                } else {
                    self.startWatch()            // caiu: reinicia
                }
            }
        }
        do {
            try process.run()
            watch = process
        } catch {
            startPolling()
        }
    }

    private func startPolling() {
        fallback?.cancel()
        fallback = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let snap = try? JSONDecoder().decode(StatusSnapshot.self, from: data) else { continue }
            apply(snap)
        }
        if buffer.count > 2_000_000 { buffer = "" }
    }

    func refresh() async {
        do {
            let result = try await MoleCLI.run(["status", "--json"])
            guard let data = result.output.jsonPayload(startingWith: "{") else {
                throw MoleError.failed("O mo status não devolveu JSON.")
            }
            apply(try JSONDecoder().decode(StatusSnapshot.self, from: data))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ snap: StatusSnapshot) {
        snapshot = snap
        error = nil
        push(&cpuHistory, snap.cpu?.usage ?? 0)
        push(&gpuHistory, snap.gpuUsage ?? 0)
        push(&memHistory, snap.memory?.used_percent ?? 0)
        if let rx = snap.network_history?.rx_history, rx.count > 3 {
            rxHistory = Array(rx.suffix(40))
        } else {
            push(&rxHistory, snap.rxMBs)
        }
        if let tx = snap.network_history?.tx_history, tx.count > 3 {
            txHistory = Array(tx.suffix(40))
        } else {
            push(&txHistory, snap.txMBs)
        }
        for alert in snap.activeAlerts where !notified.contains(alert.id) {
            notified.insert(alert.id)
            onAlert?(alert)
        }
    }

    private func push(_ list: inout [Double], _ value: Double) {
        list.append(value)
        if list.count > 40 { list.removeFirst(list.count - 40) }
    }
}

// MARK: - Formatação

enum Fmt {
    static func pct(_ v: Double?) -> String {
        guard let v, v >= 0 else { return "—" }
        return String(format: "%.0f", v)
    }
    static func dec(_ v: Double?) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: v ?? 0)) ?? "0"
    }
    static func temp(_ v: Double?) -> String {
        guard let v, v > 0 else { return "—" }
        return String(format: "%.0f°", v)
    }
    static func rate(_ mbs: Double) -> (String, String) {
        if mbs >= 1 { return (dec(mbs), "MB/s") }
        return (String(format: "%.0f", mbs * 1024), "KB/s")
    }
    static func rpm(_ v: Int?) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v ?? 0)) ?? "0"
    }
    static func bytes(_ v: UInt64?) -> String { Bytes.mem(Int64(v ?? 0)) }
    static func pressure(_ raw: String?) -> String? {
        switch raw {
        case "warn": return "Pressão alta"
        case "critical": return "Pressão crítica"
        default: return nil
        }
    }
}

// MARK: - Peças visuais reutilizadas pelo Status e pelo Monitor

struct Chip: View {
    let text: String
    var strong = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: strong ? .semibold : .medium))
            .foregroundStyle(strong ? Palette.memory : Color(white: 0.8))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(strong ? Palette.memory.opacity(0.18) : Color.white.opacity(0.08)))
    }
}

struct BigValue: View {
    let value: String
    let unit: String
    var size: CGFloat = 40

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit)
                .font(.system(size: size * 0.36))
                .foregroundStyle(Theme.muted)
        }
    }
}

struct CoreBars: View {
    let values: [Double]
    var color: Color = Palette.cpu

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.prefix(16).enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.45 + min(v, 100) / 100 * 0.55))
                        .frame(height: max(3, geo.size.height * min(v, 100) / 100))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.4), value: values)
    }
}

struct Sparkline: View {
    let values: [Double]
    var fill = false
    var maxValue: Double? = nil
    var color: Color = Palette.network
    var secondary: [Double]? = nil
    var secondaryColor: Color = Palette.upload

    var body: some View {
        GeometryReader { geo in
            let pts = points(values, in: geo.size, top: scaleTop)
            ZStack {
                if fill, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                }
                if let secondary {
                    line(points(secondary, in: geo.size, top: scaleTop))
                        .stroke(secondaryColor.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
                line(pts)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var scaleTop: Double {
        max(maxValue ?? max(values.max() ?? 1, secondary?.max() ?? 0), 0.0001)
    }

    private func line(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
    }

    private func points(_ values: [Double], in size: CGSize, top: Double) -> [CGPoint] {
        let data = values.count == 1 ? values + values : values
        guard data.count > 1 else { return [] }
        return data.enumerated().map { i, v in
            CGPoint(
                x: size.width * CGFloat(i) / CGFloat(data.count - 1),
                y: size.height - size.height * CGFloat(min(v / top, 1)) * 0.9 - 1
            )
        }
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color? = nil
    var gradient: LinearGradient? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Group {
                    if let gradient {
                        Capsule().fill(gradient)
                    } else {
                        Capsule().fill(LinearGradient(colors: [(color ?? Palette.level(fraction)).opacity(0.75), color ?? Palette.level(fraction)], startPoint: .leading, endPoint: .trailing))
                    }
                }
                .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct HealthRing: View {
    let score: Int
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: size * 0.09)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(Palette.health(score), style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: score)
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
        }
        .frame(width: size, height: size)
    }
}

struct MetricCard<Content: View>: View {
    let title: String
    let symbol: String
    var badge: String? = nil
    var badgeStrong = false
    var compact = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                Text(compact ? title.capitalized : title)
                    .font(.system(size: compact ? 12 : 11.5, weight: .semibold))
                    .tracking(compact ? 0 : 0.8)
                Spacer(minLength: 4)
                if let badge { Chip(text: badge, strong: badgeStrong) }
            }
            .foregroundStyle(Color(white: 0.75))
            content
        }
        .padding(compact ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}

struct Footnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
    }
}

// MARK: - Tela Status

struct StatusView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.status

        Group {
            if let s = model.snapshot {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(s.activeAlerts) { alert in
                            AlertBanner(alert: alert)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                            healthCard(s)
                            cpuCard(s, model)
                            gpuCard(s, model)
                            memoryCard(s, model)
                            tempCard(s)
                            diskCard(s)
                            networkCard(s, model)
                            fanCard(s)
                            if let battery = s.batteries?.first { batteryCard(battery, s) }
                            if (s.trash_size ?? 0) > 0 { trashCard(s) }
                        }
                        ProcessListView()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                }
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text("Não foi possível ler o status").font(.title2)
                    Text(error).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BusyView(title: "Lendo o sistema…", subtitle: "")
            }
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    private let cardHeight: CGFloat = 230

    private func healthCard(_ s: StatusSnapshot) -> some View {
        MetricCard(title: "SAÚDE", symbol: "sun.max", badge: [s.hardware?.cpu_model, s.hardware?.total_ram].compactMap { $0 }.first) {
            HStack(spacing: 16) {
                HealthRing(score: s.health_score ?? 0, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.healthLabel).font(.system(size: 18, weight: .semibold))
                    if let msg = s.health_score_msg, !msg.isEmpty {
                        Text(msg).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Footnote(text: [s.hardware?.os_version, s.uptime.map { "ligado há \($0)" }].compactMap { $0 }.joined(separator: " · "))
        }
        .frame(height: cardHeight)
    }

    private func cpuCard(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        MetricCard(title: "CPU", symbol: "cpu", badge: s.thermal?.cpu_temp.map { String(format: "%.0f°C", $0) }) {
            BigValue(value: Fmt.pct(s.cpu?.usage), unit: "%")
            Spacer(minLength: 0)
            CoreBars(values: s.cpu?.per_core ?? m.cpuHistory, color: Palette.cpu).frame(height: 34)
            Footnote(text: "\(s.cpu?.logical_cpu ?? 0) núcleos · carga média \(Fmt.dec(s.cpu?.load1))")
        }
        .frame(height: cardHeight)
    }

    private func gpuCard(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        MetricCard(title: "GPU", symbol: "square.stack.3d.up", badge: s.thermal?.gpu_temp.flatMap { $0 > 0 ? String(format: "%.0f°C", $0) : nil }) {
            BigValue(value: Fmt.pct(s.gpuUsage), unit: "%")
            Spacer(minLength: 0)
            Sparkline(values: m.gpuHistory, fill: true, maxValue: 100, color: Palette.gpu).frame(height: 34)
            Footnote(text: s.gpuUsage == nil ? "sem leitura de uso" : (s.gpuUsage ?? 0) < 5 ? "ociosa" : (s.gpu?.first?.name ?? "em uso"))
        }
        .frame(height: cardHeight)
    }

    private func memoryCard(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        let pressure = Fmt.pressure(s.memory?.pressure)
        return MetricCard(title: "MEMÓRIA", symbol: "memorychip", badge: pressure, badgeStrong: pressure != nil) {
            BigValue(value: Fmt.pct(s.memory?.used_percent), unit: "%")
            Spacer(minLength: 0)
            Sparkline(values: m.memHistory, fill: true, maxValue: 100, color: Palette.memory).frame(height: 34)
            Footnote(text: "\(Fmt.bytes(s.memory?.used)) · \(Fmt.bytes(s.memory?.swap_used)) de swap")
        }
        .frame(height: cardHeight)
    }

    private func tempCard(_ s: StatusSnapshot) -> some View {
        let cpu = s.thermal?.cpu_temp ?? 0
        return MetricCard(title: "TEMPERATURA", symbol: "thermometer.medium", badge: cpu > 90 ? "Alta" : "Normal", badgeStrong: cpu > 90) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                BigValue(value: Fmt.temp(s.thermal?.cpu_temp), unit: "CPU")
                if (s.thermal?.gpu_temp ?? 0) > 0 {
                    BigValue(value: Fmt.temp(s.thermal?.gpu_temp), unit: "GPU")
                }
            }
            Spacer(minLength: 0)
            Meter(fraction: cpu / 110, gradient: Palette.temperature)
            Footnote(text: (s.sensors ?? []).prefix(3).compactMap { sensor in
                sensor.value.map { "\(sensor.label) \(String(format: "%.0f", $0))\(sensor.unit ?? "")" }
            }.joined(separator: " · ").nilIfEmpty ?? (s.hardware?.cpu_model ?? "Sensores do chip"))
        }
        .frame(height: cardHeight)
    }

    private func diskCard(_ s: StatusSnapshot) -> some View {
        let d = s.mainDisk
        let free = Int64(d?.total ?? 0) - Int64(d?.used ?? 0)
        let parts = Bytes.split(max(free, 0))
        return MetricCard(title: "ESPAÇO LIVRE", symbol: "internaldrive", badge: Bytes.str(Int64(d?.total ?? 0))) {
            BigValue(value: parts.number, unit: parts.unit)
            Spacer(minLength: 0)
            Meter(fraction: (d?.used_percent ?? 0) / 100, color: Palette.disk)
            Footnote(text: "Leitura \(Fmt.dec(s.disk_io?.read_rate)) MB/s · gravação \(Fmt.dec(s.disk_io?.write_rate)) MB/s")
        }
        .frame(height: cardHeight)
    }

    private func networkCard(_ s: StatusSnapshot, _ m: StatusModel) -> some View {
        let rx = Fmt.rate(s.rxMBs)
        let tx = Fmt.rate(s.txMBs)
        return MetricCard(title: "REDE", symbol: "globe", badge: s.primaryInterface) {
            BigValue(value: rx.0, unit: rx.1)
            Spacer(minLength: 0)
            Sparkline(values: m.rxHistory, color: Palette.network, secondary: m.txHistory).frame(height: 34)
            Footnote(text: "Envio \(tx.0) \(tx.1)" + ((s.proxy?.enabled == true) ? " · proxy \(s.proxy?.type ?? "")" : ""))
        }
        .frame(height: cardHeight)
    }

    private func batteryCard(_ b: StatusSnapshot.Battery, _ s: StatusSnapshot) -> some View {
        let pct = b.percent ?? 0
        return MetricCard(title: "BATERIA", symbol: "battery.75percent", badge: b.health, badgeStrong: (b.health ?? "Normal") != "Normal" && b.health != "Good") {
            BigValue(value: Fmt.pct(pct), unit: "%")
            Spacer(minLength: 0)
            Meter(fraction: pct / 100, color: pct <= 20 ? Palette.hot : Palette.cpu)
            Footnote(text: [b.status, b.time_left, b.cycle_count.map { "\($0) ciclos" }, b.capacity.map { "capacidade \($0)%" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        }
        .frame(height: cardHeight)
    }

    private func trashCard(_ s: StatusSnapshot) -> some View {
        MetricCard(title: "LIXO", symbol: "trash", badge: nil) {
            let parts = Bytes.split(Int64(s.trash_size ?? 0))
            BigValue(value: parts.number, unit: parts.unit)
            Spacer(minLength: 0)
            Button("Esvaziar Lixo…") {
                let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
                script?.executeAndReturnError(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentLight)
            Footnote(text: "Itens que o Limpo e você moveram para o Lixo")
        }
        .frame(height: cardHeight)
    }

    private func fanCard(_ s: StatusSnapshot) -> some View {
        let count = s.thermal?.fan_count ?? 0
        return MetricCard(title: "VENTOINHA", symbol: "fanblades", badge: count > 0 ? "\(count) ventoinha\(count > 1 ? "s" : "")" : nil) {
            if count > 0 {
                BigValue(value: Fmt.rpm(s.thermal?.fan_speed), unit: "RPM")
            } else {
                BigValue(value: "—", unit: "")
            }
            Spacer(minLength: 0)
            Footnote(text: "Controlada pelo macOS" + ((s.thermal?.system_power ?? 0) > 0 ? " · \(Fmt.dec(s.thermal?.system_power)) W" : ""))
        }
        .frame(height: cardHeight)
    }
}

// MARK: - Tabela de processos

struct ProcessTable: View {
    let processes: [StatusSnapshot.Proc]
    let total: UInt64?

    var body: some View {
        VStack(spacing: 0) {
            row(name: Text("NOME" + (total.map { " (\($0))" } ?? "")), mem: Text("MEM"), cpu: AnyView(Text("% CPU")), pid: Text("PID"), header: true)
            Divider().overlay(Theme.hairline)
            ForEach(processes.prefix(10)) { p in
                row(
                    name: Text(p.name ?? "PID \(p.pid)"),
                    mem: Text(memText(p)),
                    cpu: AnyView(
                        HStack(spacing: 12) {
                            Meter(fraction: (p.cpu ?? 0) / 100).frame(width: 80)
                            Text(Fmt.dec(p.cpu)).frame(width: 44, alignment: .trailing)
                        }
                    ),
                    pid: Text("\(p.pid)"),
                    header: false,
                    icon: NSRunningApplication(processIdentifier: pid_t(p.pid))?.icon
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func memText(_ p: StatusSnapshot.Proc) -> String {
        if let b = p.memory_bytes, b > 0 { return Bytes.str(Int64(b)) }
        return "\(Fmt.dec(p.memory))%"
    }

    private func row(name: Text, mem: Text, cpu: AnyView, pid: Text, header: Bool, icon: NSImage? = nil) -> some View {
        HStack(spacing: 12) {
            if !header {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(white: 0.4), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .frame(width: 24, height: 24)
            }
            name.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            mem.frame(width: 100, alignment: .trailing).foregroundStyle(header ? Theme.muted : Color(white: 0.8))
            cpu.frame(width: 190, alignment: .trailing)
            pid.frame(width: 70, alignment: .trailing).foregroundStyle(Color(white: header ? 0.58 : 0.5))
        }
        .font(header ? .system(size: 11.5, weight: .semibold) : .system(size: 14))
        .foregroundStyle(header ? Theme.muted : Theme.text)
        .padding(.horizontal, 20)
        .padding(.vertical, header ? 12 : 9)
    }
}


extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct AlertBanner: View {
    let alert: StatusSnapshot.Alert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "flame.fill").foregroundStyle(Palette.warm)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.name ?? "PID \(alert.pid)") está usando \(Fmt.dec(alert.cpu))% de CPU")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Acima de \(Fmt.dec(alert.threshold))% há mais de \(alert.window ?? "alguns minutos") · PID \(alert.pid)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Encerrar…") {
                let p = AppStore.shared.processes
                if let row = p.all.first(where: { Int($0.pid) == alert.pid }) {
                    p.actionOrigin = "window"
                    p.pendingKill = ProcessGroup(single: row)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.warm.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warm.opacity(0.35), lineWidth: 1))
    }
}
