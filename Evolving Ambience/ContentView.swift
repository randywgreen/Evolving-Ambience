import SwiftUI

struct ContentView: View {
    @StateObject private var engine = AmbientAudioEngine()

    var body: some View {
        VStack(spacing: 20) {
            Text("Ambient Audio")
                .font(.title)
                .padding(.top)

            HStack(spacing: 40) {
                Button {
                    engine.start()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title2)
                    Text("Play")
                        .fontWeight(.semibold)
                }
                .disabled(engine.isPlaying)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityLabel("Play ambient audio")

                Button {
                    engine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                    Text("Stop")
                        .fontWeight(.semibold)
                }
                .disabled(!engine.isPlaying)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityLabel("Stop ambient audio")
            }

            Slider(value: $engine.volume, in: 0...1) { isEditing in
                if !isEditing {
                    engine.setVolume(engine.volume)
                }
            }
            .accentColor(.blue)
            .padding(.horizontal)
            .accessibilityLabel("Volume")
        }
        .padding()
        .onAppear {
            engine.setVolume(engine.volume)
        }
    }
}

#Preview {
    ContentView()
}
