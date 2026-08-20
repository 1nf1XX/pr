import SwiftUI
import AVFoundation
import Speech

// MARK: - Voice Assistant
class VoiceAssistant: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    @Published var recognizedText = "Нажми на микрофон..."
    @Published var assistantReply = "Система LUPIN на связи. Жду распоряжений."
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var isSpeaking = false
    @Published var micAccessDenied = false

    @AppStorage("deepseek_api_key") var apiKey: String = ""
    @Published var pcConnection: PCServerConnection?
    
    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let maleRuVoice = voices.first(where: { $0.language == "ru-RU" && $0.gender == .male }) {
            return maleRuVoice
        }
        return AVSpeechSynthesisVoice(language: "ru-RU")
    }

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Не удалось настроить сессию воспроизведения: \(error)")
        }
    }

    func speak(_ text: String) {
        configurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = pickVoice()
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.78
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func sendToDeepSeek(prompt: String, sendToPC: Bool = false) {
        if sendToPC, let pcConnection = pcConnection, pcConnection.isConnected {
            pcConnection.sendVoiceCommand(prompt)
            DispatchQueue.main.async {
                self.assistantReply = "Команда отправлена на ПК: \(prompt)"
                self.speak(self.assistantReply)
            }
            return
        }
        
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.assistantReply = "Ключ не задан. Открой настройки."
                self.speak(self.assistantReply)
            }
            return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        Тебя зовут LUPIN — ИИ-ассистент. Стиль общения: сдержанный, точный, слегка ироничный, \
        как у безупречного личного помощника. Отвечай по делу, кратко, без грубости и без \
        наигранной дерзости. Лёгкий налёт элегантности и остроумия уместен, хамство — нет.
        """

        let requestBody: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "stream": false
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        DispatchQueue.main.async { self.isProcessing = true }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { self.isProcessing = false }

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                DispatchQueue.main.async {
                    self.assistantReply = "Ошибка сервера: код \(httpResponse.statusCode). Проверь ключ или лимиты."
                }
                return
            }

            guard let data = data, error == nil else {
                DispatchQueue.main.async {
                    self.assistantReply = "Сетевая ошибка соединения с ядром."
                }
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {

                DispatchQueue.main.async {
                    self.assistantReply = content
                    self.speak(content)
                }
            } else {
                DispatchQueue.main.async {
                    self.assistantReply = "Ошибка парсинга ответа API."
                }
            }
        }.resume()
    }

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self.micAccessDenied = false
                    self.startRecording()
                } else {
                    self.micAccessDenied = true
                    self.recognizedText = "Доступ к микрофону заблокирован системой."
                }
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        isListening = false
    }

    private func startRecording() {
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false
            if let result = result {
                DispatchQueue.main.async {
                    self.recognizedText = result.bestTranscription.formattedString
                }
                isFinal = result.isFinal
            }
            if error != nil || isFinal {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                DispatchQueue.main.async { self.isListening = false }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try? audioEngine.start()
        isListening = true
        recognizedText = "Слушаю..."
    }
}

// MARK: - PC Server Connection
class PCServerConnection: ObservableObject {
    @Published var isConnected = false
    @Published var pcIP = "192.168.1.100"
    @Published var pcPort = "8080"
    @Published var authToken = "lupin_secure_token_2024"
    @Published var lastResponse = ""
    @Published var systemInfo = ""
    @Published var screenshot: UIImage?
    
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    
    func connect() {
        guard let url = URL(string: "ws://\(pcIP):\(pcPort)") else {
            print("❌ Invalid URL")
            return
        }
        
        print("🔗 Connecting to: \(url)")
        
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        
        let authMessage: [String: Any] = ["auth": authToken]
        sendJSON(authMessage)
        
        isConnected = true
        startListening()
    }
    
    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        isConnected = false
        print("🔌 Disconnected")
    }
    
    private func sendJSON(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Can't serialize JSON")
            return
        }
        
        print("📤 Sending: \(jsonString)")
        
        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                print("❌ Send error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
            } else {
                print("✅ Message sent")
            }
        }
    }
    
    private func startListening() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("📥 Received: \(text)")
                    DispatchQueue.main.async {
                        self?.handleResponse(text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        print("📥 Received data: \(text)")
                        DispatchQueue.main.async {
                            self?.handleResponse(text)
                        }
                    }
                @unknown default:
                    break
                }
                self?.startListening()
            case .failure(let error):
                print("❌ Receive error: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
            }
        }
    }
    
    private func handleResponse(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        if let screenshotBase64 = json["screenshot"] as? String,
           let imageData = Data(base64Encoded: screenshotBase64),
           let image = UIImage(data: imageData) {
            screenshot = image
        }
        
        if let data = json["data"] as? [String: Any] {
            let cpu = data["cpu_percent"] ?? "N/A"
            let ram = data["ram_percent"] ?? "N/A"
            let disk = data["disk_percent"] ?? "N/A"
            let ip = data["ip"] ?? "N/A"
            let torIP = data["tor_ip"] ?? "N/A"
            let gpu = data["gpu"] ?? "N/A"
            let uptime = data["uptime"] ?? "N/A"
            
            systemInfo = """
            💻 CPU: \(cpu)%
            🧠 RAM: \(ram)%
            💾 Disk: \(disk)%
            🌐 IP: \(ip)
            🔒 Tor IP: \(torIP)
            🎮 GPU: \(gpu)
            ⏱ Uptime: \(uptime)
            """
        }
        
        if let message = json["message"] as? String {
            lastResponse = message
        }
    }
    
    func sendVoiceCommand(_ text: String) {
        sendJSON([
            "command": "voice_command",
            "params": ["text": text]
        ])
    }
    
    func sendTextMessage(_ text: String) {
        sendJSON([
            "command": "send_message",
            "params": ["text": text]
        ])
    }
    
    func requestSystemInfo() {
        sendJSON(["command": "system_info"])
    }
    
    func controlMedia(_ action: String) {
        sendJSON([
            "command": "media_control",
            "params": ["action": action]
        ])
    }
    
    func searchMusic(_ query: String) {
        sendJSON([
            "command": "search_music",
            "params": ["query": query]
        ])
    }
    
    func controlTor(_ action: String) {
        sendJSON([
            "command": "tor_control",
            "params": ["action": action]
        ])
    }
    
    func takeScreenshot() {
        sendJSON(["command": "screenshot"])
    }
    
    func controlVolume(_ volume: Int) {
        sendJSON([
            "command": "volume_control",
            "params": ["volume": volume]
        ])
    }
    
    func launchApp(_ app: String) {
        sendJSON([
            "command": "launch_app",
            "params": ["app": app]
        ])
    }
    
    func powerControl(_ action: String) {
        sendJSON([
            "command": "power_control",
            "params": ["action": action]
        ])
    }
    
    func switchAudioDevice(_ device: String) {
        sendJSON([
            "command": "audio_device",
            "params": ["device": device]
        ])
    }
}

// MARK: - Colors Extension
extension Color {
    static let lupinAccent = Color(red: 0.85, green: 0.88, blue: 0.0) // #D8E000
    static let lupinAccentHover = Color(red: 0.69, green: 0.72, blue: 0.0) // #B0B800
    static let lupinBackground = Color(red: 0.04, green: 0.04, blue: 0.04) // #0a0a0a
    static let lupinPanel = Color(red: 0.07, green: 0.07, blue: 0.07) // #111111
    static let lupinBorder = Color(red: 0.10, green: 0.10, blue: 0.10) // #1a1a1a
    static let lupinText = Color(red: 0.72, green: 0.72, blue: 0.72) // #B8B8B8
    static let lupinTextDim = Color(red: 0.40, green: 0.40, blue: 0.40) // #666666
    static let lupinRed = Color(red: 1.0, green: 0.27, blue: 0.27) // #FF4444
    static let lupinGreen = Color(red: 0.27, green: 1.0, blue: 0.27) // #44FF44
    static let lupinOrange = Color(red: 1.0, green: 0.53, blue: 0.0) // #FF8800
}

// MARK: - Custom Button Style
struct LupinButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var isDanger: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundColor(foregroundColor(for: configuration))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(backgroundColor(for: configuration))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
    
    private func foregroundColor(for configuration: Configuration) -> Color {
        if isActive {
            return .black
        } else if isDanger {
            return .lupinRed
        } else {
            return .lupinText
        }
    }
    
    private func backgroundColor(for configuration: Configuration) -> Color {
        if configuration.isPressed {
            return .lupinAccentHover
        } else if isActive {
            return .lupinAccent
        } else if isDanger {
            return Color(red: 0.10, green: 0.05, blue: 0.05)
        } else {
            return .lupinPanel
        }
    }
    
    private var borderColor: Color {
        if isActive {
            return .lupinAccent
        } else if isDanger {
            return Color(red: 0.24, green: 0.11, blue: 0.11)
        } else {
            return .lupinBorder
        }
    }
}

// MARK: - Pixel Character
struct PixelLupinView: View {
    let isListening: Bool
    let isSpeaking: Bool

    @State private var mouthOpen = false
    @State private var bobUp = false

    private let mouthTimer = Timer.publish(every: 0.22, on: .main, in: .common).autoconnect()
    private let bobTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    private let baseGrid: [[Int]] = [
        [0,0,0,1,1,1,1,0,0,0],
        [0,1,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,1,1,1,1],
        [0,2,2,2,2,2,2,2,2,0],
        [0,2,8,2,2,2,2,8,2,0],
        [0,2,2,2,2,2,2,2,2,0],
        [0,2,2,2,0,0,2,2,2,0],
        [0,0,2,2,2,2,2,2,0,0],
        [0,0,3,5,5,5,5,3,0,0],
        [0,3,3,3,3,3,3,3,3,0],
        [3,3,3,3,3,3,3,3,3,3],
        [3,3,4,3,3,3,3,4,3,3],
        [4,4,3,3,3,3,3,3,4,4],
        [4,4,4,4,4,4,4,4,4,4]
    ]

    private var currentGrid: [[Int]] {
        var grid = baseGrid
        if mouthOpen {
            grid[6] = [0,2,2,7,7,7,7,2,2,0]
        } else {
            grid[6] = [0,2,2,2,7,7,2,2,2,0]
        }
        return grid
    }

    private func pixelColor(for value: Int) -> Color {
        switch value {
        case 1: return Color(red: 0.10, green: 0.10, blue: 0.10)
        case 2: return Color(red: 0.86, green: 0.72, blue: 0.55)
        case 3: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case 4: return Color(red: 0.06, green: 0.06, blue: 0.08)
        case 5: return Color.lupinAccent
        case 7: return Color.black.opacity(0.85)
        case 8: return Color.lupinAccent
        default: return .clear
        }
    }

    var body: some View {
        GeometryReader { geo in
            let cols = baseGrid[0].count
            let rows = baseGrid.count
            let cell = min(geo.size.width / CGFloat(cols), geo.size.height / CGFloat(rows))
            let originX = (geo.size.width - CGFloat(cols) * cell) / 2
            let originY = (geo.size.height - CGFloat(rows) * cell) / 2

            ZStack {
                ForEach(0..<rows, id: \.self) { r in
                    ForEach(0..<cols, id: \.self) { c in
                        let value = currentGrid[r][c]
                        if value != 0 {
                            Rectangle()
                                .fill(pixelColor(for: value))
                                .frame(width: cell, height: cell)
                                .position(
                                    x: originX + CGFloat(c) * cell + cell / 2,
                                    y: originY + CGFloat(r) * cell + cell / 2
                                )
                        }
                    }
                }
            }
        }
        .frame(width: 130, height: 175)
        .offset(y: bobUp ? -5 : 0)
        .shadow(color: Color.lupinAccent.opacity((isListening || isSpeaking) ? 0.5 : 0.15), radius: (isListening || isSpeaking) ? 14 : 6)
        .onReceive(mouthTimer) { _ in
            if isSpeaking {
                mouthOpen.toggle()
            } else if mouthOpen {
                mouthOpen = false
            }
        }
        .onReceive(bobTimer) { _ in
            let duration = (isListening || isSpeaking) ? 0.35 : 0.9
            withAnimation(.easeInOut(duration: duration)) {
                bobUp.toggle()
            }
        }
    }
}

// MARK: - Section View
struct SectionView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.lupinAccent)
                .padding(.bottom, 2)
            
            content
        }
        .padding(12)
        .background(Color.lupinPanel)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.lupinBorder, lineWidth: 1)
        )
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject var assistant = VoiceAssistant()
    @StateObject var pcConnection = PCServerConnection()
    @State private var showSettings = false
    @State private var showPCControls = false
    @State private var textInput = ""
    @State private var showTextInput = false

    var body: some View {
        ZStack {
            Color.lupinBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    Spacer()
                    Text("LUPIN // SUITE")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.lupinAccent)
                    Spacer()
                }
                .overlay(
                    HStack {
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.lupinTextDim)
                        }
                        .padding(.trailing)
                    }
                )
                .padding(.top, 10)

                // Pixel Character
                PixelLupinView(isListening: assistant.isListening, isSpeaking: assistant.isSpeaking)
                    .padding(.top, 4)

                // PC Connection + Text Input Toggle
                HStack(spacing: 12) {
                    Button(action: { showPCControls.toggle() }) {
                        HStack {
                            Circle()
                                .fill(pcConnection.isConnected ? Color.lupinGreen : Color.lupinRed)
                                .frame(width: 8, height: 8)
                            Text(pcConnection.isConnected ? "PC ONLINE" : "PC OFFLINE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(pcConnection.isConnected ? .lupinGreen : .lupinRed)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.lupinPanel)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.lupinBorder, lineWidth: 1)
                        )
                    }
                    
                    Spacer()
                    
                    Button(action: { showTextInput.toggle() }) {
                        Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.system(size: 16))
                            .foregroundColor(.lupinAccent)
                            .padding(8)
                            .background(Color.lupinPanel)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.lupinBorder, lineWidth: 1)
                            )
                    }
                }
                .padding(.horizontal)

                // Text Input Field
                if showTextInput {
                    HStack(spacing: 8) {
                        TextField("Введите команду...", text: $textInput)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.lupinPanel)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.lupinBorder, lineWidth: 1)
                            )
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.send)
                            .onSubmit {
                                sendTextCommand()
                            }
                        
                        Button(action: sendTextCommand) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.black)
                                .padding(10)
                                .background(Color.lupinAccent)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.horizontal)
                }

                // Input Stream
                SectionView(title: "ВХОДЯЩИЙ ПОТОК:") {
                    Text(assistant.recognizedText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)

                // Microphone Access Denied
                if assistant.micAccessDenied {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.lupinRed)
                        Text("Микрофон заблокирован. Разреши доступ в Настройках iOS.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.lupinRed)
                    }
                    .padding(.horizontal)
                }

                // Response
                SectionView(title: "ОТВЕТ ЯДРА:") {
                    if assistant.isProcessing {
                        HStack {
                            ProgressView()
                                .tint(.lupinAccent)
                            Text("ОБРАБОТКА...")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.lupinOrange)
                        }
                    } else {
                        ScrollView {
                            Text(assistant.assistantReply)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(.lupinAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Microphone Button
                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        if pcConnection.isConnected {
                            assistant.sendToDeepSeek(prompt: assistant.recognizedText, sendToPC: true)
                        } else {
                            assistant.sendToDeepSeek(prompt: assistant.recognizedText)
                        }
                    } else {
                        assistant.startListening()
                    }
                }) {
                    Image(systemName: assistant.isListening ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 35))
                        .foregroundColor(.black)
                        .padding(25)
                        .background(assistant.isListening ? Color.lupinRed : Color.lupinAccent)
                        .clipShape(Circle())
                        .shadow(color: (assistant.isListening ? Color.lupinRed : Color.lupinAccent).opacity(0.5), radius: 10)
                }

                Text(assistant.isListening ? "ИДЕТ ЗАПИСЬ..." : "НАЖМИ ДЛЯ ВВОДА")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.lupinTextDim)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $assistant.apiKey, pcConnection: pcConnection)
        }
        .sheet(isPresented: $showPCControls) {
            PCControlView(pcConnection: pcConnection)
        }
        .onAppear {
            assistant.pcConnection = pcConnection
            if assistant.apiKey.isEmpty {
                showSettings = true
            }
        }
    }
    
    private func sendTextCommand() {
        guard !textInput.isEmpty else { return }
        
        let command = textInput
        textInput = ""
        
        print("📱 Sending command: \(command)")
        print("📱 PC Connected: \(pcConnection.isConnected)")
        
        if pcConnection.isConnected {
            pcConnection.sendTextMessage(command)
            assistant.assistantReply = "Отправлено на ПК: \(command)"
        } else {
            assistant.sendToDeepSeek(prompt: command)
        }
    }
}

// MARK: - PC Control View
struct PCControlView: View {
    @ObservedObject var pcConnection: PCServerConnection
    @Environment(\.dismiss) var dismiss
    @State private var volume: Double = 50
    @State private var musicQuery = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 12) {
                        // Connection
                        SectionView(title: "CONNECTION") {
                            VStack(spacing: 8) {
                                TextField("PC IP Address", text: $pcConnection.pcIP)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.lupinBackground)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.lupinBorder, lineWidth: 1)
                                    )
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                TextField("Port", text: $pcConnection.pcPort)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.lupinBackground)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.lupinBorder, lineWidth: 1)
                                    )
                                    .keyboardType(.numberPad)
                                
                                SecureField("Auth Token", text: $pcConnection.authToken)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.lupinBackground)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.lupinBorder, lineWidth: 1)
                                    )
                                    .autocapitalization(.none)
                                
                                Button(action: {
                                    if pcConnection.isConnected {
                                        pcConnection.disconnect()
                                    } else {
                                        pcConnection.connect()
                                    }
                                }) {
                                    Text(pcConnection.isConnected ? "DISCONNECT" : "CONNECT")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(pcConnection.isConnected ? Color.lupinRed : Color.lupinGreen)
                                        .cornerRadius(4)
                                }
                            }
                        }
                        
                        if pcConnection.isConnected {
                            // System Info
                            SectionView(title: "SYSTEM INFO") {
                                Text(pcConnection.systemInfo)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.white)
                                    .lineLimit(nil)
                                
                                Button("REFRESH INFO") {
                                    pcConnection.requestSystemInfo()
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                            }
                            
                            // Media Control
                            SectionView(title: "MEDIA CONTROL") {
                                HStack(spacing: 20) {
                                    Button(action: { pcConnection.controlMedia("prev") }) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.lupinAccent)
                                            .frame(maxWidth: .infinity)
                                            .padding(10)
                                            .background(Color.lupinBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.lupinBorder, lineWidth: 1)
                                            )
                                    }
                                    
                                    Button(action: { pcConnection.controlMedia("toggle") }) {
                                        Image(systemName: "playpause.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.black)
                                            .frame(maxWidth: .infinity)
                                            .padding(10)
                                            .background(Color.lupinAccent)
                                            .cornerRadius(4)
                                    }
                                    
                                    Button(action: { pcConnection.controlMedia("next") }) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 22))
                                            .foregroundColor(.lupinAccent)
                                            .frame(maxWidth: .infinity)
                                            .padding(10)
                                            .background(Color.lupinBackground)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(Color.lupinBorder, lineWidth: 1)
                                            )
                                    }
                                }
                                
                                HStack(spacing: 8) {
                                    TextField("Поиск музыки...", text: $musicQuery)
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.lupinBackground)
                                        .cornerRadius(4)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.lupinBorder, lineWidth: 1)
                                        )
                                    
                                    Button("SEARCH") {
                                        if !musicQuery.isEmpty {
                                            pcConnection.searchMusic(musicQuery)
                                        }
                                    }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                }
                            }
                            
                            // Tor Control
                            SectionView(title: "TOR CONTROL") {
                                HStack(spacing: 8) {
                                    Button("CONNECT") {
                                        pcConnection.controlTor("connect")
                                    }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                    
                                    Button("DISCONNECT") {
                                        pcConnection.controlTor("disconnect")
                                    }
                                    .buttonStyle(LupinButtonStyle(isDanger: true))
                                    
                                    Button("NEW ID") {
                                        pcConnection.controlTor("new_identity")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                }
                            }
                            
                            // Volume
                            SectionView(title: "VOLUME: \(Int(volume))%") {
                                Slider(value: $volume, in: 0...100) { editing in
                                    if !editing {
                                        pcConnection.controlVolume(Int(volume))
                                    }
                                }
                                .tint(.lupinAccent)
                            }
                            
                            // Screenshot
                            SectionView(title: "SCREENSHOT") {
                                Button("TAKE SCREENSHOT") {
                                    pcConnection.takeScreenshot()
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                                
                                if let screenshot = pcConnection.screenshot {
                                    Image(uiImage: screenshot)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 200)
                                        .cornerRadius(4)
                                }
                            }
                            
                            // Quick Launch
                            SectionView(title: "QUICK LAUNCH") {
                                HStack(spacing: 8) {
                                    Button("CHROME") {
                                        pcConnection.launchApp("chrome")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                    
                                    Button("NOTEPAD") {
                                        pcConnection.launchApp("notepad")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                    
                                    Button("EXPLORER") {
                                        pcConnection.launchApp("explorer")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                    
                                    Button("CMD") {
                                        pcConnection.launchApp("cmd")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                }
                            }
                            
                            // Power Control
                            SectionView(title: "POWER CONTROL") {
                                HStack(spacing: 8) {
                                    Button("LOCK") {
                                        pcConnection.powerControl("lock")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                    
                                    Button("SLEEP") {
                                        pcConnection.powerControl("sleep")
                                    }
                                    .buttonStyle(LupinButtonStyle())
                                    
                                    Button("REBOOT") {
                                        pcConnection.powerControl("reboot")
                                    }
                                    .buttonStyle(LupinButtonStyle(isDanger: true))
                                    
                                    Button("SHUTDOWN") {
                                        pcConnection.powerControl("shutdown")
                                    }
                                    .buttonStyle(LupinButtonStyle(isDanger: true))
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("PC CONTROL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("CLOSE") { dismiss() }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.lupinAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Binding var apiKey: String
    @ObservedObject var pcConnection: PCServerConnection
    @Environment(\.dismiss) var dismiss
    @State private var draftKey: String = ""
    @State private var draftIP: String = ""
    @State private var draftPort: String = ""
    @State private var draftToken: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionView(title: "DEEPSEEK API KEY") {
                            SecureField("sk-...", text: $draftKey)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.lupinBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.lupinBorder, lineWidth: 1)
                                )
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            Text("Ключ хранится только на этом устройстве (AppStorage) и вводится один раз.")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.lupinTextDim)
                        }
                        
                        SectionView(title: "PC CONNECTION") {
                            TextField("PC IP Address", text: $draftIP)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.lupinBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.lupinBorder, lineWidth: 1)
                                )
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            TextField("Port", text: $draftPort)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.lupinBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.lupinBorder, lineWidth: 1)
                                )
                                .keyboardType(.numberPad)
                            
                            SecureField("Auth Token", text: $draftToken)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.lupinBackground)
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.lupinBorder, lineWidth: 1)
                                )
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Для подключения к ПК убедитесь, что:")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.lupinTextDim)
                                Text("• LUPIN SUITE запущен на ПК")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.lupinTextDim)
                                Text("• Оба устройства в одной Wi-Fi сети")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.lupinTextDim)
                                Text("• Порт 8080 не заблокирован")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.lupinTextDim)
                            }
                        }
                        
                        Button(action: {
                            apiKey = draftKey
                            pcConnection.pcIP = draftIP
                            pcConnection.pcPort = draftPort
                            pcConnection.authToken = draftToken
                            dismiss()
                        }) {
                            Text("СОХРАНИТЬ")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.lupinAccent)
                                .cornerRadius(4)
                        }
                        .disabled(draftKey.isEmpty && draftIP.isEmpty)
                    }
                    .padding()
                }
            }
            .navigationTitle("НАСТРОЙКИ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ЗАКРЫТЬ") { dismiss() }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.lupinAccent)
                }
            }
        }
        .onAppear {
            draftKey = apiKey
            draftIP = pcConnection.pcIP
            draftPort = pcConnection.pcPort
            draftToken = pcConnection.authToken
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - App Entry Point
@main
struct LupinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
