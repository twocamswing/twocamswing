import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - H.264 Hardware Encoder

final class HardwareH264Encoder {
    private var compressionSession: VTCompressionSession?
    private let encodeQueue = DispatchQueue(label: "com.golfswingrtc.h264encoder", qos: .userInteractive)

    var onEncodedFrame: ((Data, Bool) -> Void)?  // (nalData, isKeyframe)

    private var width: Int32 = 0
    private var height: Int32 = 0
    private var frameCount: Int64 = 0
    private let targetBitrate: Int = 2_000_000  // 2 Mbps
    private let keyframeInterval: Int = 30  // Keyframe every 30 frames

    func configure(width: Int32, height: Int32) {
        self.width = width
        self.height = height

        // Tear down existing session
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("HW Encoder: Failed to create compression session: \(status)")
            return
        }

        // Configure session for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
        frameCount = 0
        print("HW Encoder: Configured for \(width)x\(height) @ \(targetBitrate/1_000_000)Mbps")
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session = compressionSession else { return }

        frameCount += 1

        // Force keyframe periodically
        var properties: [String: Any]? = nil
        if frameCount % Int64(keyframeInterval) == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }

        encodeQueue.async { [weak self] in
            var infoFlags = VTEncodeInfoFlags()

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: timestamp,
                duration: .invalid,
                frameProperties: properties as CFDictionary?,
                sourceFrameRefcon: nil,
                infoFlagsOut: &infoFlags
            )

            if status != noErr {
                print("HW Encoder: Encode failed: \(status)")
                return
            }

            // Get encoded frame synchronously
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    func encodeSync(pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> (Data, Bool)? {
        guard let session = compressionSession else { return nil }

        frameCount += 1

        // Force keyframe periodically
        var properties: [String: Any]? = nil
        if frameCount % Int64(keyframeInterval) == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }

        var result: (Data, Bool)? = nil
        let semaphore = DispatchSemaphore(value: 0)

        let callback: VTCompressionOutputCallback = { refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer in
            defer {
                if let semPtr = refcon {
                    let sem = Unmanaged<DispatchSemaphore>.fromOpaque(semPtr).takeUnretainedValue()
                    sem.signal()
                }
            }

            guard status == noErr, let sampleBuffer = sampleBuffer else { return }

            // Check if keyframe
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

            // Get NAL data
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let pointer = dataPointer else { return }

            // Convert AVCC format to Annex-B format for streaming
            var nalData = Data()
            let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

            // If keyframe, prepend SPS/PPS
            if isKeyframe {
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    // Get SPS
                    var spsSize = 0
                    var spsCount = 0
                    var spsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)
                    if let sps = spsPointer {
                        nalData.append(contentsOf: startCode)
                        nalData.append(sps, count: spsSize)
                    }

                    // Get PPS
                    var ppsSize = 0
                    var ppsPointer: UnsafePointer<UInt8>?
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if let pps = ppsPointer {
                        nalData.append(contentsOf: startCode)
                        nalData.append(pps, count: ppsSize)
                    }
                }
            }

            // Parse AVCC NAL units and convert to Annex-B
            var offset = 0
            while offset < length - 4 {
                // Read NAL unit length (4 bytes, big-endian)
                var nalLength: UInt32 = 0
                memcpy(&nalLength, pointer.advanced(by: offset), 4)
                nalLength = CFSwapInt32BigToHost(nalLength)
                offset += 4

                if offset + Int(nalLength) <= length {
                    nalData.append(contentsOf: startCode)
                    nalData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
                    offset += Int(nalLength)
                } else {
                    break
                }
            }

            // Store result in the refcon's associated result variable
            // We'll use a different approach - callback-based
        }

        // Use a simpler synchronous approach with callback
        var outputData = Data()
        var outputIsKeyframe = false

        let outputCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void = { refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }

            // Extract to a thread-local or use a different pattern
        }

        // Actually, let's use a simpler pattern with VTCompressionSessionEncodeFrame with outputHandler
        var infoFlags = VTEncodeInfoFlags()

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, infoFlags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else {
                semaphore.signal()
                return
            }

            result = self?.extractNALData(from: sampleBuffer)
            semaphore.signal()
        }

        if status != noErr {
            print("HW Encoder: Encode failed: \(status)")
            return nil
        }

        // Wait for encoding to complete (should be very fast with hardware)
        _ = semaphore.wait(timeout: .now() + 0.1)

        return result
    }

    private func extractNALData(from sampleBuffer: CMSampleBuffer) -> (Data, Bool) {
        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        var nalData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // If keyframe, prepend SPS/PPS
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Get SPS
            var spsSize = 0
            var spsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let sps = spsPointer {
                nalData.append(contentsOf: startCode)
                nalData.append(sps, count: spsSize)
            }

            // Get PPS
            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
               let pps = ppsPointer {
                nalData.append(contentsOf: startCode)
                nalData.append(pps, count: ppsSize)
            }
        }

        // Get NAL data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return (nalData, isKeyframe)
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else {
            return (nalData, isKeyframe)
        }

        // Parse AVCC NAL units and convert to Annex-B
        var offset = 0
        while offset < length - 4 {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer.advanced(by: offset), 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4

            if offset + Int(nalLength) <= length {
                nalData.append(contentsOf: startCode)
                nalData.append(Data(bytes: pointer.advanced(by: offset), count: Int(nalLength)))
                offset += Int(nalLength)
            } else {
                break
            }
        }

        return (nalData, isKeyframe)
    }

    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    deinit {
        invalidate()
    }
}

// MARK: - H.264 Hardware Decoder

final class HardwareH264Decoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let decodeQueue = DispatchQueue(label: "com.golfswingrtc.h264decoder", qos: .userInteractive)

    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    private var spsData: Data?
    private var ppsData: Data?

    func decode(nalData: Data) {
        decodeQueue.async { [weak self] in
            self?.processNALData(nalData)
        }
    }

    private func processNALData(_ data: Data) {
        // Parse Annex-B NAL units
        let startCode3: [UInt8] = [0x00, 0x00, 0x01]
        let startCode4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        var nalUnits: [(type: UInt8, data: Data)] = []
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            // Find start code
            var startCodeLength = 0
            if offset + 4 <= bytes.count && Array(bytes[offset..<offset+4]) == startCode4 {
                startCodeLength = 4
            } else if offset + 3 <= bytes.count && Array(bytes[offset..<offset+3]) == startCode3 {
                startCodeLength = 3
            } else {
                offset += 1
                continue
            }

            let nalStart = offset + startCodeLength

            // Find next start code or end
            var nalEnd = bytes.count
            for i in nalStart..<bytes.count-3 {
                if Array(bytes[i..<i+3]) == startCode3 || (i + 4 <= bytes.count && Array(bytes[i..<i+4]) == startCode4) {
                    nalEnd = i
                    break
                }
            }

            if nalStart < nalEnd {
                let nalType = bytes[nalStart] & 0x1F
                let nalData = Data(bytes[nalStart..<nalEnd])
                nalUnits.append((nalType, nalData))
            }

            offset = nalEnd
        }

        // Process NAL units
        for nal in nalUnits {
            switch nal.type {
            case 7: // SPS
                spsData = nal.data
                tryCreateDecompressionSession()
            case 8: // PPS
                ppsData = nal.data
                tryCreateDecompressionSession()
            case 5, 1: // IDR or non-IDR slice
                decodeSlice(nal.data)
            default:
                break
            }
        }
    }

    private func tryCreateDecompressionSession() {
        guard let sps = spsData, let pps = ppsData, decompressionSession == nil else { return }

        let spsPointer = [UInt8](sps)
        let ppsPointer = [UInt8](pps)

        let parameterSets: [UnsafePointer<UInt8>] = spsPointer.withUnsafeBufferPointer { spsBuffer in
            ppsPointer.withUnsafeBufferPointer { ppsBuffer in
                [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
            }
        }
        let parameterSetSizes: [Int] = [sps.count, pps.count]

        var formatDesc: CMVideoFormatDescription?

        spsPointer.withUnsafeBufferPointer { spsBuffer in
            ppsPointer.withUnsafeBufferPointer { ppsBuffer in
                let pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                pointers.withUnsafeBufferPointer { pointersBuffer in
                    parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        guard let desc = formatDesc else {
            print("HW Decoder: Failed to create format description")
            return
        }

        formatDescription = desc

        // Create decompression session
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        print("HW Decoder: Creating session for \(dimensions.width)x\(dimensions.height)")

        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dimensions.width,
            kCVPixelBufferHeightKey as String: dimensions.height
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if status == noErr {
            decompressionSession = session
            print("HW Decoder: Session created successfully")
        } else {
            print("HW Decoder: Failed to create session: \(status)")
        }
    }

    private func decodeSlice(_ nalData: Data) {
        guard let session = decompressionSession, let formatDesc = formatDescription else { return }

        // Convert to AVCC format (prepend 4-byte length)
        var avccData = Data()
        var length = UInt32(nalData.count).bigEndian
        avccData.append(Data(bytes: &length, count: 4))
        avccData.append(nalData)

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        avccData.withUnsafeBytes { rawBuffer in
            let pointer = rawBuffer.baseAddress!
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: pointer),
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let buffer = blockBuffer else { return }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avccData.count

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else { return }

        // Decode
        var infoFlags = VTDecodeInfoFlags()
        _ = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, flags, imageBuffer, pts, duration in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }

            DispatchQueue.main.async {
                self?.onDecodedFrame?(pixelBuffer)
            }
        }
    }

    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        spsData = nil
        ppsData = nil
    }

    deinit {
        invalidate()
    }
}
