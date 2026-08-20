import SwiftUI
import AVFoundation
import Speech

// MARK: - Telegram Connection
class TelegramConnection: ObservableObject {
    @Published var isConnected = false
    @Published var lastResponse = ""
    @Published var systemInfo = ""
    @Published var screenshot: UIImage?
    
    private var botToken = "8602600416:AAGgYHxYL9hbyqlQdxPIPFXYIspZoUoeN8s"
    // Жестко зашитый chat_id - замените на ваш после первого сообщения боту
    private var chatId: Int64 = 7106785409 // 0 = автоопределение
    
    private var apiBase: String {
        return "https://api.telegram.org/bot\(botToken)"
    }
    private var lastUpdateId: Int64 = 0
    private var pollingTimer: Timer?
    private var isPolling = false
    
    init() {
        // Пытаемся получить chat_id при запуске
        fetchChatId()
        startPolling()
    }
    
    // MARK: - Fetch Chat ID
    func fetchChatId() {
        let urlString = "\(apiBase)/getUpdates"
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else {
                return
            }
            
            // Ищем последнее сообщение с chat_id
            for update in result.reversed() {
                if let message = update["message"] as? [String: Any],
                   let chat = message["chat"] as? [String: Any],
                   let id = chat["id"] as? Int64 {
                    DispatchQueue.main.async {
                        self.chatId = id
                        print("📱 Chat ID found: \(id)")
                    }
                    break
                }
            }
        }.resume()
    }
    
    // MARK: - Send Message
    func sendCommand(_ text: String, completion: ((Bool, String) -> Void)? = nil) {
        guard !text.isEmpty else { return }
        
        // Если chat_id не найден, пытаемся получить
        if chatId == 0 {
            fetchChatId()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.performSend(text: text, completion: completion)
            }
        } else {
            performSend(text: text, completion: completion)
        }
    }
    
    private func performSend(text: String, completion: ((Bool, String) -> Void)? = nil) {
        guard chatId != 0 else {
            DispatchQueue.main.async {
                self.lastResponse = "❌ Chat ID не найден. Отправьте любое сообщение боту в Telegram!"
                completion?(false, self.lastResponse)
            }
            return
        }
        
        let urlString = "\(apiBase)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "parse_mode": "HTML"
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        print("📤 Sending to chat \(chatId): \(text)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error {
                    self.lastResponse = "❌ Ошибка: \(error.localizedDescription)"
                    print("❌ Send error: \(error)")
                    completion?(false, self.lastResponse)
                    return
                }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    if let ok = json["ok"] as? Bool, ok {
                        self.lastResponse = "✅ Команда отправлена"
                        print("✅ Message sent successfully")
                        completion?(true, self.lastResponse)
                    } else {
                        let description = json["description"] as? String ?? "Unknown error"
                        self.lastResponse = "❌ \(description)"
                        print("❌ API error: \(description)")
                        completion?(false, self.lastResponse)
                    }
                } else {
                    self.lastResponse = "❌ Ошибка отправки"
                    completion?(false, self.lastResponse)
                }
            }
        }.resume()
    }
    
    // MARK: - Start Polling
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        isConnected = true
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkUpdates()
        }
        
        print("📱 Polling started")
    }
    
    func stopPolling() {
        isPolling = false
        isConnected = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        print("📱 Polling stopped")
    }
    
    private func checkUpdates() {
        let urlString = "\(apiBase)/getUpdates?offset=\(lastUpdateId + 1)&timeout=10"
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            if let ok = json["ok"] as? Bool, ok,
               let result = json["result"] as? [[String: Any]] {
                
                for update in result {
                    if let updateId = update["update_id"] as? Int64 {
                        self.lastUpdateId = updateId
                    }
                    
                    if let message = update["message"] as? [String: Any],
                       let chat = message["chat"] as? [String: Any],
                       let id = chat["id"] as? Int64 {
                        DispatchQueue.main.async {
                            self.chatId = id
                        }
                    }
                    
                    if let message = update["message"] as? [String: Any],
                       let text = message["text"] as? String {
                        DispatchQueue.main.async {
                            print("📥 Received: \(text)")
                            self.lastResponse = text
                        }
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Voice Commands
    func sendVoiceCommand(_ text: String) {
        sendCommand("🎤 \(text)")
    }
    
    func sendTextMessage(_ text: String) {
        sendCommand(text)
    }
    
    func requestSystemInfo() {
        sendCommand("/system_info")
    }
    
    func controlMedia(_ action: String) {
        let commands = [
            "prev": "предыдущий трек",
            "toggle": "пауза",
            "next": "следующий трек"
        ]
        if let command = commands[action] {
            sendCommand(command)
        }
    }
    
    func searchMusic(_ query: String) {
        sendCommand("включи \(query)")
    }
    
    func controlTor(_ action: String) {
        let commands = [
            "connect": "включи тор",
            "disconnect": "выключи тор",
            "new_identity": "новая личность"
        ]
        if let command = commands[action] {
            sendCommand(command)
        }
    }
    
    func takeScreenshot() {
        sendCommand("сделай скриншот")
    }
    
    func controlVolume(_ volume: Int) {
        sendCommand("громкость \(volume)")
    }
    
    func launchApp(_ app: String) {
        let commands = [
            "chrome": "открой хром",
            "notepad": "открой блокнот",
            "explorer": "открой проводник",
            "cmd": "открой командную строку"
        ]
        if let command = commands[app] {
            sendCommand(command)
        }
    }
    
    func powerControl(_ action: String) {
        let commands = [
            "lock": "заблокируй пк",
            "sleep": "спящий режим",
            "reboot": "перезагрузи пк",
            "shutdown": "выключи пк"
        ]
        if let command = commands[action] {
            sendCommand(command)
        }
    }
    
    func switchAudioDevice(_ device: String) {
        let commands = [
            "speaker": "на колонку",
            "headphones": "на наушники"
        ]
        if let command = commands[device] {
            sendCommand(command)
        }
    }
}

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
    @Published var telegramConnection: TelegramConnection?
    
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
        if sendToPC, let tgConnection = telegramConnection, tgConnection.isConnected {
            tgConnection.sendVoiceCommand(prompt)
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

// MARK: - Colors Extension
extension Color {
    static let lupinAccent = Color(red: 0.85, green: 0.88, blue: 0.0)
    static let lupinAccentHover = Color(red: 0.69, green: 0.72, blue: 0.0)
    static let lupinBackground = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let lupinPanel = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let lupinBorder = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let lupinText = Color(red: 0.72, green: 0.72, blue: 0.72)
    static let lupinTextDim = Color(red: 0.40, green: 0.40, blue: 0.40)
    static let lupinRed = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let lupinGreen = Color(red: 0.27, green: 1.0, blue: 0.27)
    static let lupinOrange = Color(red: 1.0, green: 0.53, blue: 0.0)
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
    @StateObject var telegramConnection = TelegramConnection()
    @State private var showSettings = false
    @State private var showPCControls = false
    @State private var textInput = ""
    @State private var showTextInput = false

    var body: some View {
        ZStack {
            Color.lupinBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
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

                PixelLupinView(isListening: assistant.isListening, isSpeaking: assistant.isSpeaking)
                    .padding(.top, 4)

                HStack(spacing: 12) {
                    Button(action: { showPCControls.toggle() }) {
                        HStack {
                            Circle()
                                .fill(telegramConnection.isConnected ? Color.lupinGreen : Color.lupinRed)
                                .frame(width: 8, height: 8)
                            Text(telegramConnection.isConnected ? "TG ONLINE" : "TG OFFLINE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(telegramConnection.isConnected ? .lupinGreen : .lupinRed)
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

                SectionView(title: "ВХОДЯЩИЙ ПОТОК:") {
                    Text(assistant.recognizedText)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)

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

                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        if telegramConnection.isConnected {
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
            SettingsView(apiKey: $assistant.apiKey, telegramConnection: telegramConnection)
        }
        .sheet(isPresented: $showPCControls) {
            PCControlView(telegramConnection: telegramConnection)
        }
        .onAppear {
            assistant.telegramConnection = telegramConnection
        }
    }
    
    private func sendTextCommand() {
        guard !textInput.isEmpty else { return }
        
        let command = textInput
        textInput = ""
        
        print("📱 Sending command: \(command)")
        
        telegramConnection.sendCommand(command) { success, response in
            if success {
                assistant.assistantReply = "✅ Отправлено на ПК: \(command)"
            } else {
                assistant.assistantReply = response
            }
        }
    }
}

// MARK: - PC Control View
struct PCControlView: View {
    @ObservedObject var telegramConnection: TelegramConnection
    @Environment(\.dismiss) var dismiss
    @State private var volume: Double = 50
    @State private var musicQuery = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 12) {
                        SectionView(title: "CONNECTION") {
                            VStack(spacing: 8) {
                                Text("Telegram Bot Connection")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                
                                Text("Status: \(telegramConnection.isConnected ? "ONLINE" : "OFFLINE")")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(telegramConnection.isConnected ? .lupinGreen : .lupinRed)
                                
                                Button("REFRESH CHAT ID") {
                                    telegramConnection.fetchChatId()
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                            }
                        }
                        
                        SectionView(title: "SYSTEM INFO") {
                            Text(telegramConnection.systemInfo)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(nil)
                            
                            Button("REFRESH INFO") {
                                telegramConnection.requestSystemInfo()
                            }
                            .buttonStyle(LupinButtonStyle(isActive: true))
                        }
                        
                        SectionView(title: "MEDIA CONTROL") {
                            HStack(spacing: 20) {
                                Button(action: { telegramConnection.controlMedia("prev") }) {
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
                                
                                Button(action: { telegramConnection.controlMedia("toggle") }) {
                                    Image(systemName: "playpause.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinAccent)
                                        .cornerRadius(4)
                                }
                                
                                Button(action: { telegramConnection.controlMedia("next") }) {
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
                                        telegramConnection.searchMusic(musicQuery)
                                    }
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                            }
                        }
                        
                        SectionView(title: "TOR CONTROL") {
                            HStack(spacing: 8) {
                                Button("CONNECT") {
                                    telegramConnection.controlTor("connect")
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                                
                                Button("DISCONNECT") {
                                    telegramConnection.controlTor("disconnect")
                                }
                                .buttonStyle(LupinButtonStyle(isDanger: true))
                                
                                Button("NEW ID") {
                                    telegramConnection.controlTor("new_identity")
                                }
                                .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "VOLUME: \(Int(volume))%") {
                            Slider(value: $volume, in: 0...100) { editing in
                                if !editing {
                                    telegramConnection.controlVolume(Int(volume))
                                }
                            }
                            .tint(.lupinAccent)
                        }
                        
                        SectionView(title: "SCREENSHOT") {
                            Button("TAKE SCREENSHOT") {
                                telegramConnection.takeScreenshot()
                            }
                            .buttonStyle(LupinButtonStyle(isActive: true))
                        }
                        
                        SectionView(title: "QUICK LAUNCH") {
                            HStack(spacing: 8) {
                                Button("CHROME") {
                                    telegramConnection.launchApp("chrome")
                                }
                                .buttonStyle(LupinButtonStyle())
                                
                                Button("NOTEPAD") {
                                    telegramConnection.launchApp("notepad")
                                }
                                .buttonStyle(LupinButtonStyle())
                                
                                Button("EXPLORER") {
                                    telegramConnection.launchApp("explorer")
                                }
                                .buttonStyle(LupinButtonStyle())
                                
                                Button("CMD") {
                                    telegramConnection.launchApp("cmd")
                                }
                                .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "POWER CONTROL") {
                            HStack(spacing: 8) {
                                Button("LOCK") {
                                    telegramConnection.powerControl("lock")
                                }
                                .buttonStyle(LupinButtonStyle())
                                
                                Button("SLEEP") {
                                    telegramConnection.powerControl("sleep")
                                }
                                .buttonStyle(LupinButtonStyle())
                                
                                Button("REBOOT") {
                                    telegramConnection.powerControl("reboot")
                                }
                                .buttonStyle(LupinButtonStyle(isDanger: true))
                                
                                Button("SHUTDOWN") {
                                    telegramConnection.powerControl("shutdown")
                                }
                                .buttonStyle(LupinButtonStyle(isDanger: true))
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
    @ObservedObject var telegramConnection: TelegramConnection
    @Environment(\.dismiss) var dismiss
    @State private var draftKey: String = ""

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
                            
                            Text("Ключ хранится только на этом устройстве (AppStorage).")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.lupinTextDim)
                        }
                        
                        SectionView(title: "TELEGRAM CONNECTION") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bot Token: 8602600416:AAGg...")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.lupinTextDim)
                                Text("Статус: \(telegramConnection.isConnected ? "ONLINE" : "OFFLINE")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(telegramConnection.isConnected ? .lupinGreen : .lupinRed)
                            }
                        }
                        
                        Button(action: {
                            apiKey = draftKey
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
