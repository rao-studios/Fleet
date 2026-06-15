import Fleet
import SwiftUI

/// SwiftUI bindings for editing node config in place. Each setter mutates the node
/// (a class), nudges `objectWillChange`, and persists.
extension GraphChatViewModel {

    private func bind<Value>(
        _ get: @escaping () -> Value, _ set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                set(newValue)
                self.objectWillChange.send()
                self.persist()
            })
    }

    // MARK: - LoRA node

    func operationBinding(_ node: LoRANode) -> Binding<OperationKind> {
        bind({ node.operationKind }, { node.operationKind = $0 })
    }

    func adapterBinding(_ node: LoRANode) -> Binding<UUID?> {
        bind({ node.adapterId }, { node.adapterId = $0 })
    }

    // MARK: - Router node

    func gateBinding(_ node: RouterNode) -> Binding<GateKind> {
        bind({ node.gateKind }, { node.gateKind = $0 })
    }

    func topKBinding(_ node: RouterNode) -> Binding<Int> {
        bind({ node.topK }, { node.topK = max(0, $0) })
    }

    func combineBinding(_ node: RouterNode) -> Binding<CombineKind> {
        bind({ node.combineKind }, { node.combineKind = $0 })
    }

    func routerAdapterBinding(_ node: RouterNode) -> Binding<UUID?> {
        bind({ node.adapterId }, { node.adapterId = $0 })
    }

    func routerOperationBinding(_ node: RouterNode) -> Binding<OperationKind> {
        bind({ node.operationKind }, { node.operationKind = $0 })
    }
}
