import SwiftUI

/// Connections (v1): local LLM (OpenAI-compatible endpoint) + destination folder for summaries.
/// No cloud — the endpoint is strictly local. There are no secrets, so the Keychain isn't used here.
struct ConnectionsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var conn = env.connections
        Form {
            Section {
                TextField("Endpoint", text: $conn.llm.baseURL, prompt: Text("http://127.0.0.1:1234/v1 (LM Studio)"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()

                // The model is chosen FROM the ones actually loaded in LM Studio (/v1/models). Until the list
                // arrives (server not running / wrong endpoint) — manual entry as a fallback.
                if conn.availableModels.isEmpty {
                    HStack {
                        TextField("Model", text: $conn.llm.model, prompt: Text("llama3.2 / qwen2.5 / …"))
                            .autocorrectionDisabled()
                        Button { Task { await conn.loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Fetch the model list from the server")
                    }
                } else {
                    Picker("Model", selection: $conn.llm.model) {
                        ForEach(conn.modelOptions, id: \.self) { Text($0).tag($0) }
                    }
                }

                HStack {
                    Button {
                        Task { await conn.testLLM() }
                    } label: {
                        Label("Test connection", systemImage: "bolt.horizontal")
                    }
                    .disabled(conn.llmStatus == .testing || !conn.llm.isConfigured)

                    if conn.llmStatus == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                    statusBadge(conn.llmStatus)
                }

                if !conn.llm.isLocalOnly && conn.llm.isConfigured {
                    Label("Endpoint is not local — in v1 only 127.0.0.1/localhost is allowed.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Local LLM")
            } footer: {
                Text("Any OpenAI-compatible server on localhost: Ollama (`ollama serve`, port 11434), "
                     + "LM Studio (1234), mlx_lm.server, llama.cpp server. Requests never leave for the cloud.")
            }

            Section {
                HStack {
                    Button {
                        conn.pickDestination()
                    } label: {
                        Label("Choose folder…", systemImage: "folder")
                    }
                    Spacer()
                    if conn.destination.isConfigured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let path = conn.destination.displayPath {
                    Text(path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                TextField("Subfolder", text: $conn.destination.subfolder, prompt: Text("ZBS Eye"))
                    .autocorrectionDisabled()
            } header: {
                Text("Destination")
            } footer: {
                Text("Where to write summaries. For Obsidian, pick the vault folder — files land in "
                     + "`<vault>/<subfolder>/YYYY-MM-DD.md`.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
        .task { await conn.loadModels() }   // fetch models right when opening (if the server is reachable)
    }

    @ViewBuilder
    private func statusBadge(_ status: ConnectionStore.LLMTestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Text("testing…").foregroundStyle(.secondary)
        case .ok(let models):
            Label(models.isEmpty ? "connected" : "connected · \(models.count) models",
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
