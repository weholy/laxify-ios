import SwiftUI
import YMAPI

struct RootPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Laxify")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .onAppear {
            _ = YMClient.version
        }
    }
}

#Preview {
    RootPlaceholderView()
}
