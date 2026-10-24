import Foundation

enum MoleError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Mole CLI não encontrado. Instale com: brew install mole"
        case .failed(let msg): return msg
        }
    }
}

enum MoleCLI {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]

    static func locate() -> String? {
        for dir in searchPaths {
            let path = dir + "/mo"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func environment(tty: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["NO_COLOR"] = "1"
        if UserDefaults.standard.bool(forKey: "noOplog") { env["MO_NO_OPLOG"] = "1" }
        env["TERM"] = tty ? "xterm-256color" : "dumb"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Executa `mo <args>` sem terminal e devolve a saída completa.
    static func run(_ args: [String], mergeStderr: Bool = false) async throws -> (output: String, status: Int32) {
        guard let mo = locate() else { throw MoleError.notFound }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: mo)
            process.arguments = args
            process.environment = environment(tty: false)
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            process.standardOutput = out
            process.standardError = mergeStderr ? out : FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), process.terminationStatus)
        }.value
    }
}

/// Roda o `mo` dentro de um pseudo-terminal (via /usr/bin/script), necessário
/// para o fluxo de desinstalação, que só aceita confirmação de um terminal real.
final class PTYSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    var onText: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    func start(mo: String, args: [String]) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", mo] + args
        process.environment = MoleCLI.environment(tty: true)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onText?(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] proc in
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(proc.terminationStatus)
        }
        try process.run()
    }

    func send(_ text: String) {
        guard process.isRunning else { return }
        input.fileHandleForWriting.write(Data(text.utf8))
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Utilitários de texto

enum ANSI {
    private static let regex = try! NSRegularExpression(
        pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])"
    )

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let noEscapes = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return noEscapes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                // Spinners reescrevem a linha com \r: fica só o último trecho com conteúdo.
                line.components(separatedBy: "\r")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            }
            .joined(separator: "\n")
    }
}

enum Sizes {
    private static let regex = try! NSRegularExpression(pattern: #"([0-9]+(?:[.,][0-9]+)?)\s*(TB|GB|MB|KB|B)\b"#)
    private static let multipliers: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]

    /// Converte o último tamanho encontrado no texto ("2 items, 1.2GB") em bytes.
    static func parse(_ text: String) -> Int64 {
        let ns = text as NSString
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return 0 }
        let number = Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")) ?? 0
        let unit = ns.substring(with: match.range(at: 2))
        return Int64(number * (multipliers[unit] ?? 1))
    }
}

extension String {
    /// Corta qualquer lixo antes do primeiro `{` ou `[` (avisos que o CLI imprime antes do JSON).
    func jsonPayload(startingWith char: Character) -> Data? {
        guard let start = firstIndex(of: char) else { return nil }
        return Data(self[start...].utf8)
    }
}

// MARK: - Execução com saída ao vivo

extension MoleCLI {
    /// Executa `mo <args>` sem terminal, entregando a saída aos poucos.
    static func stream(_ args: [String], onText: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        guard let mo = locate() else { throw MoleError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: mo)
            process.arguments = args
            process.environment = environment(tty: false)
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { onText(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                if let rest = try? out.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    onText(String(decoding: rest, as: UTF8.self))
                }
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Leitura genérica da saída do Mole (➤ seção / ✓ → ◎ itens)

struct OutputLine: Identifiable, Hashable {
    enum Kind { case done, preview, skipped, warning, error, info }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct OutputSection: Identifiable {
    var id: String { title }
    let title: String
    var lines: [OutputLine]
}

enum OutputParser {
    static func parse(_ raw: String) -> (sections: [OutputSection], summary: [String]) {
        var sections: [OutputSection] = []
        var summary: [String] = []
        var current: String?
        var inSummary = false

        for rawLine in ANSI.strip(raw).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("====") {
                inSummary.toggle()
                continue
            }
            if inSummary {
                summary.append(line)
                continue
            }
            if line.hasPrefix("➤") {
                current = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let current, !sections.contains(where: { $0.title == current }) {
                    sections.append(OutputSection(title: current, lines: []))
                }
                continue
            }
            guard let current, let first = line.first else { continue }
            let kind: OutputLine.Kind
            switch first {
            case "✓": kind = .done
            case "→": kind = .preview
            case "◎": kind = .skipped
            case "⚠", "!": kind = .warning
            case "✗", "✘", "×": kind = .error
            case "•", "-": kind = .info
            default: continue
            }
            var text = line.dropFirst().trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(" dry") { text = String(text.dropLast(4)) }
            if let index = sections.firstIndex(where: { $0.title == current }) {
                sections[index].lines.append(OutputLine(kind: kind, text: text))
            }
        }
        return (sections.filter { !$0.lines.isEmpty }, summary)
    }
}
