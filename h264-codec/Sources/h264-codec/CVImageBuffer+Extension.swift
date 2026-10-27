import CoreImage
import CoreMedia
import CoreVideo

extension CVImageBuffer {
    func rotate(
        context: CIContext,
        orientation: CGImagePropertyOrientation,
        pool: CVPixelBufferPool? = nil
    ) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(self, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: self)
        let rotatedCIImage = ciImage.flip(orientation: orientation)

        // Reuse a pooled buffer when provided to avoid per-frame allocations.
        if pool == nil, let pixelBuffer = rotatedCIImage.pixelBuffer {
            return pixelBuffer
        }

        var rotatedPixelBuffer: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &rotatedPixelBuffer)
        } else {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(rotatedCIImage.extent.width),
                Int(rotatedCIImage.extent.height),
                CVPixelBufferGetPixelFormatType(self),
                nil,
                &rotatedPixelBuffer
            )
        }

        guard let rotatedBuffer = rotatedPixelBuffer else { return nil }
        context.render(rotatedCIImage, to: rotatedBuffer)
        return rotatedBuffer
    }
}
