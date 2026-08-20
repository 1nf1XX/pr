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
                self.assistantReply = "Ошибка: не введен API-ключ!"
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
                    self.startRecording()
                } else {
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

struct ContentView: View {
    @StateObject var assistant = VoiceAssistant()

    var body: some View {
        ZStack {
            // Глубокий темный фон в стиле Lupin Suite
            Color(red: 0.08, green: 0.08, blue: 0.1)
                .ignoresSafeArea()

            VStack(spacing: 25) {
                // Заголовок
                Text("ADOLFIK // SUITE")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.95, green: 0.9, blue: 0.2)) // Кислотный желтый
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
                .background(Color(red: 0.12, green: 0.12, blue: 0.15))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 0.95, green: 0.9, blue: 0.2).opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal)

                // Блок ответа ИИ
                VStack(alignment: .leading, spacing: 6) {
                    Text("ОТВЕТ ЯДРА:")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    if assistant.isProcessing {
                        ProgressView()
                            tint(Color(red: 0.95, green: 0.9, blue: 0.2))
                    } else {
                        Text(assistant.assistantReply)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(Color(red: 0.95, green: 0.9, blue: 0.2))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color(red: 0.12, green: 0.12, blue: 0.15))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(red: 0.95, green: 0.9, blue: 0.2), lineWidth: 1)
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
                        .background(assistant.isListening ? Color.red : Color(red: 0.95, green: 0.9, blue: 0.2))
                        .clipShape(Circle())
                        .shadow(color: (assistant.isListening ? Color.red : Color(red: 0.95, green: 0.9, blue: 0.2)).opacity(0.5), radius: 10)
                }
                
                Text(assistant.isListening ? "ИДЕТ ЗАПИСЬ..." : "НАЖМИ ДЛЯ ВВОДА")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                // Поле для API-ключа
                SecureField("DeepSeek API Key", text: $assistant.apiKey)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding()
                    .background(Color(red: 0.12, green: 0.12, blue: 0.15))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .font(.system(size: 14, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }
        }
    }
}
