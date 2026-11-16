import SwiftUI
import AppKit
import QuartzCore
import Combine

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0.12, green: 0.86, blue: 0.42)
    static let accentSoft = Color(red: 0.35, green: 0.95, blue: 0.75)
    static let violet = Color(red: 0.55, green: 0.38, blue: 1.0)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.28)
    static let stroke = Color.white.opacity(0.08)

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.7)
}

struct ContentView: View {
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var message = ""
    @State private var isError = false

    // Что сейчас играет (берётся с сервера /native-state)
    @State private var currentSong = ""
    @State private var currentArtist = ""
    @State private var albumImageURL = ""
    @State private var isPlaying = false
    @State private var progressMs = 0
    @State private var durationMs = 0
    @State private var trackID = ""
    @State private var isLiked = false
    @State private var likeBounce = 0

    /// Что мы только что попросили у Spotify. Он применяет команды с задержкой 1–3 с
    /// и всё это время отдаёт старое состояние — такие ответы игнорируем,
    /// иначе после паузы на пару секунд снова мелькало «NOW PLAYING».
    @State private var expected: Expectation?
    @State private var stateDate = Date()

    @State private var isWindowVisible = false
    @State private var appeared = false

    @FocusState private var searchFocused: Bool

    private let stateTimer = Timer.publish(
        every: 1.5,
        on: .main,
        in: .common
    ).autoconnect()

    private var hasTrack: Bool {
        !currentSong.isEmpty
    }

    var body: some View {
        ZStack {
            AmbientBackground(
                imageURL: albumImageURL,
                isPlaying: isPlaying
            )

            VStack(spacing: 0) {
                header
                    .stagger(appeared, index: 0)

                searchField
                    .padding(.top, 16)
                    .stagger(appeared, index: 1)

                ZStack {
                    if hasTrack {
                        nowPlayingCard
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .opacity)
                                        .combined(with: .scale(scale: 0.96)),
                                    removal: .opacity
                                )
                            )
                    } else {
                        emptyState
                            .transition(.opacity)
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 12)
                .stagger(appeared, index: 2)

                bottomBar
                    .padding(.top, 10)
                    .stagger(appeared, index: 3)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .frame(
            width: 640,
            height: 295
        )
        .scaleEffect(appeared ? 1 : 0.955)
        .animation(Theme.spring, value: appeared)
        .onKeyPress(.escape) {
            requestHide()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.2
            ) {
                activateAndFocus()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .spotifyDJFocus
            )
        ) { _ in
            if !isWindowVisible {
                isWindowVisible = true
                appeared = false
                refreshState()

                DispatchQueue.main.async {
                    appeared = true
                }
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.1
            ) {
                activateAndFocus()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .spotifyDJDidHide
            )
        ) { _ in
            isWindowVisible = false
            appeared = false
        }
        .onReceive(stateTimer) { _ in
            // опрашиваем Spotify только пока окно открыто
            if isWindowVisible && !isLoading {
                refreshState()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Spotify Player")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)

                ZStack(alignment: .leading) {
                    if isLoading {
                        ShimmerText(text: "Searching the vibe…")
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    } else {
                        Text("What would you like to listen to?")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .animation(Theme.snappy, value: isLoading)
            }

            Spacer()

            HStack(spacing: 4) {
                KeyCap("⇧")
                KeyCap("Space")
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.tertiary)
                .scaleEffect(searchFocused ? 1.08 : 1)
                .animation(Theme.snappy, value: searchFocused)

            TextField("Track, artist or vibe…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.text)
                .focused($searchFocused)
                .onSubmit {
                    playSong()
                }

            if !searchText.isEmpty && !isLoading {
                Button {
                    withAnimation(Theme.snappy) {
                        searchText = ""
                        message = ""
                    }

                    DispatchQueue.main.async {
                        searchFocused = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(PressableStyle())
                .transition(.scale.combined(with: .opacity))
            }

            Button {
                playSong()
            } label: {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .black))
                            Text("Play")
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 68, height: 32)
                .background(
                    LinearGradient(
                        colors: [Theme.accentSoft, Theme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
                .shadow(
                    color: Theme.accent.opacity(canPlay ? 0.45 : 0),
                    radius: 10,
                    y: 2
                )
            }
            .buttonStyle(PressableStyle())
            .disabled(!canPlay)
            .opacity(canPlay || isLoading ? 1 : 0.4)
            .animation(Theme.snappy, value: isLoading)
            .animation(Theme.snappy, value: canPlay)
        }
        .padding(.leading, 15)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(searchFocused ? 0.09 : 0.06))
        )
        .overlay(
            GlowBorder(active: searchFocused, cornerRadius: 22)
        )
        .animation(Theme.snappy, value: searchText.isEmpty)
        .animation(.easeOut(duration: 0.25), value: searchFocused)
    }

    private var canPlay: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    // MARK: - Empty

    private var emptyState: some View {
        HStack(spacing: 10) {
            EqualizerView(isPlaying: false, color: Theme.tertiary)
                .frame(width: 18, height: 14)

            Text("Nothing playing yet — type something above")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Now Playing

    private var nowPlayingCard: some View {
        HStack(spacing: 15) {
            albumCover

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    EqualizerView(isPlaying: isPlaying, color: Theme.accent)
                        .frame(width: 13, height: 10)

                    Text(isPlaying ? "NOW PLAYING" : "PAUSED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(isPlaying ? Theme.accent : Theme.tertiary)
                        .contentTransition(.interpolate)
                }
                .animation(Theme.snappy, value: isPlaying)

                VStack(alignment: .leading, spacing: 2) {
                    Text(currentSong)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Text(currentArtist)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .id(currentSong + currentArtist)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )

                progressBar
                    .padding(.top, 4)
            }
            .clipped()

            Spacer(minLength: 6)

            LikeButton(isLiked: isLiked, bounce: likeBounce) {
                toggleLike()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(trackID.isEmpty)
            .opacity(trackID.isEmpty ? 0.35 : 1)
            .padding(.trailing, 2)

            HStack(spacing: 8) {
                IconButton(systemName: "backward.fill", size: 12) {
                    control("previous")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                IconButton(
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    size: 15,
                    prominent: true
                ) {
                    withAnimation(Theme.snappy) {
                        isPlaying.toggle()
                    }
                    stateDate = Date()
                    control(isPlaying ? "play" : "pause")
                }
                .keyboardShortcut("p", modifiers: .command)

                IconButton(systemName: "forward.fill", size: 12) {
                    control("next")
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }

    private var progressBar: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !isPlaying || !isWindowVisible)) { context in
            let current = livePosition(at: context.date)

            HStack(spacing: 8) {
                Text(formatTime(current))
                    .frame(width: 30, alignment: .leading)

                GeometryReader { geo in
                    let ratio = durationMs > 0 ? CGFloat(current) / CGFloat(durationMs) : 0

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accentSoft],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * min(1, ratio)))
                            .shadow(color: Theme.accent.opacity(0.6), radius: 4)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard durationMs > 0, geo.size.width > 0 else {
                            return
                        }

                        let tapRatio = max(0, min(1, location.x / geo.size.width))
                        let position = Int(Double(durationMs) * tapRatio)

                        progressMs = position
                        stateDate = Date()
                        control("seek", positionMs: position)
                    }
                }
                .frame(height: 12)

                Text(formatTime(durationMs))
                    .frame(width: 30, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Album Cover

    private var albumCover: some View {
        ZStack {
            if !albumImageURL.isEmpty, let url = URL(string: albumImageURL) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    default:
                        placeholderCover
                    }
                }
                .id(albumImageURL)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                placeholderCover
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .scaleEffect(isPlaying ? 1 : 0.92)
        .shadow(color: .black.opacity(0.45), radius: isPlaying ? 12 : 6, y: isPlaying ? 6 : 3)
        .animation(Theme.spring, value: isPlaying)
    }

    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.violet.opacity(0.35), Theme.accent.opacity(0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack {
            Button {
                openTelegram()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 8, weight: .semibold))

                    Text("@tenssage")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(HoverPillStyle())

            Spacer()

            ZStack(alignment: .trailing) {
                if !message.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))

                        Text(message)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(
                        isError
                        ? Color(red: 1, green: 0.45, blue: 0.45)
                        : Theme.accent
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(message)
                } else {
                    HStack(spacing: 4) {
                        if hasTrack {
                            KeyCap("⌘←")
                            KeyCap("⌘P")
                            KeyCap("⌘→")
                            KeyCap("⌘L")
                            Text("control")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.trailing, 6)
                        }

                        KeyCap("esc")
                        Text("close")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(Theme.snappy, value: message)
        }
    }

    // MARK: - Networking

    private static let serverBase = "http://127.0.0.1:8888"

    private func sendRequest(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        completion: @escaping ([String: Any]?, String?) -> Void
    ) {
        guard let url = URL(string: Self.serverBase + path) else {
            completion(nil, "Address error")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        // запас времени: если Spotify был закрыт, сервер ждёт, пока он запустится
        request.timeoutInterval = 35

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if error != nil {
                    completion(nil, "Server is starting… try again in a second")
                    return
                }

                guard
                    let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    completion(nil, "Server response error")
                    return
                }

                if json["success"] as? Bool == true {
                    completion(json, nil)
                } else {
                    completion(json, json["error"] as? String ?? "Something went wrong")
                }
            }
        }.resume()
    }

    private func showMessage(_ text: String, error: Bool) {
        withAnimation(Theme.snappy) {
            message = text
            isError = error
        }
    }

    // MARK: - Play

    private func playSong() {
        let song = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !song.isEmpty, !isLoading else {
            activateAndFocus()
            return
        }

        withAnimation(Theme.snappy) {
            isLoading = true
            message = ""
        }

        ensureSpotifyRunning()

        sendRequest("/native-play", method: "POST", body: ["prompt": song]) { json, error in
            withAnimation(Theme.snappy) {
                isLoading = false
            }

            if let error {
                showMessage(error, error: true)
                return
            }

            withAnimation(Theme.spring) {
                currentSong = json?["name"] as? String ?? song
                currentArtist = json?["artist"] as? String ?? ""
                albumImageURL = json?["image_url"] as? String ?? ""
                durationMs = json?["duration_ms"] as? Int ?? 0
                progressMs = 0
                stateDate = Date()
                isPlaying = true
                searchText = ""
                trackID = json?["id"] as? String ?? ""
                isLiked = false
            }

            let isArtist = (json?["kind"] as? String) == "artist"
            expected = Expectation(
                playing: true,
                trackTo: isArtist || trackID.isEmpty ? nil : trackID
            )

            // узнаём, лайкнут ли трек, и точное «сейчас играет» (для исполнителя)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                refreshState()
            }

            showMessage("Playing", error: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                requestHide()
            }
        }
    }

    // MARK: - Player state & controls

    private func refreshState() {
        sendRequest("/native-state") { json, error in
            guard error == nil, let json else {
                return
            }

            if isStale(json) {
                return  // Spotify ещё не применил нашу команду
            }

            let track = json["track"] as? [String: Any]
            let newSong = track?["name"] as? String ?? currentSong
            let newArtist = track?["artist"] as? String ?? currentArtist
            let newImage = track?["image_url"] as? String ?? albumImageURL
            let newPlaying = json["playing"] as? Bool ?? false

            let changed = newSong != currentSong
                || newArtist != currentArtist
                || newPlaying != isPlaying

            withAnimation(changed ? Theme.spring : nil) {
                isPlaying = newPlaying
                currentSong = newSong
                currentArtist = newArtist
                albumImageURL = newImage
            }

            if let track {
                trackID = track["id"] as? String ?? ""

                let liked = track["liked"] as? Bool ?? false
                if liked != isLiked {
                    withAnimation(Theme.snappy) {
                        isLiked = liked
                    }
                }
            }

            progressMs = json["progress_ms"] as? Int ?? 0
            durationMs = json["duration_ms"] as? Int ?? 0
            stateDate = Date()
        }
    }

    private func toggleLike() {
        let newValue = !isLiked

        // сразу показываем результат, если сервер откажет — откатим
        withAnimation(Theme.snappy) {
            isLiked = newValue
        }
        if newValue {
            likeBounce += 1
        }

        var body: [String: Any] = ["liked": newValue]
        if !trackID.isEmpty {
            body["id"] = trackID
        }

        sendRequest("/native-like", method: "POST", body: body) { _, error in
            guard let error else {
                showMessage(newValue ? "Added to Liked Songs" : "Removed from Liked Songs", error: false)
                return
            }

            withAnimation(Theme.snappy) {
                isLiked = !newValue
            }

            if error.contains("/login") {
                // нужно новое разрешение Spotify — открываем вход в браузере
                showMessage("Log in again in the browser to enable likes", error: true)
                if let url = URL(string: "http://127.0.0.1:8888/login") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                showMessage(error, error: true)
            }
        }
    }

    /// true, если ответ сервера ещё не отражает нашу последнюю команду
    private func isStale(_ json: [String: Any]) -> Bool {
        guard let e = expected else {
            return false
        }

        if Date() > e.until {
            expected = nil  // подождали достаточно — дальше верим Spotify
            return false
        }

        let track = json["track"] as? [String: Any]
        let id = track?["id"] as? String
        let playing = json["playing"] as? Bool ?? false
        let progress = json["progress_ms"] as? Int ?? 0

        var stale = false
        if let want = e.playing, playing != want { stale = true }
        if let from = e.trackFrom, id == from { stale = true }
        if let to = e.trackTo, id != to { stale = true }
        if let seek = e.seekTo, abs(progress - seek) > 4000 { stale = true }

        if !stale {
            expected = nil  // подтверждено
        }
        return stale
    }

    /// Если Spotify закрыт — открываем его в фоне, чтобы команда было куда отправить.
    /// Возвращает true, если Spotify пришлось запускать.
    @discardableResult
    private func ensureSpotifyRunning() -> Bool {
        let bundleID = "com.spotify.client"

        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false   // не уводим фокус из плеера
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        showMessage("Opening Spotify…", error: false)
        return true
    }

    private func control(_ action: String, positionMs: Int? = nil) {
        let launchedSpotify = (action == "play" || action == "next" || action == "previous")
            && ensureSpotifyRunning()

        switch action {
        case _ where launchedSpotify:
            // Spotify запускается — подтверждение придёт только через несколько секунд
            expected = Expectation(playing: true, seconds: 20)
        case "play", "pause":
            expected = Expectation(playing: action == "play")
        case "next", "previous":
            expected = Expectation(trackFrom: trackID)
        case "seek":
            expected = Expectation(seekTo: positionMs, seconds: 3)
        default:
            break
        }

        var body: [String: Any] = ["action": action]

        if let positionMs {
            body["position_ms"] = positionMs
        }

        sendRequest("/native-control", method: "POST", body: body) { json, error in
            if let error {
                showMessage(error, error: true)
                expected = nil
            } else if isError {
                showMessage("", error: false)
            }

            // «Следующий»: сервер заранее знает трек из очереди — показываем его сразу
            if error == nil, let track = json?["track"] as? [String: Any] {
                showTrackNow(track)
            }

            // Spotify обновляет состояние не мгновенно. После переключения трека
            // спрашиваем часто, чтобы новый трек появился как можно быстрее.
            let delays: [Double] = (action == "next" || action == "previous")
                ? [0.3, 0.6, 1.0, 1.5, 2.2, 3.0]
                : [0.7]

            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    refreshState()
                }
            }
        }
    }

    /// Мгновенно показать трек (не дожидаясь подтверждения от Spotify)
    private func showTrackNow(_ track: [String: Any]) {
        let id = track["id"] as? String ?? ""

        withAnimation(Theme.spring) {
            currentSong = track["name"] as? String ?? currentSong
            currentArtist = track["artist"] as? String ?? ""
            albumImageURL = track["image_url"] as? String ?? albumImageURL
            durationMs = track["duration_ms"] as? Int ?? durationMs
            progressMs = 0
            stateDate = Date()
            isPlaying = true
            trackID = id
            isLiked = track["liked"] as? Bool ?? false
        }

        if !id.isEmpty {
            // пока Spotify не подтвердит этот трек — его старые ответы игнорируем
            expected = Expectation(trackTo: id)
        }
    }

    // MARK: - Helpers

    /// Позиция трека, плавно «дотикивающая» между опросами сервера
    private func livePosition(at date: Date) -> Int {
        guard isPlaying else {
            return progressMs
        }

        let elapsed = Int(date.timeIntervalSince(stateDate) * 1000)
        return min(durationMs, progressMs + max(0, elapsed))
    }

    private func formatTime(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func activateAndFocus() {
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func requestHide() {
        NotificationCenter.default.post(name: .spotifyDJHide, object: nil)
    }

    private func openTelegram() {
        guard let url = URL(string: "https://t.me/tenssage") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

// MARK: - Expectation

/// Ожидаемое состояние после команды пользователя (см. ContentView.expected)
private struct Expectation {
    var playing: Bool? = nil
    var trackFrom: String? = nil
    var trackTo: String? = nil
    var seekTo: Int? = nil
    var until: Date

    init(
        playing: Bool? = nil,
        trackFrom: String? = nil,
        trackTo: String? = nil,
        seekTo: Int? = nil,
        seconds: Double = 5
    ) {
        self.playing = playing
        self.trackFrom = trackFrom
        self.trackTo = trackTo
        self.seekTo = seekTo
        self.until = Date().addingTimeInterval(seconds)
    }
}

// MARK: - Ambient background

/// Размытая обложка текущего трека + медленно плывущие цветные пятна
private struct AmbientBackground: View {
    let imageURL: String
    let isPlaying: Bool

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            Color.black.opacity(0.62)

            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let speed = isPlaying ? 0.35 : 0.12

                ZStack {
                    blob(Theme.accent, size: 300, opacity: 0.22)
                        .offset(
                            x: CGFloat(sin(t * speed) * 160) - 120,
                            y: CGFloat(cos(t * speed * 0.8) * 50) + 40
                        )

                    blob(Theme.violet, size: 280, opacity: 0.22)
                        .offset(
                            x: CGFloat(cos(t * speed * 0.7) * 170) + 140,
                            y: CGFloat(sin(t * speed * 1.1) * 60) - 30
                        )

                    blob(Color(red: 0.1, green: 0.6, blue: 1.0), size: 220, opacity: 0.12)
                        .offset(
                            x: CGFloat(sin(t * speed * 0.5 + 2) * 200),
                            y: CGFloat(cos(t * speed * 0.6 + 1) * 70) + 60
                        )
                }
            }

            if !imageURL.isEmpty, let url = URL(string: imageURL) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.8))) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 640, height: 295)
                            .blur(radius: 50)
                            .saturation(1.6)
                            .opacity(0.45)
                            .transition(.opacity)
                    }
                }
                .id(imageURL)
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            // лёгкая виньетка для читаемости текста
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.8), value: imageURL)
        .clipped()
    }

    private func blob(_ color: Color, size: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: 60)
    }
}

// MARK: - Equalizer

private struct EqualizerView: View {
    let isPlaying: Bool
    let color: Color

    private let phases: [Double] = [0, 1.7, 3.1, 0.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: geo.size.width * 0.12) {
                    ForEach(phases.indices, id: \.self) { index in
                        let wave = (sin(t * (5 + Double(index)) + phases[index]) + 1) / 2
                        let height = isPlaying ? 0.25 + wave * 0.75 : 0.25

                        Capsule()
                            .fill(color)
                            .frame(height: geo.size.height * height)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isPlaying)
    }
}

// MARK: - Small components

private struct KeyCap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t * 0.9).truncatingRemainder(dividingBy: 1))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .overlay(
                    LinearGradient(
                        colors: [.clear, Theme.accentSoft, .clear],
                        startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                        endPoint: UnitPoint(x: phase * 2, y: 0.5)
                    )
                    .mask(
                        Text(text).font(.system(size: 11, weight: .medium))
                    )
                )
        }
    }
}

/// Спокойная «стеклянная» граница поля поиска: светлый блик сверху,
/// при фокусе чуть ярче и с еле заметным зелёным оттенком снизу
private struct GlowBorder: View {
    let active: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .stroke(
                LinearGradient(
                    colors: active
                    ? [Color.white.opacity(0.28), Color.white.opacity(0.08), Theme.accent.opacity(0.22)]
                    : [Color.white.opacity(0.14), Color.white.opacity(0.04), Color.white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
            .background(
                // мягкая внутренняя подсветка вместо яркого свечения
                shape
                    .fill(Color.white.opacity(active ? 0.025 : 0))
            )
            .animation(.easeOut(duration: 0.25), value: active)
    }
}

private struct IconButton: View {
    let systemName: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(hovering ? 0.95 : 0.7))
                .frame(width: prominent ? 42 : 32, height: prominent ? 42 : 32)
                .background(
                    Circle()
                        .fill(
                            prominent
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [.white, Color.white.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(hovering ? 0.14 : 0.06))
                        )
                )
                .shadow(
                    color: prominent ? Color.white.opacity(hovering ? 0.35 : 0.15) : .clear,
                    radius: hovering ? 12 : 6
                )
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
    }
}

private struct LikeButton: View {
    let isLiked: Bool
    let bounce: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bounce)
                    .foregroundStyle(
                        isLiked
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [Theme.accentSoft, Theme.accent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(Color.white.opacity(hovering ? 0.9 : 0.55))
                    )
                    .shadow(color: isLiked ? Theme.accent.opacity(0.6) : .clear, radius: 6)
            }
            .frame(width: 32, height: 32)
            .background(
                Circle()
                    .fill(Color.white.opacity(hovering ? 0.1 : 0))
            )
            .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
        .help(isLiked ? "Remove from Liked Songs (⌘L)" : "Add to Liked Songs (⌘L)")
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

private struct HoverPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPill(configuration: configuration)
    }

    private struct HoverPill: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    Capsule()
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.snappy, value: hovering)
                .animation(Theme.snappy, value: configuration.isPressed)
        }
    }
}

private extension View {
    /// Элементы появляются по очереди, снизу вверх
    func stagger(_ appeared: Bool, index: Int) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(
                Theme.spring.delay(Double(index) * 0.045),
                value: appeared
            )
    }
}

// MARK: - Blur

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Окно показано — сфокусировать поиск и обновить «сейчас играет»
    static let spotifyDJFocus = Notification.Name("SpotifyDJFocus")

    /// Попросить AppController спрятать окно
    static let spotifyDJHide = Notification.Name("SpotifyDJHide")

    /// Окно спрятано — перестать опрашивать сервер
    static let spotifyDJDidHide = Notification.Name("SpotifyDJDidHide")
}
