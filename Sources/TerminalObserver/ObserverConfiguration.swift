import Foundation
import TerminalMacCore

public enum ObserverPNGPolicy {
    case threshold(Int)
    case adaptive
}

public struct ObserverConfiguration {
    public let maxFPS: Int
    public let bytesPerSecond: Int?
    public let tileSize: Int
    public let pngPolicy: ObserverPNGPolicy
    public init(maxFPS: Int = 30, bytesPerSecond: Int? = nil, tileSize: Int = 128,
                pngPolicy: ObserverPNGPolicy = .threshold(40)) throws {
        guard (1...30).contains(maxFPS), bytesPerSecond.map({ (1000...10_000_000).contains($0) }) ?? true,
              [64, 128].contains(tileSize) else { throw Failure("Invalid observer rate or tile size") }
        if case .threshold(let percent) = pngPolicy, !(1...100).contains(percent) {
            throw Failure("Observer full threshold must be 1...100 percent")
        }
        self.maxFPS = maxFPS; self.bytesPerSecond = bytesPerSecond
        self.tileSize = tileSize; self.pngPolicy = pngPolicy
    }
    public static let standard = try! ObserverConfiguration()
    public static let low = try! ObserverConfiguration(maxFPS: 10, bytesPerSecond: 180_000, pngPolicy: .adaptive)
}
