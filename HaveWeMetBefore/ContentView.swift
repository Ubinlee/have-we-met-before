import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("본 적 있나")
                        .font(.largeTitle.bold())

                    Text("우리는 만나기 전에도\n가까이 있었을까요?")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                NavigationLink("시작하기") {
                    Text("다음 화면을 만들어 보세요")
                        .navigationTitle("시작하기")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .tint(Color(red: 0.45, green: 0.36, blue: 0.78))
    }
}

#Preview {
    ContentView()
}
