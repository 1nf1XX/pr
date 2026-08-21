// LUPIN — единый файл (объединены: main app, история команд, макросы, локальные уведомления, Siri Shortcuts / App Intents)
import SwiftUI
import AVFoundation
import Speech
import UIKit
import UserNotifications
import Foundation
import Combine
import AppIntents

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

    /// Слабая ссылка на историю команд — так все кнопки (PC Control, макросы и т.д.)
    /// логируются в одном месте без переписывания каждого вызова.
    weak var historyStore: CommandHistoryStore?
    
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
                        // Локальное уведомление — сработает, пока приложение живо в фоне
                        // (не настоящий push, см. заметку в NotificationManager.swift)
                        NotificationManager.shared.notifyNow(title: "LUPIN", body: text)
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

// MARK: - Voice Assistant с DeepSeek ИИ
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
    @Published var botConnection: TelegramBotConnection?
    
    private var chatHistory: [[String: String]] = []
    
    override init() {
        super.init()
        synthesizer.delegate = self
        chatHistory.append([
            "role": "system",
            "content": "Тебя зовут LUPIN — ИИ-ассистент. Стиль общения: сдержанный, точный, слегка ироничный, как у безупречного личного помощника. Отвечай по делу, кратко, без грубости. Лёгкий налёт элегантности и остроумия уместен, хамство — нет."
        ])
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
            print("Audio session error: \(error)")
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

    // MARK: - Отправка в DeepSeek
    func sendToDeepSeek(prompt: String, sendToPC: Bool = false) {
        // Если нужно отправить на ПК
        if sendToPC, let bot = botConnection {
            bot.sendVoiceCommand(prompt)
            DispatchQueue.main.async {
                self.assistantReply = "Команда отправлена на ПК: \(prompt)"
                self.speak(self.assistantReply)
            }
            return
        }
        
        // Иначе — DeepSeek
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.assistantReply = "Ключ DeepSeek не задан. Открой настройки."
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

        // Добавляем сообщение в историю
        chatHistory.append(["role": "user", "content": prompt])
        
        // Ограничиваем историю
        if chatHistory.count > 11 {
            chatHistory = [chatHistory[0]] + chatHistory.suffix(10)
        }

        let requestBody: [String: Any] = [
            "model": "deepseek-chat",
            "messages": chatHistory,
            "stream": false
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        DispatchQueue.main.async { self.isProcessing = true }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { self.isProcessing = false }

            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                DispatchQueue.main.async {
                    self.assistantReply = "Ошибка сервера: код \(httpResponse.statusCode). Проверь ключ."
                }
                return
            }

            guard let data = data, error == nil else {
                DispatchQueue.main.async {
                    self.assistantReply = "Сетевая ошибка соединения."
                }
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {

                DispatchQueue.main.async {
                    self.assistantReply = content
                    self.chatHistory.append(["role": "assistant", "content": content])
                    self.speak(content)
                }
            } else {
                DispatchQueue.main.async {
                    self.assistantReply = "Ошибка парсинга ответа API."
                }
            }
        }.resume()
    }

    // MARK: - Голосовой ввод
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
    @StateObject var historyStore = CommandHistoryStore()
    @State private var showPCControls = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showMacros = false
    @State private var textInput = ""
    @State private var showTextInput = false
    
    var body: some View {
        ZStack {
            Color.lupinBackground.ignoresSafeArea()
            
            VStack(spacing: 16) {
                HStack {
                    Text("LUPIN // SUITE")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.lupinAccent)
                    
                    Spacer()

                    HStack(spacing: 16) {
                        Button(action: { showMacros = true }) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.lupinTextDim)
                        }

                        Button(action: { showHistory = true }) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16))
                                .foregroundColor(.lupinTextDim)
                        }

                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.lupinTextDim)
                        }
                    }
                }
                .padding(.horizontal)
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
                        TextField("Вопрос или команда...", text: $textInput)
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
                
                SectionView(title: "ОТВЕТ ИИ:") {
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
                        .frame(maxHeight: 120)
                    }
                }
                .padding(.horizontal)
                
                SectionView(title: "ОТВЕТ БОТА (ПК):") {
                    ScrollView {
                        Text(botConnection.botReply)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.lupinGreen)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
                .padding(.horizontal)
                
                Spacer()
                
                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        // Отправляем голос в ИИ
                        historyStore.log(assistant.recognizedText, source: "voice")
                        assistant.sendToDeepSeek(prompt: assistant.recognizedText)
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
        .sheet(isPresented: $showPCControls) {
            PCControlView(botConnection: botConnection, historyStore: historyStore)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(apiKey: $assistant.apiKey)
        }
        .sheet(isPresented: $showHistory) {
            CommandHistoryView(historyStore: historyStore)
        }
        .sheet(isPresented: $showMacros) {
            MacrosView(botConnection: botConnection, historyStore: historyStore)
        }
        .onAppear {
            assistant.botConnection = botConnection
            botConnection.historyStore = historyStore
            NotificationManager.shared.requestAuthorization()
            if assistant.apiKey.isEmpty {
                showSettings = true
            }
        }
    }
    
    private func sendTextCommand() {
        guard !textInput.isEmpty else { return }
        let text = textInput
        textInput = ""
        
        // Проверяем: это команда для ПК или вопрос для ИИ?
        let pcCommands = ["открой", "пауза", "следующ", "предыдущ", "громкость", "выключи", "перезагрузи", "заблокируй", "скриншот", "инфо", "процессы", "wifi", "пароль", "ip", "корзин", "буфер", "скажи", "включи"]
        
        let isPCCommand = pcCommands.contains { text.lowercased().contains($0) }
        
        if isPCCommand {
            botConnection.sendCommand(text)
            historyStore.log(text, source: "text")
            assistant.assistantReply = "Команда отправлена на ПК: \(text)"
        } else {
            assistant.sendToDeepSeek(prompt: text)
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    @State private var draftKey: String = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                VStack(spacing: 16) {
                    SectionView(title: "DEEPSEEK API KEY") {
                        SecureField("sk-...", text: $draftKey)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.lupinPanel)
                            .cornerRadius(4)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(.horizontal)
                    
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
                    .padding(.horizontal)
                    
                    Spacer()
                }
                .padding(.top, 20)
            }
            .navigationTitle("НАСТРОЙКИ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ЗАКРЫТЬ") { dismiss() }
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

// MARK: - PC Control View
struct PCControlView: View {
    @ObservedObject var botConnection: TelegramBotConnection
    @ObservedObject var historyStore: CommandHistoryStore
    @Environment(\.dismiss) var dismiss
    @State private var volume: Double = 50
    @State private var musicQuery = ""

    private func log(_ text: String) {
        historyStore.log(text, source: "button")
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 12) {
                        SectionView(title: "MEDIA CONTROL") {
                            HStack(spacing: 20) {
                                Button(action: { botConnection.controlMedia("prev"); log("предыдущий трек") }) {
                                    Image(systemName: "backward.fill")
                                        .foregroundColor(.lupinAccent)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinPanel)
                                        .cornerRadius(4)
                                }
                                
                                Button(action: { botConnection.controlMedia("toggle"); log("пауза") }) {
                                    Image(systemName: "playpause.fill")
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(10)
                                        .background(Color.lupinAccent)
                                        .cornerRadius(4)
                                }
                                
                                Button(action: { botConnection.controlMedia("next"); log("следующий трек") }) {
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
                                        botConnection.searchMusic(musicQuery); log("включи \(musicQuery)")
                                    }
                                }
                                .buttonStyle(LupinButtonStyle(isActive: true))
                            }
                        }
                        
                        SectionView(title: "VOLUME: \(Int(volume))%") {
                            Slider(value: $volume, in: 0...100) { editing in
                                if !editing {
                                    botConnection.controlVolume(Int(volume)); log("громкость \(Int(volume))")
                                }
                            }
                            .tint(.lupinAccent)
                        }
                        
                        SectionView(title: "SYSTEM") {
                            HStack(spacing: 8) {
                                Button("INFO") { botConnection.requestSystemInfo(); log("инфо") }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("SCREENSHOT") { botConnection.takeScreenshot(); log("скриншот") }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("PROCESSES") { botConnection.getProcessList(); log("процессы") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "QUICK LAUNCH") {
                            HStack(spacing: 6) {
                                Button("CHROME") { botConnection.launchApp("chrome"); log("открой хром") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("NOTEPAD") { botConnection.launchApp("notepad"); log("открой блокнот") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("CMD") { botConnection.launchApp("cmd"); log("открой cmd") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                            
                            HStack(spacing: 6) {
                                Button("EXPLORER") { botConnection.launchApp("explorer"); log("открой проводник") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("CALC") { botConnection.launchApp("calculator"); log("открой калькулятор") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("PAINT") { botConnection.launchApp("paint"); log("открой paint") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "AUDIO DEVICE") {
                            HStack(spacing: 8) {
                                Button("SPEAKER") { botConnection.switchAudioDevice("speaker"); log("на колонку") }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("HEADPHONES") { botConnection.switchAudioDevice("headphones"); log("на наушники") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "NETWORK") {
                            HStack(spacing: 8) {
                                Button("WIFI PASS") { botConnection.getWifiPasswords(); log("wifi пароли") }
                                    .buttonStyle(LupinButtonStyle(isActive: true))
                                Button("IP") { botConnection.getIP(); log("ip адрес") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("PASSWORD") { botConnection.generatePassword(); log("пароль") }
                                    .buttonStyle(LupinButtonStyle())
                            }
                        }
                        
                        SectionView(title: "POWER") {
                            HStack(spacing: 8) {
                                Button("LOCK") { botConnection.powerControl("lock"); log("заблокируй пк") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("SLEEP") { botConnection.powerControl("sleep"); log("спящий режим") }
                                    .buttonStyle(LupinButtonStyle())
                                Button("REBOOT") { botConnection.powerControl("reboot"); log("перезагрузи пк") }
                                    .buttonStyle(LupinButtonStyle(isDanger: true))
                                Button("SHUTDOWN") { botConnection.powerControl("shutdown"); log("выключи пк") }
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

// ======================================================================

// MARK: - Command Log Entry
struct CommandLogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let source: String // "voice" | "text" | "macro" | "button"

    init(text: String, source: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.source = source
    }
}

// MARK: - History Store
/// Локальная история команд, отправленных на ПК.
/// Аналог lupin_commands.log на стороне Python, только на телефоне и без доступа к чату Telegram.
final class CommandHistoryStore: ObservableObject {
    @Published private(set) var entries: [CommandLogEntry] = []

    private let storageKey = "lupin_command_history_v1"
    private let maxEntries = 300

    init() {
        load()
    }

    func log(_ text: String, source: String) {
        let entry = CommandLogEntry(text: text, source: source)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CommandLogEntry].self, from: data) else {
            return
        }
        entries = decoded
    }
}

// ======================================================================

struct CommandHistoryView: View {
    @ObservedObject var historyStore: CommandHistoryStore
    @Environment(\.dismiss) var dismiss

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()

                if historyStore.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundColor(.lupinTextDim)
                        Text("ИСТОРИЯ ПУСТА")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.lupinTextDim)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(historyStore.entries) { entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(sourceIcon(entry.source))
                                        .font(.system(size: 14))
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.text)
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(.white)
                                        Text(Self.timeFormatter.string(from: entry.timestamp))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.lupinTextDim)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(Color.lupinPanel)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.lupinBorder, lineWidth: 1))
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("ИСТОРИЯ КОМАНД")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) {
                        historyStore.clear()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.lupinRed)
                    }
                    .disabled(historyStore.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ЗАКРЫТЬ") { dismiss() }
                        .foregroundColor(.lupinAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sourceIcon(_ source: String) -> String {
        switch source {
        case "voice": return "🎙"
        case "text": return "⌨️"
        case "macro": return "⚡️"
        default: return "▶️"
        }
    }
}

// ======================================================================

// MARK: - Macro Model
struct Macro: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var steps: [String] // текстовые команды, отправляются по очереди, как в sendCommand
    /// Пауза между шагами в секундах — некоторым командам на ПК нужно время выполниться
    /// (например "открой хром" перед "включи плейлист"), иначе они прилетят почти одновременно.
    var delayBetweenSteps: Double

    init(name: String, steps: [String], delayBetweenSteps: Double = 1.0) {
        self.id = UUID()
        self.name = name
        self.steps = steps
        self.delayBetweenSteps = delayBetweenSteps
    }
}

// MARK: - Macro Store
final class MacroStore: ObservableObject {
    @Published private(set) var macros: [Macro] = []

    private let storageKey = "lupin_macros_v1"

    init() {
        load()
        if macros.isEmpty {
            macros = Self.defaultMacros
            save()
        }
    }

    static let defaultMacros: [Macro] = [
        Macro(name: "Рабочий режим", steps: ["открой хром", "громкость 40"], delayBetweenSteps: 1.5),
        Macro(name: "Тихий вечер", steps: ["громкость 20", "на наушники"], delayBetweenSteps: 1.0)
    ]

    func add(_ macro: Macro) {
        macros.append(macro)
        save()
    }

    func update(_ macro: Macro) {
        guard let idx = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        macros[idx] = macro
        save()
    }

    func delete(at offsets: IndexSet) {
        macros.remove(atOffsets: offsets)
        save()
    }

    func delete(_ macro: Macro) {
        macros.removeAll { $0.id == macro.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data) else {
            return
        }
        macros = decoded
    }
}

// MARK: - Macro Runner
/// Выполняет шаги макроса последовательно с задержкой между ними.
enum MacroRunner {
    static func run(_ macro: Macro, bot: TelegramBotConnection, history: CommandHistoryStore) {
        for (index, step) in macro.steps.enumerated() {
            let delay = Double(index) * macro.delayBetweenSteps
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                bot.sendCommand(step)
                history.log(step, source: "macro")
            }
        }
    }
}

// MARK: - Macros List View
struct MacrosView: View {
    @ObservedObject var botConnection: TelegramBotConnection
    @ObservedObject var historyStore: CommandHistoryStore
    @StateObject private var store = MacroStore()
    @Environment(\.dismiss) var dismiss
    @State private var showEditor = false
    @State private var editingMacro: Macro? = nil

    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.macros) { macro in
                            MacroRow(
                                macro: macro,
                                onRun: { MacroRunner.run(macro, bot: botConnection, history: historyStore) },
                                onEdit: { editingMacro = macro; showEditor = true },
                                onDelete: { store.delete(macro) }
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("МАКРОСЫ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { editingMacro = nil; showEditor = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(.lupinAccent)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ЗАКРЫТЬ") { dismiss() }
                        .foregroundColor(.lupinAccent)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            MacroEditorView(store: store, macro: editingMacro)
        }
        .preferredColorScheme(.dark)
    }
}

private struct MacroRow: View {
    let macro: Macro
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(macro.name.uppercased())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.lupinAccent)
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .foregroundColor(.lupinTextDim)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.lupinRed)
                }
            }

            Text(macro.steps.joined(separator: " → "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.lupinText)

            Button(action: onRun) {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("ЗАПУСТИТЬ")
                }
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Color.lupinAccent)
                .cornerRadius(4)
            }
        }
        .padding(12)
        .background(Color.lupinPanel)
        .cornerRadius(4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.lupinBorder, lineWidth: 1))
    }
}

// MARK: - Macro Editor
private struct MacroEditorView: View {
    @ObservedObject var store: MacroStore
    let macro: Macro?

    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var stepsText: String = "" // одна команда на строку
    @State private var delay: Double = 1.0

    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()

                VStack(spacing: 16) {
                    SectionView(title: "НАЗВАНИЕ") {
                        TextField("Например: Рабочий режим", text: $name)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.lupinPanel)
                            .cornerRadius(4)
                    }

                    SectionView(title: "ШАГИ (по одному на строку, в порядке выполнения)") {
                        TextEditor(text: $stepsText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .scrollContentBackground(.hidden)
                            .background(Color.lupinPanel)
                            .frame(minHeight: 120)
                            .cornerRadius(4)
                    }

                    SectionView(title: "ПАУЗА МЕЖДУ ШАГАМИ: \(String(format: "%.1f", delay))с") {
                        Slider(value: $delay, in: 0.5...5.0, step: 0.5)
                            .tint(.lupinAccent)
                    }

                    Button(action: save) {
                        Text("СОХРАНИТЬ")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.lupinAccent)
                            .cornerRadius(4)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || parsedSteps.isEmpty)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle(macro == nil ? "НОВЫЙ МАКРОС" : "РЕДАКТИРОВАНИЕ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ОТМЕНА") { dismiss() }
                        .foregroundColor(.lupinTextDim)
                }
            }
        }
        .onAppear {
            if let macro = macro {
                name = macro.name
                stepsText = macro.steps.joined(separator: "\n")
                delay = macro.delayBetweenSteps
            }
        }
        .preferredColorScheme(.dark)
    }

    private var parsedSteps: [String] {
        stepsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        if var existing = macro {
            existing.name = name
            existing.steps = parsedSteps
            existing.delayBetweenSteps = delay
            store.update(existing)
        } else {
            store.add(Macro(name: name, steps: parsedSteps, delayBetweenSteps: delay))
        }
        dismiss()
    }
}

// ======================================================================

// MARK: - Notification Manager
/// Важно: это Local Notifications, а не APNs push.
/// Они позволяют показать уведомление, когда ответ от бота уже пришёл и приложение
/// активно (foreground) либо было недавно активно в фоне (background fetch/timer работает,
/// пока iOS не выгрузила приложение из памяти). Настоящий push "в любой момент, даже если
/// приложение выгружено" требует APNs-сервера на стороне Python (см. заметку ниже).
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    @Published var permissionGranted = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.permissionGranted = granted
            }
        }
    }

    /// Немедленное уведомление — например, о новом ответе бота или срабатывании алерта мониторинга.
    func notifyNow(title: String, body: String, identifier: String = UUID().uuidString) {
        guard permissionGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Отложенное уведомление — используется для напоминаний из ReminderScheduler.
    /// intervalSeconds — через сколько секунд сработает; для точной даты используй
    /// UNCalendarNotificationTrigger вместо UNTimeIntervalNotificationTrigger.
    @discardableResult
    func scheduleReminder(id: String, title: String, body: String, fireDate: Date) -> Bool {
        guard permissionGranted else { return false }
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 0 else { return false }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    func cancelReminder(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func cancelAllReminders() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}

// MARK: - Foreground presentation
extension NotificationManager: UNUserNotificationCenterDelegate {
    // Показываем баннер и звук, даже если приложение открыто (по умолчанию iOS их глушит).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

// ======================================================================

// ВАЖНО (требования для реальной сборки):
// 1. Таргет должен поддерживать iOS 16+ (App Intents framework).
// 2. Bot Token/Chat ID сейчас захардкожены в TelegramBotConnection — App Intents создают
//    СВОЙ экземпляр соединения (см. IntentBotBridge ниже), а не переиспользуют тот,
//    что живёт в ContentView, потому что интенты выполняются вне UI-процесса приложения.
// 3. Добавь в Info.plist / Target Capabilities ничего дополнительного не нужно —
//    App Intents регистрируются автоматически через AppShortcutsProvider ниже.

// MARK: - Bridge: минимальная обёртка для отправки команды из интента
/// Интенты не имеют доступа к @StateObject-инстансам живого UI, поэтому здесь —
/// собственный лёгкий клиент с той же логикой отправки, что и в TelegramBotConnection.
enum IntentBotBridge {
    // Дублирует значения из TelegramBotConnection. Если меняешь токен там — поменяй и здесь,
    // либо вынеси оба в общий Constants.swift, чтобы не рассинхронизировались.
    private static let botToken = "8602600416:AAGgYHxYL9hbyqlQdxPIPFXYIspZoUoeN8s"
    private static let chatId: Int64 = 7106785409

    static func send(_ text: String) async -> Bool {
        let urlString = "https://api.telegram.org/bot\(botToken)/sendMessage"
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatId,
            "text": text
        ])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                return ok
            }
        } catch {
            return false
        }
        return false
    }
}

// MARK: - Power Actions
enum PowerAction: String, AppEnum {
    case lock, sleep, reboot, shutdown

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Действие питания"
    static var caseDisplayRepresentations: [PowerAction: DisplayRepresentation] = [
        .lock: "Заблокировать",
        .sleep: "Спящий режим",
        .reboot: "Перезагрузить",
        .shutdown: "Выключить"
    ]

    var command: String {
        switch self {
        case .lock: return "заблокируй пк"
        case .sleep: return "спящий режим"
        case .reboot: return "перезагрузи пк"
        case .shutdown: return "выключи пк"
        }
    }
}

struct PowerControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Управление ПК Люпен"
    static var description = IntentDescription("Заблокировать, усыпить, перезагрузить или выключить ПК через LUPIN.")

    @Parameter(title: "Действие")
    var action: PowerAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) ПК")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await IntentBotBridge.send(action.command)
        return .result(dialog: ok ? "Команда отправлена." : "Не удалось отправить команду — проверь соединение.")
    }
}

// MARK: - Wake command (пример "разбуди Люпена")
struct WakeLupinIntent: AppIntent {
    static var title: LocalizedStringResource = "Разбудить Люпена"
    static var description = IntentDescription("Отправляет тестовую команду, чтобы проверить, что бот на связи.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await IntentBotBridge.send("привет")
        return .result(dialog: ok ? "Люпен на связи." : "Люпен не отвечает.")
    }
}

// MARK: - Media control
enum MediaAction: String, AppEnum {
    case prev, toggle, next

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Медиа-действие"
    static var caseDisplayRepresentations: [MediaAction: DisplayRepresentation] = [
        .prev: "Предыдущий трек",
        .toggle: "Пауза/Play",
        .next: "Следующий трек"
    ]

    var command: String {
        switch self {
        case .prev: return "предыдущий трек"
        case .toggle: return "пауза"
        case .next: return "следующий трек"
        }
    }
}

struct MediaControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Медиа на ПК"
    static var description = IntentDescription("Управляет воспроизведением музыки на ПК через LUPIN.")

    @Parameter(title: "Действие")
    var action: MediaAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await IntentBotBridge.send(action.command)
        return .result(dialog: ok ? "Готово." : "Не удалось отправить команду.")
    }
}

// MARK: - Screenshot
struct TakeScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Скриншот ПК"
    static var description = IntentDescription("Запросить скриншот экрана ПК через LUPIN.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await IntentBotBridge.send("скриншот")
        return .result(dialog: ok ? "Запрос на скриншот отправлен." : "Не удалось отправить запрос.")
    }
}

// MARK: - Free-form command ("Эй Siri, скажи Люпену открой хром")
struct SendCustomCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Команда для Люпена"
    static var description = IntentDescription("Отправляет произвольный текст как команду на ПК.")

    @Parameter(title: "Команда")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Отправить команду \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await IntentBotBridge.send(text)
        return .result(dialog: ok ? "Отправлено: \(text)" : "Не удалось отправить команду.")
    }
}

// MARK: - App Shortcuts Provider
/// Регистрирует готовые фразы для Siri/Shortcuts без ручной настройки пользователем.
struct LupinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WakeLupinIntent(),
            phrases: ["Разбуди \(.applicationName)", "\(.applicationName) на связи"],
            shortTitle: "Разбудить Люпена",
            systemImageName: "power.circle"
        )

        AppShortcut(
            intent: PowerControlIntent(),
            phrases: ["Выключи ПК через \(.applicationName)", "Заблокируй ПК через \(.applicationName)"],
            shortTitle: "Питание ПК",
            systemImageName: "power"
        )

        AppShortcut(
            intent: MediaControlIntent(),
            phrases: ["\(.applicationName), переключи трек", "\(.applicationName), пауза"],
            shortTitle: "Медиа",
            systemImageName: "playpause.fill"
        )

        AppShortcut(
            intent: TakeScreenshotIntent(),
            phrases: ["Сделай скриншот через \(.applicationName)"],
            shortTitle: "Скриншот",
            systemImageName: "camera.viewfinder"
        )
    }
}
