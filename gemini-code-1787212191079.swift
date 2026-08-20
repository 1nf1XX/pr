import SwiftUI
import AVFoundation
import Speech

class VoiceAssistant: ObservableObject {
    private var synthesizer = AVSpeechSynthesizer()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    @Published var recognizedText = "Нажми на микрофон..."
    @Published var assistantReply = "Система готова. Ожидание команды..."
    @Published var isListening = false
    @Published var isProcessing = false
    @Published var micAccessDenied = false

    @AppStorage("deepseek_api_key") var apiKey: String = ""

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func sendToDeepSeek(prompt: String) {
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.assistantReply = "Ошибка: не введен API-ключ! Открой настройки."
                self.speak(self.assistantReply)
            }
            return
        }

        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": "deepseek-chat",
            "messages": [
                ["role": "system", "content": "Ты голосовой ассистент Адольфик. Отвечай дерзко, коротко и по делу в стиле киберпанк/хакер."],
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

// Акцентный цвет вынесен один раз, чтобы не повторять RGB по всему файлу
extension Color {
    static let adolfikAccent = Color(red: 0.95, green: 0.9, blue: 0.2)
    static let adolfikBackground = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let adolfikPanel = Color(red: 0.12, green: 0.12, blue: 0.15)
}

struct ContentView: View {
    @StateObject var assistant = VoiceAssistant()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.adolfikBackground
                .ignoresSafeArea()

            VStack(spacing: 25) {
                // Заголовок + шестеренка настроек
                HStack {
                    Spacer()
                    Text("ADOLFIK // SUITE")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.adolfikAccent)
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

                // Блок ввода запроса
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
                .background(Color.adolfikPanel)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.adolfikAccent.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal)

                // Предупреждение о микрофоне, если доступ запрещен
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

                // Блок ответа ИИ
                VStack(alignment: .leading, spacing: 6) {
                    Text("ОТВЕТ ЯДРА:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    if assistant.isProcessing {
                        ProgressView()
                            .tint(.adolfikAccent)
                    } else {
                        Text(assistant.assistantReply)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.adolfikAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color.adolfikPanel)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.adolfikAccent, lineWidth: 1)
                )
                .padding(.horizontal)

                Spacer()

                // Кнопка микрофона в неоновом стиле
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
                        .background(assistant.isListening ? Color.red : Color.adolfikAccent)
                        .clipShape(Circle())
                        .shadow(color: (assistant.isListening ? Color.red : Color.adolfikAccent).opacity(0.5), radius: 10)
                }

                Text(assistant.isListening ? "ИДЕТ ЗАПИСЬ..." : "НАЖМИ ДЛЯ ВВОДА")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.bottom, 20)
            }
        }
        // Ключ вводится один раз через настройки — пустой ключ сам открывает лист
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
                Color.adolfikBackground.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 16) {
                    Text("DEEPSEEK API KEY")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)

                    SecureField("sk-...", text: $draftKey)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding()
                        .background(Color.adolfikPanel)
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
                            .background(Color.adolfikAccent)
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
                        .foregroundColor(.adolfikAccent)
                }
            }
        }
        .onAppear {
            draftKey = apiKey
        }
        .preferredColorScheme(.dark)
    }
}
