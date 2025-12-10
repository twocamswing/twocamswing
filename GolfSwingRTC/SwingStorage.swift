import UIKit
import AVFoundation

struct LineData: Codable {
    /// Normalized coordinates (0.0-1.0 range relative to view size)
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat

    /// Create from absolute coordinates - normalizes to 0.0-1.0 range
    init(start: CGPoint, end: CGPoint, viewSize: CGSize) {
        self.startX = start.x / viewSize.width
        self.startY = start.y / viewSize.height
        self.endX = end.x / viewSize.width
        self.endY = end.y / viewSize.height
    }

    /// Get absolute start point scaled to given view size
    func start(in size: CGSize) -> CGPoint {
        CGPoint(x: startX * size.width, y: startY * size.height)
    }

    /// Get absolute end point scaled to given view size
    func end(in size: CGSize) -> CGPoint {
        CGPoint(x: endX * size.width, y: endY * size.height)
    }
}

struct SavedSwing: Codable {
    let id: UUID
    let date: Date
    let remoteVideoFilename: String
    let frontVideoFilename: String?
    let thumbnailFilename: String
    let frameCount: Int
    let duration: TimeInterval
    let remoteLine: LineData?
    let frontLine: LineData?
}

final class SwingStorage {
    static let shared = SwingStorage()

    private let fileManager = FileManager.default
    private let swingsDirectoryName = "Swings"
    private let manifestFilename = "swings.json"

    private var swingsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(swingsDirectoryName)
    }

    private var manifestURL: URL {
        swingsDirectory.appendingPathComponent(manifestFilename)
    }

    private init() {
        createSwingsDirectoryIfNeeded()
    }

    private func createSwingsDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: swingsDirectory.path) {
            try? fileManager.createDirectory(at: swingsDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Public API

    /// Saves a swing recording from the replay buffer frames.
    /// Frames are used at their existing size - no resizing performed.
    func saveSwing(
        remoteFrames: [UIImage],
        frontFrames: [UIImage]?,
        remoteLine: LineData? = nil,
        frontLine: LineData? = nil,
        completion: @escaping (Result<SavedSwing, Error>) -> Void
    ) {
        guard !remoteFrames.isEmpty else {
            completion(.failure(SwingStorageError.noFrames))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let swingId = UUID()
                let dateString = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")

                // Create video from remote frames
                let remoteFilename = "remote_\(dateString).mp4"
                let remoteURL = self.swingsDirectory.appendingPathComponent(remoteFilename)
                try self.createVideo(from: remoteFrames, outputURL: remoteURL)

                // Create video from front frames if available
                var frontFilename: String? = nil
                if let frontFrames = frontFrames, !frontFrames.isEmpty {
                    let filename = "front_\(dateString).mp4"
                    let frontURL = self.swingsDirectory.appendingPathComponent(filename)
                    try self.createVideo(from: frontFrames, outputURL: frontURL)
                    frontFilename = filename
                }

                // Generate thumbnail from first remote frame
                let thumbnailFilename = "thumb_\(dateString).jpg"
                let thumbnailURL = self.swingsDirectory.appendingPathComponent(thumbnailFilename)
                if let firstFrame = remoteFrames.first {
                    self.saveThumbnail(firstFrame, to: thumbnailURL)
                }

                // Estimate duration (30fps assumed)
                let duration = Double(remoteFrames.count) / 30.0

                let swing = SavedSwing(
                    id: swingId,
                    date: Date(),
                    remoteVideoFilename: remoteFilename,
                    frontVideoFilename: frontFilename,
                    thumbnailFilename: thumbnailFilename,
                    frameCount: remoteFrames.count,
                    duration: duration,
                    remoteLine: remoteLine,
                    frontLine: frontLine
                )

                // Add to manifest
                var swings = self.loadSwingsListInternal()
                swings.insert(swing, at: 0)  // Most recent first
                self.saveManifest(swings)

                DispatchQueue.main.async {
                    completion(.success(swing))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func loadSwingsList() -> [SavedSwing] {
        return loadSwingsListInternal()
    }

    func deleteSwing(_ swing: SavedSwing) {
        // Delete video files
        let remoteURL = swingsDirectory.appendingPathComponent(swing.remoteVideoFilename)
        try? fileManager.removeItem(at: remoteURL)

        if let frontFilename = swing.frontVideoFilename {
            let frontURL = swingsDirectory.appendingPathComponent(frontFilename)
            try? fileManager.removeItem(at: frontURL)
        }

        let thumbnailURL = swingsDirectory.appendingPathComponent(swing.thumbnailFilename)
        try? fileManager.removeItem(at: thumbnailURL)

        // Update manifest
        var swings = loadSwingsListInternal()
        swings.removeAll { $0.id == swing.id }
        saveManifest(swings)
    }

    func getVideoURL(for swing: SavedSwing, front: Bool = false) -> URL? {
        if front {
            guard let frontFilename = swing.frontVideoFilename else { return nil }
            return swingsDirectory.appendingPathComponent(frontFilename)
        }
        return swingsDirectory.appendingPathComponent(swing.remoteVideoFilename)
    }

    func getThumbnail(for swing: SavedSwing) -> UIImage? {
        let url = swingsDirectory.appendingPathComponent(swing.thumbnailFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Private Helpers

    private func loadSwingsListInternal() -> [SavedSwing] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder().decode([SavedSwing].self, from: data)) ?? []
    }

    private func saveManifest(_ swings: [SavedSwing]) {
        guard let data = try? JSONEncoder().encode(swings) else { return }
        try? data.write(to: manifestURL)
    }

    private func saveThumbnail(_ image: UIImage, to url: URL) {
        // Scale down for thumbnail
        let maxSize: CGFloat = 200
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        if let data = thumbnail?.jpegData(compressionQuality: 0.7) {
            try? data.write(to: url)
        }
    }

    /// Creates an MP4 video from UIImage frames at 30fps.
    /// Uses the frames at their existing size - no resizing.
    private func createVideo(from frames: [UIImage], outputURL: URL) throws {
        guard let firstFrame = frames.first, let cgImage = firstFrame.cgImage else {
            throw SwingStorageError.invalidFrame
        }

        // Use the first frame's size as the video size
        let videoSize = CGSize(width: cgImage.width, height: cgImage.height)

        // Remove existing file if present
        try? fileManager.removeItem(at: outputURL)

        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw SwingStorageError.cannotAddInput
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw writer.error ?? SwingStorageError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        // Write frames at 30fps
        let frameDuration = CMTime(value: 1, timescale: 30)

        for (index, frame) in frames.enumerated() {
            autoreleasepool {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                if let pixelBuffer = self.pixelBuffer(from: frame, size: videoSize) {
                    let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                    adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                }
            }
        }

        writerInput.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status == .failed {
            throw writer.error ?? SwingStorageError.writerFailed
        }
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }

        return buffer
    }
}

// MARK: - Errors

enum SwingStorageError: LocalizedError {
    case noFrames
    case invalidFrame
    case cannotAddInput
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames to save"
        case .invalidFrame: return "Invalid frame format"
        case .cannotAddInput: return "Cannot add video input"
        case .writerFailed: return "Video writer failed"
        }
    }
}
