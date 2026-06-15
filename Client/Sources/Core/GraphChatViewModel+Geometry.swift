import Fleet
import Foundation

/// Port geometry and wiring hit-tests (centers are stored in `positions`).
extension GraphChatViewModel {

    func outputPort(_ id: UUID) -> CGPoint {
        let center = positions[id] ?? .zero
        return CGPoint(x: center.x + cardSize.width / 2, y: center.y)
    }

    func inputPort(_ id: UUID) -> CGPoint {
        let center = positions[id] ?? .zero
        return CGPoint(x: center.x - cardSize.width / 2, y: center.y)
    }

    /// Nearest node whose input port is within `threshold` of `location`.
    func nodeNearInputPort(_ location: CGPoint, threshold: CGFloat = 44) -> UUID? {
        nodes
            .filter { $0.kind != .input }
            .map { ($0.id, hypot(inputPort($0.id).x - location.x, inputPort($0.id).y - location.y)) }
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }?.0
    }
}
