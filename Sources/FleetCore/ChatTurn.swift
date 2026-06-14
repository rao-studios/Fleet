import Foundation

/// One turn in a chat conversation.
///
/// Lives in `FleetCore` (not a heavy MLX target) so both `FleetInference`
/// (generation) and `FleetGraph` (node operations) can use it without pulling in
/// the MLX graph.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case system, user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}
