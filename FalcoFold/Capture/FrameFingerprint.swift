import Metal
import os

/// Tells whether a captured frame has the same pixels as the one before, without reading it back in full:
/// a compute kernel sums every pixel into a grid of 64×64-pixel cell totals, so a change anywhere alters a total.
///
/// Needed because the overlay's own redraw counts as a screen change: without this, every draw would come
/// back as a "new" frame and keep the GPU busy at the display rate even while the desktop is still.
final class FrameFingerprint {
    static let cellSize = 64

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let queue: MTLCommandQueue
    private var buffer: MTLBuffer?
    private var previous: [UInt32]?
    private var comparisons = 0
    private let log = Logger(subsystem: "io.github.pietrouk.FalcoFold", category: "Fingerprint")

    init?(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "frameFingerprint"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.pipeline = pipeline
        self.queue = queue
    }

    /// Fingerprints `texture` and compares it with the previous call's. Waits for the GPU (a fraction of a millisecond).
    func matchesPrevious(_ texture: MTLTexture) -> Bool {
        let cells = MTLSize(width: (texture.width + Self.cellSize - 1) / Self.cellSize,
                            height: (texture.height + Self.cellSize - 1) / Self.cellSize, depth: 1)
        let length = cells.width * cells.height * MemoryLayout<SIMD4<UInt32>>.stride
        if buffer?.length != length {
            buffer = device.makeBuffer(length: length, options: .storageModeShared)
            previous = nil
        }
        guard let buffer, let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }
        var cellsPerRow = UInt32(cells.width)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&cellsPerRow, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreadgroups(cells, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let current = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self),
                                                count: length / MemoryLayout<UInt32>.size))
        defer { previous = current }
        guard let previous else { return false }
        #if DEBUG
        diagnose(previous, current, gpuTime: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        #endif
        return current == previous
    }

    func reset() {
        previous = nil
    }

    #if DEBUG
    /// How the fingerprint differs from the last one: a few cells (a local change) or all of them (noise?).
    private func diagnose(_ previous: [UInt32], _ current: [UInt32], gpuTime: CFTimeInterval) {
        comparisons += 1
        guard comparisons <= 8 || comparisons % 300 == 0 else { return }
        var changedCells = 0
        var maxDiff = 0
        for cell in stride(from: 0, to: current.count, by: 4) {
            var cellDiff = 0
            for c in 0..<3 { cellDiff = max(cellDiff, abs(Int(current[cell + c]) - Int(previous[cell + c]))) }
            if cellDiff > 0 { changedCells += 1 }
            maxDiff = max(maxDiff, cellDiff)
        }
        log.info("Comparison \(self.comparisons): \(changedCells)/\(current.count / 4) cells differ, max cell diff \(maxDiff), GPU \(gpuTime * 1000, format: .fixed(precision: 2)) ms")
    }
    #endif
}
