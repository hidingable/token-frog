import Foundation
import VoyageCore

/// Mirrors the Canvas's 20/16 origin and column-major layout. Gaps retain the
/// preceding cell's hit area, matching the original grid's selection behavior.
enum HeatGridGeometry {
    static func cell(at point: CGPoint, pitch: CGFloat, cells: [HeatCell]) -> HeatCell? {
        guard point.x.isFinite, point.y.isFinite, pitch.isFinite, pitch > 0,
              point.x >= 20, point.y >= 16 else { return nil }
        let column = ((point.x - 20) / pitch).rounded(.down)
        let row = ((point.y - 16) / pitch).rounded(.down)
        guard row < 7, column < CGFloat((cells.last?.week ?? -1) + 1) else { return nil }
        let index = Int(column) * 7 + Int(row)
        guard cells.indices.contains(index) else { return nil }
        return cells[index]
    }
}
