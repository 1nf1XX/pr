import SwiftUI
import AVFoundation
import Speech
import UIKit

// MARK: - Telegram Bot Connection
class TelegramBotConnection: ObservableObject {
    @Published var isConnected = true
    @Published var lastResponse = ""
    @Published var botReply = "Ожидание ответа..."
    
    private var botToken = "8602600416:AAGgYHxYL9hbyqlQdxPIPFXYIspZoUoeN8s"
    private var chatId: Int64 = 7106785409
    private var lastUpdateId: Int64 = 0
    private var pollingTimer: Timer?
    private var isPolling = false
    
    init() {
        startPolling()
    }
    
    // MARK: - Отправка команды
    func sendCommand(_ text: String, completion: ((Bool, String) -> Void)? = nil) {
        let urlString = "https://api.telegram.org/bot\(botToken)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        print("📤 Sending: \(text)")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.lastResponse = "❌ \(error.localizedDescription)"
                    completion?(false, self?.lastResponse ?? "")
                    return
                }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok {
                    self?.lastResponse = "✅ Отправлено"
                    completion?(true, "✅ Отправлено")
                } else {
                    self?.lastResponse = "❌ Ошибка API"
                    completion?(false, "❌ Ошибка")
                }
            }
        }.resume()
    }
    
    // MARK: - Polling ответов
    func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkUpdates()
        }
    }
    
    func stopPolling() {
        isPolling = false
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
    
    private func checkUpdates() {
        let urlString = "https://api.telegram.org/bot\(botToken)/getUpdates?offset=\(lastUpdateId + 1)&timeout=5"
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else {
                return
            }
            
            for update in result {
                if let updateId = update["update_id"] as? Int64 {
                    self.lastUpdateId = updateId
                }
                
                if let message = update["message"] as? [String: Any],
                   let text = message["text"] as? String {
                    DispatchQueue.main.async {
                        print("📥 Bot reply: \(text)")
                        self.botReply = text
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Все команды
    func sendVoiceCommand(_ text: String) { sendCommand(text) }
    func sendTextMessage(_ text: String) { sendCommand(text) }
    func requestSystemInfo() { sendCommand("инфо") }
    func getProcessList() { sendCommand("процессы") }
    
    func controlMedia(_ action: String) {
        let commands = ["prev": "предыдущий трек", "toggle": "пауза", "next": "следующий трек"]
        if let cmd = commands[action] { sendCommand(cmd) }
    }
    
    func searchMusic(_ query: String) { sendCommand("включи \(query)") }
    
    func controlTor(_ action: String) {
        let commands = ["connect": "включи тор", "disconnect": "выключи тор"]
        if let cmd = commands[action] { sendCommand(cmd) }
    }
    
    func takeScreenshot() { sendCommand("скриншот") }
    func controlVolume(_ volume: Int) { sendCommand("громкость \(volume)") }
    
    func launchApp(_ app: String) {
        let commands = [
            "chrome": "открой хром", "notepad": "открой блокнот",
            "explorer": "открой проводник", "cmd": "открой cmd",
            "calculator": "открой калькулятор", "paint": "открой paint"
        ]
        if let cmd = commands[app] { sendCommand(cmd) }
    }
    
    func powerControl(_ action: String) {
        let commands = [
            "lock": "заблокируй пк", "sleep": "спящий режим",
            "reboot": "перезагрузи пк", "shutdown": "выключи пк"
        ]
        if let cmd = commands[action] { sendCommand(cmd) }
    }
    
    func switchAudioDevice(_ device: String) {
        let commands = ["speaker": "на колонку", "headphones": "на наушники"]
        if let cmd = commands[device] { sendCommand(cmd) }
    }
    
    func getWifiPasswords() { sendCommand("wifi пароли") }
    func generatePassword() { sendCommand("пароль") }
    func getIP() { sendCommand("ip адрес") }
    func clearTrash() { sendCommand("очистить корзину") }
    func clearClipboard() { sendCommand("очистить буфер") }
    func speakOnPC(_ text: String) { sendCommand("скажи \(text)") }
}

// MARK: - Voice Assistant
class VoiceAssistant: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private var synthesizer = AVSpeechSynthesizer()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    @Published var recognizedText = "Нажми на микрофон..."
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var micAccessDenied = false

    @Published var botConnection: TelegramBotConnection?
    
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

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = pickVoice()
        utterance.rate = 0.46
        utterance.pitchMultiplier = 0.78
        synthesizer.speak(utterance)
    }

    func sendVoiceToPC(_ text: String) {
        if let bot = botConnection {
            bot.sendVoiceCommand(text)
            speak("Команда отправлена")
        }
    }

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self.micAccessDenied = false
                    self.startRecording()
                } else {
                    self.micAccessDenied = true
                    self.recognizedText = "Доступ к микрофону заблокирован"
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

// MARK: - Colors
extension Color {
    static let lupinAccent = Color(red: 0.85, green: 0.88, blue: 0.0)
    static let lupinBackground = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let lupinPanel = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let lupinBorder = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let lupinText = Color(red: 0.72, green: 0.72, blue: 0.72)
    static let lupinTextDim = Color(red: 0.40, green: 0.40, blue: 0.40)
    static let lupinRed = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let lupinGreen = Color(red: 0.27, green: 1.0, blue: 0.27)
    static let lupinOrange = Color(red: 1.0, green: 0.53, blue: 0.0)
}

// MARK: - Button Style
struct LupinButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var isDanger: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(isActive ? .black : (isDanger ? .lupinRed : .lupinText))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.lupinAccent : Color.lupinPanel)
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.lupinBorder, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - Section
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
            content
        }
        .padding(12)
        .background(Color.lupinPanel)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.lupinBorder, lineWidth: 1))
    }
}

// MARK: - Pixel Face
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
        .shadow(color: Color.lupinAccent.opacity((isListening || isSpeaking) ? 0.5 : 0.15), radius: 10)
        .onReceive(mouthTimer) { _ in
            if isSpeaking { mouthOpen.toggle() }
        }
        .onReceive(bobTimer) { _ in
            withAnimation(.easeInOut(duration: 0.6)) { bobUp.toggle() }
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject var assistant = VoiceAssistant()
    @StateObject var botConnection = TelegramBotConnection()
    @State private var showPCControls = false
    @State private var textInput = ""
    @State private var showTextInput = false
    
    var body: some View {
        ZStack {
            Color.lupinBackground.ignoresSafeArea()
            
            VStack(spacing: 16) {
                Text("LUPIN // SUITE")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.lupinAccent)
                    .padding(.top, 10)
                
                PixelLupinView(isListening: assistant.isListening, isSpeaking: assistant.isSpeaking)
                
                HStack(spacing: 12) {
                    Button(action: { showPCControls.toggle() }) {
                        HStack {
                            Circle()
                                .fill(Color.lupinGreen)
                                .frame(width: 8, height: 8)
                            Text("PC CONTROL")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.lupinGreen)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.lupinPanel)
                        .cornerRadius(4)
                    }
                    
                    Spacer()
                    
                    Button(action: { showTextInput.toggle() }) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 16))
                            .foregroundColor(.lupinAccent)
                            .padding(8)
                            .background(Color.lupinPanel)
                            .cornerRadius(4)
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
                            .onSubmit { sendTextCommand() }
                        
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
                }
                .padding(.horizontal)
                
                SectionView(title: "ОТВЕТ БОТА:") {
                    ScrollView {
                        Text(botConnection.botReply)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.lupinAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(.horizontal)
                
                Spacer()
                
                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        assistant.sendVoiceToPC(assistant.recognizedText)
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
                }
                
                Text(assistant.isListening ? "ИДЕТ ЗАПИСЬ..." : "НАЖМИ ДЛЯ ВВОДА")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.lupinTextDim)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showPCControls) {
            PCControlView(botConnection: botConnection)
        }
        .onAppear {
            assistant.botConnection = botConnection
        }
    }
    
    private func sendTextCommand() {
        guard !textInput.isEmpty else { return }
        let command = textInput
        textInput = ""
        botConnection.sendCommand(command)
    }
}

// MARK: - PC Control View
struct PCControlView: View {
    @ObservedObject var botConnection: TelegramBotConnection
    @Environment(\.dismiss) var dismiss
    @State private var volume: Double = 50
    @State private var musicQuery = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 12) {
                        SectionView(title: "MEDIA CONTROL") {
                            HStack(spacing: 20) {
                                Button(action: { botConnection.controlMedia("prev") }) {
                                    Image(systemName: "backward.fill")
                                        .foregroundColor(.lupinAccent)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinPanel)
                                        .cornerRadius(4)
                                }
                                
                                Button(action: { botConnection.controlMedia("toggle") }) {
                                    Image(systemName: "playpause.fill")
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinAccent)
                                        .cornerRadius(4)
                                }
                                
                                Button(action: { botConnection.controlMedia("next") }) {
                                    Image(systemName: "forward.fill")
                                        .foregroundColor(.lupinAccent)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinPanel)
                                        .cornerRadius(4)
                                }
                            }
                            
                            HStack(spacing: 8) {
                                TextField("Поиск музыки...", text: $musicQuery)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.lupinPanel)
                                    .cornerRadius(4)
                                
                                Button("SEARCH") {
                                    if !musicQuery.isEmpty {
                                        botConnection.searchMusic(musicQuery)
                                    }
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                            }
                        }
                        
                        SectionView(title: "VOLUME: \(Int(volume))%") {
                            Slider(value: $volume, in: 0...100) { editing in
                                if !editing {
                                    botConnection.controlVolume(Int(volume))
                                }
                            }
                            .tint(.lupinAccent)
                        }
                        
                        SectionView(title: "SYSTEM") {
                            HStack(spacing: 8) {
                                Button("INFO") { botConnection.requestSystemInfo() }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("SCREENSHOT") { botConnection.takeScreenshot() }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("PROCESSES") { botConnection.getProcessList() }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "QUICK LAUNCH") {
                            HStack(spacing: 6) {
                                Button("CHROME") { botConnection.launchApp("chrome") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("NOTEPAD") { botConnection.launchApp("notepad") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("CMD") { botConnection.launchApp("cmd") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                            
                            HStack(spacing: 6) {
                                Button("EXPLORER") { botConnection.launchApp("explorer") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("CALC") { botConnection.launchApp("calculator") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("PAINT") { botConnection.launchApp("paint") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "AUDIO DEVICE") {
                            HStack(spacing: 8) {
                                Button("SPEAKER") { botConnection.switchAudioDevice("speaker") }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("HEADPHONES") { botConnection.switchAudioDevice("headphones") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "NETWORK") {
                            HStack(spacing: 8) {
                                Button("WIFI PASS") { botConnection.getWifiPasswords() }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("IP") { botConnection.getIP() }
                                    .buttonStyle(LupinButtonStyle())
                                Button("PASSWORD") { botConnection.generatePassword() }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "POWER") {
                            HStack(spacing: 8) {
                                Button("LOCK") { botConnection.powerControl("lock") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("SLEEP") { botConnection.powerControl("sleep") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("REBOOT") { botConnection.powerControl("reboot") }
                                    .buttonStyle(LupinButtonStyle(isDanger: true))
                                Button("SHUTDOWN") { botConnection.powerControl("shutdown") }
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
                        .foregroundColor(.lupinAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - App Entry
@main
struct LupinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
