import CoreMedia
import ReplayKit

extension CMSampleBuffer {
    var orientation: CGImagePropertyOrientation? {
        // ReplayKit attaches the orientation to the sample-attachments array
        // (CMSampleBufferGetSampleAttachmentsArray). CMGetAttachment alone does
        // not see it, which silently left every landscape capture unrotated.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            self,
            createIfNecessary: false
        ) as? [[String: Any]],
           let rawValue = attachments.first?[RPVideoSampleOrientationKey as String] as? NSNumber {
            return CGImagePropertyOrientation(rawValue: rawValue.uint32Value)
        }

        // Fallback: some OS versions expose it as a direct attachment.
        if let rawValue = CMGetAttachment(
            self,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            return CGImagePropertyOrientation(rawValue: rawValue.uint32Value)
        }

        return nil
    }
}
