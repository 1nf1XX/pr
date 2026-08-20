import SwiftUI
import AVFoundation
import Speech

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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // Мужской голос + пониженный питч/скорость для "механического" звучания.
    // Настоящий вокодер потребовал бы аудио-постобработки — это ближайшее,
    // что даёт системный TTS.
    private func pickVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let maleRuVoice = voices.first(where: { $0.language == "ru-RU" && $0.gender == .male }) {
            return maleRuVoice
        }
        return AVSpeechSynthesisVoice(language: "ru-RU")
    }

    // После записи речи сессия остаётся в режиме .record (только вход).
    // TTS не может выдать звук, пока сессия не переключена на воспроизведение —
    // это и была причина полной тишины.
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

    func sendToDeepSeek(prompt: String) {
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

        // Тон — сдержанный, точный помощник в духе Джарвиса,
        // с лёгким шармом элегантного авантюриста, без грубости и наигранной дерзости.
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

extension Color {
    static let lupinAccent = Color(red: 0.95, green: 0.9, blue: 0.2)
    static let lupinBackground = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let lupinPanel = Color(red: 0.12, green: 0.12, blue: 0.15)
}

// MARK: - Пиксельный персонаж

/// Обобщённый пиксельный силуэт "элегантного вора/хакера" (шляпа, маска, плащ),
/// а не конкретный лицензированный персонаж. Цвета взяты из палитры интерфейса.
struct PixelLupinView: View {
    let isListening: Bool
    let isSpeaking: Bool

    @State private var mouthOpen = false
    @State private var bobUp = false

    private let mouthTimer = Timer.publish(every: 0.22, on: .main, in: .common).autoconnect()
    private let bobTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    // 0 пусто · 1 шляпа · 2 кожа · 3 плащ · 4 тень плаща · 5 галстук/акцент · 7 рот · 8 маска/очки (акцент)
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
        case 1: return Color(red: 0.16, green: 0.16, blue: 0.19) // шляпа
        case 2: return Color(red: 0.86, green: 0.72, blue: 0.55) // кожа
        case 3: return Color(red: 0.14, green: 0.14, blue: 0.18) // плащ
        case 4: return Color(red: 0.09, green: 0.09, blue: 0.12) // тень плаща
        case 5: return Color.lupinAccent                          // галстук
        case 7: return Color.black.opacity(0.85)                  // рот
        case 8: return Color.lupinAccent                          // маска/очки
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

// MARK: - Основной экран

struct ContentView: View {
    @StateObject var assistant = VoiceAssistant()
    @State private var showSettings = false

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
                        Text(assistant.assistantReply)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.lupinAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

                Button(action: {
                    if assistant.isListening {
                        assistant.stopListening()
                        assistant.sendToDeepSeek(prompt: assistant.recognizedText)
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
            SettingsView(apiKey: $assistant.apiKey)
        }
        .onAppear {
            if assistant.apiKey.isEmpty {
                showSettings = true
            }
        }
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    @State private var draftKey: String = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.lupinBackground.ignoresSafeArea()

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

                    Spacer()

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
                            .cornerRadius(8)
                    }
                    .disabled(draftKey.isEmpty)
                }
                .padding()
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
        }
        .preferredColorScheme(.dark)
    }
}
