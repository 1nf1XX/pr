import SwiftUI
import AVFoundation
import Speech
import Network

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
    
    // PC Connection
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
        // Если нужно отправить на ПК
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
            return
        }
        
        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        
        // Авторизация
        let authMessage: [String: Any] = ["auth": authToken]
        sendJSON(authMessage)
        
        isConnected = true
        startListening()
    }
    
    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        isConnected = false
    }
    
    private func sendJSON(_ data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
            }
        }
    }
    
    private func startListening() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    DispatchQueue.main.async {
                        self?.handleResponse(text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async {
                            self?.handleResponse(text)
                        }
                    }
                @unknown default:
                    break
                }
                self?.startListening()
            case .failure(let error):
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
    
    // Команды для отправки на ПК
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
    
    func getProcessList() {
        sendJSON(["command": "process_list"])
    }
    
    func killProcess(pid: Int) {
        sendJSON([
            "command": "kill_process",
            "params": ["pid": pid]
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
    static let lupinAccent = Color(red: 0.95, green: 0.9, blue: 0.2)
    static let lupinBackground = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let lupinPanel = Color(red: 0.12, green: 0.12, blue: 0.15)
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
        case 1: return Color(red: 0.16, green: 0.16, blue: 0.19)
        case 2: return Color(red: 0.86, green: 0.72, blue: 0.55)
        case 3: return Color(red: 0.14, green: 0.14, blue: 0.18)
        case 4: return Color(red: 0.09, green: 0.09, blue: 0.12)
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

            VStack(spacing: 20) {
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
                                .foregroundColor(.gray)
                        }
                        .padding(.trailing)
                    }
                )
                .padding(.top, 10)

                PixelLupinView(isListening: assistant.isListening, isSpeaking: assistant.isSpeaking)
                    .padding(.top, 4)

                // PC Connection Status
                HStack {
                    Button(action: { showPCControls.toggle() }) {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 14))
                            Text(pcConnection.isConnected ? "PC ONLINE" : "PC OFFLINE")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(pcConnection.isConnected ? .green : .gray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.lupinPanel)
                        .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    // Text Input Toggle
                    Button(action: { showTextInput.toggle() }) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 16))
                            .foregroundColor(.lupinAccent)
                            .padding(8)
                            .background(Color.lupinPanel)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal)

                // Text Input Field
                if showTextInput {
                    HStack {
                        TextField("Введите команду...", text: $textInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.send)
                            .onSubmit {
                                sendTextCommand()
                            }
                        
                        Button(action: sendTextCommand) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.lupinAccent)
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ВХОДЯЩИЙ ПОТОК:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Text(assistant.recognizedText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color.lupinPanel)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.lupinAccent.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal)

                if assistant.micAccessDenied {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Микрофон заблокирован. Разреши доступ в Настройках iOS.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ОТВЕТ ЯДРА:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    if assistant.isProcessing {
                        ProgressView()
                            .tint(.lupinAccent)
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
                .padding()
                .background(Color.lupinPanel)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.lupinAccent, lineWidth: 1)
                )
                .padding(.horizontal)

                Spacer()

                // Microphone Button
                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        // Send to PC if connected, otherwise to DeepSeek
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
                        .background(assistant.isListening ? Color.red : Color.lupinAccent)
                        .clipShape(Circle())
                        .shadow(color: (assistant.isListening ? Color.red : Color.lupinAccent).opacity(0.5), radius: 10)
                }

                Text(assistant.isListening ? "ИДЕТ ЗАПИСЬ..." : "НАЖМИ ДЛЯ ВВОДА")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
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
        
        // Send to PC if connected, otherwise to DeepSeek
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
    @State private var showScreenshot = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 15) {
                        // Connection Settings
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CONNECTION")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            VStack(spacing: 8) {
                                TextField("PC IP Address", text: $pcConnection.pcIP)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                
                                TextField("Port", text: $pcConnection.pcPort)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .keyboardType(.numberPad)
                                
                                SecureField("Auth Token", text: $pcConnection.authToken)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                                
                                Button(action: {
                                    if pcConnection.isConnected {
                                        pcConnection.disconnect()
                                    } else {
                                        pcConnection.connect()
                                    }
                                }) {
                                    Text(pcConnection.isConnected ? "DISCONNECT" : "CONNECT")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(pcConnection.isConnected ? Color.red : Color.green)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding()
                        .background(Color.lupinPanel)
                        .cornerRadius(10)
                        
                        // System Info
                        if pcConnection.isConnected {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("SYSTEM INFO")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Text(pcConnection.systemInfo)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.white)
                                    .lineLimit(nil)
                                
                                Button("Refresh Info") {
                                    pcConnection.requestSystemInfo()
                                }
                                .foregroundColor(.lupinAccent)
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Media Control
                            VStack(spacing: 10) {
                                Text("MEDIA CONTROL")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 30) {
                                    Button(action: { pcConnection.controlMedia("prev") }) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 25))
                                            .foregroundColor(.lupinAccent)
                                    }
                                    
                                    Button(action: { pcConnection.controlMedia("toggle") }) {
                                        Image(systemName: "playpause.fill")
                                            .font(.system(size: 25))
                                            .foregroundColor(.lupinAccent)
                                    }
                                    
                                    Button(action: { pcConnection.controlMedia("next") }) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 25))
                                            .foregroundColor(.lupinAccent)
                                    }
                                }
                                
                                // Music Search
                                HStack {
                                    TextField("Поиск музыки...", text: $musicQuery)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .font(.system(size: 14, design: .monospaced))
                                    
                                    Button("Search") {
                                        if !musicQuery.isEmpty {
                                            pcConnection.searchMusic(musicQuery)
                                        }
                                    }
                                    .foregroundColor(.lupinAccent)
                                }
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Tor Control
                            VStack(spacing: 10) {
                                Text("TOR CONTROL")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 10) {
                                    Button("Connect") {
                                        pcConnection.controlTor("connect")
                                    }
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Disconnect") {
                                        pcConnection.controlTor("disconnect")
                                    }
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("New Identity") {
                                        pcConnection.controlTor("new_identity")
                                    }
                                    .foregroundColor(.lupinAccent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                }
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Volume Control
                            VStack(spacing: 10) {
                                Text("VOLUME: \(Int(volume))%")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Slider(value: $volume, in: 0...100) { editing in
                                    if !editing {
                                        pcConnection.controlVolume(Int(volume))
                                    }
                                }
                                .tint(.lupinAccent)
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Screenshot
                            VStack(spacing: 10) {
                                Text("SCREENSHOT")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                Button("Take Screenshot") {
                                    pcConnection.takeScreenshot()
                                }
                                .foregroundColor(.lupinAccent)
                                .padding()
                                .background(Color.lupinPanel)
                                .cornerRadius(8)
                                
                                if let screenshot = pcConnection.screenshot {
                                    Image(uiImage: screenshot)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 200)
                                        .cornerRadius(8)
                                }
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Quick Launch Apps
                            VStack(spacing: 10) {
                                Text("QUICK LAUNCH")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 10) {
                                    Button("Chrome") {
                                        pcConnection.launchApp("chrome")
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Notepad") {
                                        pcConnection.launchApp("notepad")
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Explorer") {
                                        pcConnection.launchApp("explorer")
                                    }
                                    .foregroundColor(.yellow)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("CMD") {
                                        pcConnection.launchApp("cmd")
                                    }
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                }
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                            
                            // Power Control
                            VStack(spacing: 10) {
                                Text("POWER CONTROL")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 10) {
                                    Button("Lock") {
                                        pcConnection.powerControl("lock")
                                    }
                                    .foregroundColor(.yellow)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Sleep") {
                                        pcConnection.powerControl("sleep")
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Reboot") {
                                        pcConnection.powerControl("reboot")
                                    }
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                    
                                    Button("Shutdown") {
                                        pcConnection.powerControl("shutdown")
                                    }
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(5)
                                }
                            }
                            .padding()
                            .background(Color.lupinPanel)
                            .cornerRadius(10)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("PC CONTROL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
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
                        Text("DEEPSEEK API KEY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)

                        SecureField("sk-...", text: $draftKey)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.lupinPanel)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .font(.system(size: 14, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Text("Ключ хранится только на этом устройстве (AppStorage) и вводится один раз.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)

                        Divider()
                            .background(Color.gray.opacity(0.3))

                        Text("PC CONNECTION")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)

                        TextField("PC IP Address", text: $draftIP)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.lupinPanel)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .font(.system(size: 14, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        TextField("Port", text: $draftPort)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.lupinPanel)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .font(.system(size: 14, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .keyboardType(.numberPad)

                        SecureField("Auth Token", text: $draftToken)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.lupinPanel)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .font(.system(size: 14, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Text("Для подключения к ПК убедитесь, что:")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                        Text("• LUPIN SUITE запущен на ПК")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                        Text("• Оба устройства в одной Wi-Fi сети")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                        Text("• Порт 8080 не заблокирован")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)

                        Spacer()

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
                                .cornerRadius(8)
                        }
                        .disabled(draftKey.isEmpty && draftIP.isEmpty)
                    }
                    .padding()
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") { dismiss() }
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
