import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .background(Color.fleetBG)
        }
        .environmentObject(appState)
        .task { await appState.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                FleetMark(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fleet")
                        .font(.fleetSerif(20, weight: .light, italic: true))
                        .foregroundStyle(Color.fleetInk)
                    Text("fine-tune lab")
                        .font(.fleetSans(9, weight: .medium))
                        .foregroundStyle(Color.fleetInk.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 18)

            ForEach(Screen.allCases) { screen in
                Button {
                    appState.screen = screen
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: screen.symbol)
                            .frame(width: 18)
                            .foregroundStyle(appState.screen == screen ? Color.fleetGold : Color.fleetInk.opacity(0.6))
                        Text(screen.rawValue)
                            .font(.fleetSans(13, weight: appState.screen == screen ? .semibold : .regular))
                            .foregroundStyle(Color.fleetInk)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(appState.screen == screen ? Color.fleetGold.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            Text("fleet-db · ~/Documents/fleet-db")
                .font(.fleetMono(8.5))
                .foregroundStyle(Color.fleetInk.opacity(0.3))
                .padding(12)
        }
        .background(Color.fleetBG)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.screen {
        case .models: ModelsView()
        case .datasets: DatasetsView()
        case .fineTune: FineTuneView()
        case .chat: ChatView()
        }
    }
}
