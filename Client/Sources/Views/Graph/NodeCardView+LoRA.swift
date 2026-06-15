import Fleet
import SwiftUI

/// The LoRA node's inline config: which adapter, and which operation it performs.
extension NodeCardView {
    @ViewBuilder
    func config(_ lora: LoRANode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: vm.adapterBinding(lora)) {
                Text("Base only").tag(UUID?.none)
                ForEach(compatibleAdapters) { adapter in
                    Text(adapter.name).tag(UUID?.some(adapter.id))
                }
            }
            .labelsHidden()
            .font(.fleetSans(10))

            Picker("", selection: vm.operationBinding(lora)) {
                ForEach(OperationKind.allCases) { kind in
                    Text(NodeOperation.displayName(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .font(.fleetSans(10))
        }
    }
}
