import SwiftUI
import AVFoundation
import Speech

class VoiceAssistant: ObservableObject {
    private var synthesizer = AVSpeechSynthesizer()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    @Published var recognizedText = "Нажми кнопку и скажи что-нибудь..."
    @Published var isListening = false

    // Озвучка (Text-to-Speech)
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.5 // Скорость речи
        synthesizer.speak(utterance)
    }

    // Слух (Speech-to-Text)
    func startListening() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self.startRecording()
                } else {
                    self.recognizedText = "Нет доступа к микрофону!"
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
        VStack(spacing: 30) {
            Text("Голосовой Ассистент")
                .font(.largeTitle)
                .bold()

            Text(assistant.recognizedText)
                .padding()
                .frame(maxWidth: .infinity, minHeight: 100)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(15)
                .padding(.horizontal)

            Button(action: {
                if assistant.isListening {
                    assistant.stopListening()
                    // Пример: ассистент отвечает после того, как ты закончил говорить
                    assistant.speak("Я услышал: \(assistant.recognizedText)")
                } else {
                    assistant.startListening()
                }
            }) {
                Image(systemName: assistant.isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.white)
                    .padding()
                    .background(assistant.isListening ? Color.red : Color.blue)
                    .clipShape(Circle())
            }
            
            Text(assistant.isListening ? "Нажми, чтобы остановить" : "Нажми, чтобы сказать")
                .foregroundColor(.gray)
        }
    }
}
