import Fleet
import SwiftUI

/// The Router node's inline config: its gate, top-k, and combine mode (plus the
/// optional adapter/operation used when combining via synthesize).
extension NodeCardView {
    @ViewBuilder
    func routerConfig(_ router: RouterNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: vm.gateBinding(router)) {
                    Text("gate: none").tag(GateKind.none)
                    Text("gate: embed").tag(GateKind.embedding)
                }
                .labelsHidden()
                .font(.fleetSans(9))

                Stepper(
                    "top-\(router.topK == 0 ? "all" : "\(router.topK)")",
                    value: vm.topKBinding(router), in: 0 ... 8
                )
                .font(.fleetSans(9))
            }

            Picker("", selection: vm.combineBinding(router)) {
                Text("merge").tag(CombineKind.merge)
                Text("synthesize").tag(CombineKind.synthesize)
            }
            .labelsHidden()
            .font(.fleetSans(9))

            if router.combineKind == .synthesize {
                Picker("", selection: vm.routerAdapterBinding(router)) {
                    Text("Base only").tag(UUID?.none)
                    ForEach(compatibleAdapters) { adapter in
                        Text(adapter.name).tag(UUID?.some(adapter.id))
                    }
                }
                .labelsHidden()
                .font(.fleetSans(9))
            }
        }
    }
}
