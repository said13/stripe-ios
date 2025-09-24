//
//  MachineLearningResult.swift
//  CardScan
//
//  Created by Sam King on 4/30/20.
//

import Foundation

public class MachineLearningResult {
    public let duration: Double
    public let frames: Int
    public var framePerSecond: Double {
        return Double(frames) / duration
    }

    public init(
        duration: Double,
        frames: Int
    ) {
        self.duration = duration
        self.frames = frames
    }
}
