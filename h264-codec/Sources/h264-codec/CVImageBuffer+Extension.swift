import Accelerate
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

    /// Fast, allocation-light 90Â° rotation for bi-planar YUV 420 buffers.
    /// Rotates the luma plane as 8-bit and the interleaved chroma plane as
    /// 16-bit pixels, so no colour conversion or CoreImage graph is needed.
    func rotatevImage(
        orientation: CGImagePropertyOrientation,
        pool: CVPixelBufferPool? = nil
    ) -> CVPixelBuffer? {
        guard CVPixelBufferGetPlaneCount(self) == 2 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(self)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return nil
        }

        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)

        let swaps: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            swaps = true
        default:
            swaps = false
        }
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height

        let rotation: UInt8
        switch orientation {
        case .right, .rightMirrored:
            rotation = 1
        case .left, .leftMirrored:
            rotation = 3
        case .down, .downMirrored:
            rotation = 2
        default:
            rotation = 0
        }

        var destination: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        } else {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: outWidth,
                kCVPixelBufferHeightKey as String: outHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                outWidth,
                outHeight,
                format,
                attrs as CFDictionary,
                &destination
            )
        }
        guard let destination = destination else { return nil }

        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }

        for plane in 0..<2 {
            guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(self, plane),
                  let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                return nil
            }
            let srcWidth = CVPixelBufferGetWidthOfPlane(self, plane)
            let srcHeight = CVPixelBufferGetHeightOfPlane(self, plane)
            let srcRowBytes = CVPixelBufferGetBytesPerRowOfPlane(self, plane)
            let dstWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
            let dstHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
            let dstRowBytes = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)

            var src = vImage_Buffer(
                data: srcBase,
                height: vImagePixelCount(srcHeight),
                width: vImagePixelCount(srcWidth),
                rowBytes: srcRowBytes
            )
            var dst = vImage_Buffer(
                data: dstBase,
                height: vImagePixelCount(dstHeight),
                width: vImagePixelCount(dstWidth),
                rowBytes: dstRowBytes
            )

            let error: vImage_Error
            if plane == 0 {
                error = vImageRotate90_Planar8(
                    &src, &dst, rotation, 0, vImage_Flags(kvImageNoFlags)
                )
            } else {
                error = vImageRotate90_Planar16U(
                    &src, &dst, rotation, 0, vImage_Flags(kvImageNoFlags)
                )
            }
            if error != kvImageNoError {
                return nil
            }
        }

        return destination
    }
}

