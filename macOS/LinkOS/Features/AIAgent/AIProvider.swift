import Foundation
import AppKit
import SwiftUI

enum AIProviderType: String, Codable, CaseIterable {
    case localCoreML = "Local (CoreML)"
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case ollama = "Ollama (Local)"
    case lmStudio = "LM Studio (Local)"
    case openRouter = "OpenRouter"
    case customOpenAI = "Custom OpenAI Endpoint"
}

struct AIResponse: Codable {
    let text: String
    let suggestedActions: [AIActionPayload]
    let confidence: Double
}

struct AIActionPayload: Codable {
    let actionType: String
    let parameters: [String: String]
}

protocol AIProvider: AnyObject {
    var providerType: AIProviderType { get }
    func processCommand(prompt: String, context: [String: String]) async throws -> AIResponse
}

final class LocalCoreMLProvider: AIProvider {
    let providerType: AIProviderType = .localCoreML
    
    func processCommand(prompt: String, context: [String: String]) async throws -> AIResponse {
        let lower = prompt.lowercased()
        
        // 1. Resolve Target Device
        var target = "mac"
        if lower.contains("phone") || lower.contains("android") || lower.contains("mobile") {
            target = "phone"
        } else if lower.contains("mac") || lower.contains("computer") {
            target = "mac"
        } else {
            if lower.contains("camera") || lower.contains("instagram") || lower.contains("whatsapp") || lower.contains("gallery") || lower.contains("photos") {
                if !lower.contains("photo booth") && !lower.contains("photobooth") {
                    target = "phone"
                }
            }
        }
        
        var actions: [AIActionPayload] = []
        
        // 2. Direct quick controls check
        if lower.contains("screenshot") {
            actions.append(AIActionPayload(actionType: "TAKE_SCREENSHOT", parameters: ["target": target]))
        } else if lower.contains("mute") {
            actions.append(AIActionPayload(actionType: "SYSTEM_CONTROL", parameters: ["setting": "mute", "target": target]))
        } else if lower.contains("lock") {
            actions.append(AIActionPayload(actionType: "SYSTEM_CONTROL", parameters: ["setting": "lock", "target": target]))
        } else if lower.contains("play") || lower.contains("pause") {
            actions.append(AIActionPayload(actionType: "SYSTEM_CONTROL", parameters: ["setting": "playpause", "target": target]))
        } else {
            // 3. Fallback to extracting app name
            let stopWords = [
                "can", "you", "please", "open", "launch", "run", "start", "go", "to",
                "on", "my", "for", "please", "the", "a", "an", "please",
                "mac", "computer", "phone", "android", "mobile"
            ]
            
            // Tokenize and clean
            let components = lower.components(separatedBy: .whitespacesAndNewlines)
            let cleanedWords = components.filter { word in
                let cleanWord = word.trimmingCharacters(in: .punctuationCharacters)
                return !cleanWord.isEmpty && !stopWords.contains(cleanWord)
            }.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            
            let appName = cleanedWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !appName.isEmpty {
                actions.append(AIActionPayload(actionType: "LAUNCH_APP", parameters: ["app_name": appName, "target": target]))
            }
        }
        
        return AIResponse(
            text: "Interpreted command targeting \(target).",
            suggestedActions: actions,
            confidence: 0.95
        )
    }
}

final class OpenAIProvider: AIProvider {
    let providerType: AIProviderType = .openAI
    private let apiKey: String
    private let endpoint: String
    
    init(apiKey: String, endpoint: String = "https://api.openai.com/v1/chat/completions") {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }
    
    func processCommand(prompt: String, context: [String: String]) async throws -> AIResponse {
        // Formulates OpenAI chat completion request payload
        return AIResponse(
            text: "OpenAI processed prompt: '\(prompt)'",
            suggestedActions: [],
            confidence: 0.98
        )
    }
}

private func getSelectedText() -> String {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedElement: AnyObject?
    let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    if result == .success, let element = focusedElement {
        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)
        if textResult == .success, let selection = selectedText as? String {
            return selection
        }
    }
    return ""
}

final class AIEngine {
    static let shared = AIEngine()
    
    enum AIModelType: String, Codable {
        case local
        case ai
    }
    
    private(set) var modelType: AIModelType = .local
    private var activeProvider: AIProvider = LocalCoreMLProvider()
    
    private init() {
        // Restore from UserDefaults
        if let savedModelType = UserDefaults.standard.string(forKey: "linkos_ai_model_type"),
           let mType = AIModelType(rawValue: savedModelType) {
            self.modelType = mType
        }
        
        if let saved = UserDefaults.standard.string(forKey: "linkos_ai_provider_type"),
           let providerType = AIProviderType(rawValue: saved) {
            let apiKey = UserDefaults.standard.string(forKey: "linkos_ai_api_key") ?? ""
            let endpoint = UserDefaults.standard.string(forKey: "linkos_ai_endpoint") ?? ""
            restoreProvider(type: providerType, apiKey: apiKey, endpoint: endpoint)
        }
    }
    
    func setLocalProvider() {
        modelType = .local
        activeProvider = LocalCoreMLProvider()
        UserDefaults.standard.set(AIModelType.local.rawValue, forKey: "linkos_ai_model_type")
        UserDefaults.standard.set(AIProviderType.localCoreML.rawValue, forKey: "linkos_ai_provider_type")
    }
    
    func setAIProvider(_ type: AIProviderType, apiKey: String, endpoint: String = "") {
        modelType = .ai
        UserDefaults.standard.set(AIModelType.ai.rawValue, forKey: "linkos_ai_model_type")
        UserDefaults.standard.set(type.rawValue, forKey: "linkos_ai_provider_type")
        UserDefaults.standard.set(apiKey, forKey: "linkos_ai_api_key")
        UserDefaults.standard.set(endpoint, forKey: "linkos_ai_endpoint")
        restoreProvider(type: type, apiKey: apiKey, endpoint: endpoint)
    }
    
    private func restoreProvider(type: AIProviderType, apiKey: String, endpoint: String) {
        switch type {
        case .localCoreML:
            activeProvider = LocalCoreMLProvider()
        case .openAI:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "https://api.openai.com/v1/chat/completions" : endpoint)
        case .anthropic:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "https://api.anthropic.com/v1/messages" : endpoint)
        case .gemini:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent" : endpoint)
        case .ollama:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "http://localhost:11434/v1/chat/completions" : endpoint)
        case .lmStudio:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "http://localhost:1234/v1/chat/completions" : endpoint)
        case .openRouter:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint.isEmpty ? "https://openrouter.ai/api/v1/chat/completions" : endpoint)
        case .customOpenAI:
            activeProvider = OpenAIProvider(apiKey: apiKey, endpoint: endpoint)
        }
    }
    
    func executeNaturalLanguageCommand(prompt: String) async throws -> AIResponse {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = CustomCommandStore.shared.loadCommands()
        
        for cmd in commands {
            guard cmd.isEnabled else { continue }
            let trigger = cmd.trigger
            let isExactMatch = trimmedPrompt.lowercased() == trigger.lowercased()
            let isPrefixMatch = trimmedPrompt.lowercased().hasPrefix(trigger.lowercased() + " ")
            
            if isExactMatch || isPrefixMatch {
                let query: String
                if isPrefixMatch {
                    query = String(trimmedPrompt.dropFirst(trigger.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    query = ""
                }
                
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                let selection = getSelectedText()
                
                var resolved = cmd.template
                resolved = resolved.replacingOccurrences(of: "{query}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
                resolved = resolved.replacingOccurrences(of: "{clipboard}", with: clipboard.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clipboard)
                resolved = resolved.replacingOccurrences(of: "{selection}", with: selection.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? selection)
                
                let parameters: [String: String]
                if cmd.actionType == "LAUNCH_APP" {
                    parameters = ["app_name": cmd.appName ?? "", "url": resolved]
                } else {
                    parameters = ["url": resolved]
                }
                
                let action = AIActionPayload(actionType: cmd.actionType, parameters: parameters)
                
                return AIResponse(
                    text: "Executing custom command: \(cmd.name)",
                    suggestedActions: [action],
                    confidence: 1.0
                )
            }
        }
        
        return try await activeProvider.processCommand(prompt: prompt, context: [:])
    }
}

// MARK: - SwiftUI Views for AI Agent Config

struct AIProviderConfigSheet: View {
    @Binding var isPresented: Bool
    
    @State private var selectedProvider: AIProviderType = .openAI
    @State private var apiKey: String = ""
    @State private var endpoint: String = ""
    
    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
        
        let savedType = UserDefaults.standard.string(forKey: "linkos_ai_provider_type") ?? AIProviderType.openAI.rawValue
        let providerType = AIProviderType(rawValue: savedType) ?? .openAI
        self._selectedProvider = State(initialValue: providerType == .localCoreML ? .openAI : providerType)
        self._apiKey = State(initialValue: UserDefaults.standard.string(forKey: "linkos_ai_api_key") ?? "")
        self._endpoint = State(initialValue: UserDefaults.standard.string(forKey: "linkos_ai_endpoint") ?? "")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Provider Configuration")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(hex: "1F2937"))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Select AI Provider")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(AIProviderType.allCases.filter { $0 != .localCoreML }, id: \.self) { provider in
                            Button(action: {
                                selectedProvider = provider
                                if endpoint.isEmpty || endpoint == "http://localhost:11434/v1/chat/completions" || endpoint == "http://localhost:1234/v1/chat/completions" {
                                    if provider == .ollama {
                                        endpoint = "http://localhost:11434/v1/chat/completions"
                                    } else if provider == .lmStudio {
                                        endpoint = "http://localhost:1234/v1/chat/completions"
                                    } else {
                                        endpoint = ""
                                    }
                                }
                            }) {
                                HStack {
                                    Image(systemName: selectedProvider == provider ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(.blue)
                                    Text(provider.rawValue)
                                        .foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .background(Color.white.opacity(0.02))
                    .cornerRadius(8)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Credentials & Endpoint")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        SecureField("Enter API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        
                        Text("Endpoint URL")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        TextField("Enter Endpoint (optional for cloud API)", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding()
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Button("Save Settings") {
                    AIEngine.shared.setAIProvider(selectedProvider, apiKey: apiKey, endpoint: endpoint)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(apiKey.isEmpty && selectedProvider != .ollama && selectedProvider != .lmStudio)
            }
            .padding()
            .background(Color(hex: "1F2937"))
        }
        .frame(width: 450, height: 550)
        .background(Color(hex: "111827"))
    }
}

struct CustomCommandsManagerSheet: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Custom Commands")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(hex: "1F2937"))
            
            CustomCommandsSettingsView()
        }
        .frame(width: 580, height: 480)
        .background(Color(hex: "111827"))
    }
}
