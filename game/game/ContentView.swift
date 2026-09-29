import SwiftUI
import MediaPlayer
import AVFoundation

struct ContentView: View {
    @State private var isPlaying = false
    @State private var currentTrackTitle = "No Track Selected"
    @State private var musicPlayer = MPMusicPlayerController.applicationMusicPlayer
    
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            
            VStack(spacing: 40) {
                Text("game")
                    .font(.largeTitle)
                    .bold()
                    .tracking(1.5)
                    .padding(.top, 40)
                
                // iPod-style Classic Player Album Art Placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 260, height: 260)
                        .shadow(radius: 10)
                    
                    Image(systemName: "music.note")
                        .font(.system(size: 80))
                        .foregroundColor(.accentColor)
                }
                
                VStack(spacing: 8) {
                    Text(currentTrackTitle)
                        .font(.title2)
                        .bold()
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Playback Controls
                HStack(spacing: 50) {
                    Button(action: { previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.title)
                    }
                    
                    Button(action: { togglePlayback() }) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 70))
                    }
                    
                    Button(action: { nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.title)
                    }
                }
                
                // Local Library Sync Button
                Button(action: { requestLibraryAccess() }) {
                    Label("Scan Local iPod Library", systemName: "arrow.clockwise")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                        .padding(.horizontal, 40)
                }
                
                Spacer()
            }
        }
        .onAppear {
            setupNotifications()
        }
    }
    
    // --- MUSIC LOGIC ---
    
    func requestLibraryAccess() {
        MPMediaLibrary.requestAuthorization { status in
            if status == .authorized {
                DispatchQueue.main.async {
                    self.musicPlayer.setQueue(with: .songs())
                    self.updateCurrentTrack()
                }
            }
        }
    }
    
    func togglePlayback() {
        if isPlaying {
            musicPlayer.pause()
            isPlaying = false
        } else {
            musicPlayer.play()
            isPlaying = true
        }
        updateCurrentTrack()
    }
    
    func nextTrack() {
        musicPlayer.skipToNextItem()
        updateCurrentTrack()
    }
    
    func previousTrack() {
        musicPlayer.skipToPreviousItem()
        updateCurrentTrack()
    }
    
    func updateCurrentTrack() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let nowPlaying = self.musicPlayer.nowPlayingItem {
                self.currentTrackTitle = nowPlaying.title ?? "Unknown Track"
            }
        }
    }
    
    func setupNotifications() {
        NotificationCenter.default.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer, queue: .main) { _ in
            self.updateCurrentTrack()
        }
    }
}
