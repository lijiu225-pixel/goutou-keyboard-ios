import CoreGraphics
import Foundation

/// 一帧里的一条 OCR 结果（带几何）。
///
/// **坐标系统一为左上角原点、归一化到 0…1**：x 向右、y 向下。
/// 以后所有排序 / 区域过滤 / 角色判断都只用这一种坐标系，
/// Vision 原生左下角原点只在 `fromVision` 这一处换算，别的地方不许再出现两种口径。
struct LiveOCRObservation: Equatable {
    let text: String
    /// Vision 给的 top candidate 置信度（0…1）。
    let confidence: Double
    /// 左上角原点、归一化的包围盒。
    let box: CGRect

    /// Vision 的 `boundingBox` 原点是左下角：这里换算成左上角原点。
    static func fromVision(text: String, confidence: Double, boundingBox: CGRect) -> LiveOCRObservation {
        LiveOCRObservation(
            text: text,
            confidence: confidence,
            box: CGRect(
                x: boundingBox.minX,
                y: 1 - boundingBox.maxY,
                width: boundingBox.width,
                height: boundingBox.height
            )
        )
    }
}
