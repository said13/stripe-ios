import AVKit
import UIKit

protocol CaptureOutputDelegate {
    func capture(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    )
}

public class CreditCard: NSObject {
    public var number: String
    public var expiryMonth: String?
    public var expiryYear: String?
    public var name: String?
    public var image: UIImage?
    public var cvv: String?
    public var postalCode: String?

    public init(
        number: String
    ) {
        self.number = number
    }

    public func expiryForDisplay() -> String? {
        guard var month = self.expiryMonth, var year = self.expiryYear else {
            return nil
        }

        if month.count == 1 {
            month = "0" + month
        }

        if year.count == 4 {
            year = String(year.suffix(2))
        }

        return "\(month)/\(year)"
    }
}
