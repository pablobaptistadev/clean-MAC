import AVFoundation
import ScreenCaptureKit
import VideoToolbox

// MARK: - Gravação de vídeo leve: HEVC, no máximo 1080p, 30 fps e quadros só quando a tela muda

enum VideoFormat {
    static let fps: Int32 = 30
    /// Maior caixa de saída (deitada); vídeos em pé usam a mesma caixa virada.
    static let maxSize = CGSize(width: 1920, height: 1080)
    /// Menor lado aceito pelo codificador; áreas menores são ampliadas.
    static let minSide = 64
    /// Bits por pixel por quadro. Tela tem muito texto parado: 0,03 dá ~1,9 Mbps em 1080p e o arquivo fica bem menor que isso.
    static let bitsPerPixel = 0.03

    /// Tamanho do vídeo em pixels para uma área em pontos: resolução real, reduzida para caber em Full HD, sempre par.
    static func outputSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = points.width * scale, h = points.height * scale
        let box = w >= h ? maxSize : CGSize(width: maxSize.height, height: maxSize.width)
        var factor = min(1, box.width / w, box.height / h)
        let shortest = min(w, h) * factor
        if shortest < CGFloat(minSide) { factor *= CGFloat(minSide) / shortest }
        func even(_ v: CGFloat) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w * factor), even(h * factor))
    }

    static func bitRate(width: Int, height: Int) -> Int {
        max(300_000, Int(Double(width * height) * Double(fps) * bitsPerPixel))
    }

    /// Escritor MP4 em HEVC (H.264 se o Mac não codificar HEVC). `fast start` para abrir na hora na web e no WhatsApp.
    static func makeWriter(url: URL, width: Int, height: Int) throws -> (AVAssetWriter, AVAssetWriterInputPixelBufferAdaptor) {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let rate = bitRate(width: width, height: height)
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: color,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 5,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ] as [String: Any]
        ]
        var settings = hevc
        if !writer.canApply(outputSettings: hevc, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: rate * 3 / 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 5,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.encoder }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.encoder }
        return (writer, adaptor)
    }
}

enum RecorderError: LocalizedError {
    case display, encoder, empty

    var errorDescription: String? {
        switch self {
        case .display: return "A tela escolhida não está mais disponível."
        case .encoder: return "O Mac não conseguiu preparar o codificador de vídeo."
        case .empty: return "Nenhum quadro foi gravado."
        }
    }
}

/// Liga o ScreenCaptureKit ao escritor. Os quadros chegam numa fila própria; o estado só muda nela.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    /// Chamado (fora da thread principal) se o macOS interromper a gravação.
    var onInterrupt: (@Sendable (Error) -> Void)?

    private let writer: AVAssetWriter
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "br.com.pablobaptista.printscreen.recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var started = false
    private var finished = false
    private var lastTime = CMTime.zero

    /// `rect` em pontos da tela, com origem no canto de cima; nil grava a tela inteira.
    init(display: SCDisplay, scale: CGFloat, rect: CGRect?, excluding app: SCRunningApplication?, url: URL) throws {
        let area = rect ?? CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let size = VideoFormat.outputSize(points: area.size, scale: scale)
        self.url = url
        width = size.width
        height = size.height
        (writer, adaptor) = try VideoFormat.makeWriter(url: url, width: size.width, height: size.height)
        super.init()

        let config = SCStreamConfiguration()
        if rect != nil { config.sourceRect = area }
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: VideoFormat.fps)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.captureResolution = .best
        config.queueDepth = 6
        // As janelas do próprio PrintScreen (contorno, cronômetro, ícone da barra) não entram no vídeo.
        let filter = SCContentFilter(display: display, excludingApplications: app.map { [$0] } ?? [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
    }

    func start() async throws {
        do {
            try await stream?.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Para e fecha o arquivo. Devolve o vídeo salvo, ou o erro.
    func stop() async -> Result<URL, Error> {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async { self.finish { continuation.resume(returning: $0) } }
        }
    }

    private func finish(_ done: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard !finished else { return done(.failure(RecorderError.empty)) }
        finished = true
        guard started, writer.status == .writing else {
            let error = writer.error ?? RecorderError.empty
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return done(.failure(error))
        }
        // A tela parada não gera quadros: estica o último até o momento em que a gravação parou.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        adaptor.assetWriterInput.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(now, lastTime))
        let writer = self.writer, url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                done(.success(url))
            } else {
                try? FileManager.default.removeItem(at: url)
                done(.failure(writer.error ?? RecorderError.encoder))
            }
        }
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !finished, sample.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp
        if !started {
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard time > lastTime || lastTime == .zero, adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        if adaptor.append(pixels, withPresentationTime: time) { lastTime = time }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupt?(error)
    }
}
