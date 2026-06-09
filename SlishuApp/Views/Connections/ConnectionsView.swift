import SwiftUI

/// Подключения (v1): локальная LLM (OpenAI-совместимый endpoint) + папка-назначение для саммари.
/// Без cloud — endpoint жёстко локальный. Секретов нет, поэтому Keychain здесь не задействован.
struct ConnectionsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var conn = env.connections
        Form {
            Section {
                TextField("Endpoint", text: $conn.llm.baseURL, prompt: Text("http://127.0.0.1:11434/v1"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("Модель", text: $conn.llm.model, prompt: Text("llama3.2 / qwen2.5 / …"))
                    .autocorrectionDisabled()

                HStack {
                    Button {
                        Task { await conn.testLLM() }
                    } label: {
                        Label("Проверить подключение", systemImage: "bolt.horizontal")
                    }
                    .disabled(conn.llmStatus == .testing || !conn.llm.isConfigured)

                    if conn.llmStatus == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                    statusBadge(conn.llmStatus)
                }

                if !conn.llm.isLocalOnly && conn.llm.isConfigured {
                    Label("Endpoint не локальный — в v1 разрешён только 127.0.0.1/localhost.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Локальная LLM")
            } footer: {
                Text("Любой OpenAI-совместимый сервер на localhost: Ollama (`ollama serve`, порт 11434), "
                     + "LM Studio (1234), mlx_lm.server, llama.cpp server. Запросы не уходят в облако.")
            }

            Section {
                HStack {
                    Button {
                        conn.pickDestination()
                    } label: {
                        Label("Выбрать папку…", systemImage: "folder")
                    }
                    Spacer()
                    if conn.destination.isConfigured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let path = conn.destination.displayPath {
                    Text(path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Подпапка", text: $conn.destination.subfolder, prompt: Text("Slishu"))
                    .autocorrectionDisabled()
            } header: {
                Text("Назначение")
            } footer: {
                Text("Куда писать саммари. Для Obsidian выбери папку vault — файлы лягут в "
                     + "`<vault>/<подпапка>/ГГГГ-ММ-ДД.md`.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Подключения")
    }

    @ViewBuilder
    private func statusBadge(_ status: ConnectionStore.LLMTestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Text("проверяю…").foregroundStyle(.secondary)
        case .ok(let models):
            Label(models.isEmpty ? "на связи" : "на связи · \(models.count) моделей",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(msg)
        }
    }
}
