import SwiftUI

// MARK: - Models
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // "user", "assistant", "system"
    let content: String
}

// MARK: - ViewModel
class LupinViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false
    
    // Твой API ключ DeepSeek
    let apiKey = "sk-90fc0d48b75b43e889a6f51002a68e73" 
    let systemPrompt = """
    Тебя зовут Lupin — Арсен Люпен III, легендарный вор-джентльмен. \
    Ты умный, харизматичный, дерзкий. Отвечай коротко и по делу. \
    Говори на русском, но иногда вставляй французские словечки.
    """
    
    init() {
        // Системный промпт прячем от глаз (не рендерим в UI)
        messages.append(ChatMessage(role: "system", content: systemPrompt))
        // Стартовое сообщение
        messages.append(ChatMessage(role: "assistant", content: "Приветствую, мон ами! Готов к новым делам?"))
    }
    
    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        let userMsg = ChatMessage(role: "user", content: text)
        messages.append(userMsg)
        inputText = ""
        isThinking = true
        
        Task {
            await fetchDeepSeekResponse()
        }
    }
    
    private func fetchDeepSeekResponse() async {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Пакуем историю для API
        let apiMessages = messages.map { ["role": $0.role, "content": $0.content] }
        
        let body: [String: Any] = [
            "model": "deepseek-chat",
            "messages": apiMessages,
            "temperature": 0.7,
            "max_tokens": 1500
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                
                DispatchQueue.main.async {
                    self.messages.append(ChatMessage(role: "assistant", content: content))
                    self.isThinking = false
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.messages.append(ChatMessage(role: "assistant", content: "Ошибка связи с сервером. Проверь сеть."))
                self.isThinking = false
            }
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var viewModel = LupinViewModel()
    
    // Фирменные цвета Lupin Suite
    let bgDark = Color(red: 10/255, green: 10/255, blue: 10/255)
    let bgLight = Color(red: 26/255, green: 26/255, blue: 26/255)
    let accent = Color(red: 216/255, green: 224/255, blue: 0/255) // #D8E000
    let borderDark = Color(red: 40/255, green: 40/255, blue: 40/255)
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("LUPIN AI")
                    .font(.custom("Menlo-Bold", size: 16))
                    .foregroundColor(.white)
                Spacer()
                Text(viewModel.isThinking ? "THINKING..." : "ONLINE")
                    .font(.custom("Menlo-Bold", size: 10))
                    .foregroundColor(viewModel.isThinking ? .orange : accent)
            }
            .padding()
            .background(bgLight)
            .overlay(Rectangle().frame(height: 1).foregroundColor(accent), alignment: .bottom)
            
            // Chat View
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        // Фильтруем system промпт
                        ForEach(viewModel.messages.filter { $0.role != "system" }) { msg in
                            HStack {
                                if msg.role == "user" {
                                    Spacer()
                                    Text(msg.content)
                                        .font(.custom("Menlo", size: 14))
                                        .padding(12)
                                        .background(bgLight)
                                        .foregroundColor(.white)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderDark, lineWidth: 1))
                                } else {
                                    Text(msg.content)
                                        .font(.custom("Menlo", size: 14))
                                        .padding(12)
                                        .background(bgDark)
                                        .foregroundColor(accent)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.5), lineWidth: 1))
                                    Spacer()
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
                .background(bgDark)
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onTapGesture {
                    hideKeyboard()
                }
            }
            
            // Input Area
            HStack(spacing: 8) {
                TextField("Type message...", text: $viewModel.inputText)
                    .font(.custom("Menlo", size: 14))
                    .padding(12)
                    .background(bgLight)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderDark, lineWidth: 1))
                    .onSubmit {
                        viewModel.sendMessage()
                    }
                
                Button(action: {
                    viewModel.sendMessage()
                }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .padding(12)
                        .background(accent)
                        .cornerRadius(4)
                }
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isThinking)
            }
            .padding()
            .background(bgDark)
            .overlay(Rectangle().frame(height: 1).foregroundColor(borderDark), alignment: .top)
        }
        .preferredColorScheme(.dark) // Принудительно темная тема
    }
}

// Утилита для скрытия клавиатуры по тапу на экран
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}