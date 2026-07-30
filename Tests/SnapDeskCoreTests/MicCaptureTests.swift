import Testing
import AVFoundation
@testable import SnapDeskCore

/// The noise-cancelling mic path converts Apple's processed PCM buffers into
/// CMSampleBuffers for the asset writer. A wrong format description or a lost
/// timestamp doesn't fail loudly — it silently desyncs or mutes the voice track,
/// so this conversion is checked directly. No microphone (and no permission
/// prompt) is involved: the input is a synthetic buffer.
struct MicSampleBufferConversion {
    /// 48 kHz mono Int16 interleaved — exactly what the production path targets.
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                       channels: 1, interleaved: true)!

    /// A tone in the same shape an input-node tap delivers, converted the same way.
    private func processedBuffer(frames: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let tapFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frames))
        source.frameLength = frames
        for channel in 0..<2 {
            let samples = try #require(source.floatChannelData)[channel]
            for i in 0..<Int(frames) { samples[i] = sinf(Float(i) * 0.05) * 0.5 }
        }
        let converter = try #require(AVAudioConverter(from: tapFormat, to: target))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames + 64))
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        #expect(error == nil)
        return out
    }

    @Test func buildsASampleBufferWithTheRightShape() throws {
        let pcm = try processedBuffer()
        let host = CMClockMakeHostTimeFromSystemUnits(mach_absolute_time())
        let sb = try #require(MicCapture.sampleBuffer(from: pcm, at: host))

        #expect(CMSampleBufferDataIsReady(sb))
        #expect(CMSampleBufferGetNumSamples(sb) == CMItemCount(pcm.frameLength))
        #expect(CMSampleBufferGetPresentationTimeStamp(sb) == host,
                "a lost or rewritten PTS desyncs voice from picture")
    }

    @Test func attachesTheActualAudioBytes() throws {
        let pcm = try processedBuffer()
        let sb = try #require(MicCapture.sampleBuffer(from: pcm, at: .zero))
        let block = try #require(CMSampleBufferGetDataBuffer(sb))
        // Int16 mono → 2 bytes per frame.
        #expect(CMBlockBufferGetDataLength(block) == Int(pcm.frameLength) * 2)
    }

    @Test("The format description says 48 kHz mono, which is what the AAC input expects")
    func describesTheFormat() throws {
        let pcm = try processedBuffer()
        let sb = try #require(MicCapture.sampleBuffer(from: pcm, at: .zero))
        let fd = try #require(CMSampleBufferGetFormatDescription(sb))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(fd))
        #expect(asbd.pointee.mSampleRate == 48_000)
        #expect(asbd.pointee.mChannelsPerFrame == 1)
    }

    @Test("One constant-bitrate size entry is stated, so no writer has to infer it")
    func statesSampleSize() throws {
        let pcm = try processedBuffer()
        let sb = try #require(MicCapture.sampleBuffer(from: pcm, at: .zero))
        var sizes = [Int](repeating: 0, count: 4)
        var needed: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sb, entryCount: 4, arrayToFill: &sizes,
                                         entriesNeededOut: &needed)
        #expect(needed == 1)
        #expect(sizes[0] == 2)
        #expect(CMSampleBufferGetTotalSampleSize(sb) == Int(pcm.frameLength) * 2)
    }

    @Test("Buffer sizes other than the default still convert cleanly",
          arguments: [AVAudioFrameCount(256), 512, 1024, 4096])
    func handlesVariousBufferSizes(_ frames: AVAudioFrameCount) throws {
        let pcm = try processedBuffer(frames: frames)
        let sb = try #require(MicCapture.sampleBuffer(from: pcm, at: .zero))
        #expect(CMSampleBufferGetNumSamples(sb) == CMItemCount(pcm.frameLength))
    }
}
