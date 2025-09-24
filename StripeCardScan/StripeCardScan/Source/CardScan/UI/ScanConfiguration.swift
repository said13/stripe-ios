import Foundation

public enum ScanPerformance: Int {
    case fast
    case accurate
}

public class ScanConfiguration: NSObject {
    public var runOnOldDevices = false
    public var setPreviouslyDeniedDevicesAsIncompatible = false
}
