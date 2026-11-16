import Foundation
import ClassnoteCore

struct TextResult { var text: String; var inputTokens: Int; var outputTokens: Int }

struct OpenAIService {
    let key: String
    private func request(_ path: String, method: String = "POST") -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/" + path)!)
        r.httpMethod = method; r.timeoutInterval = 120
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return r
    }
    private func checked(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppFailure("服务器没有返回有效响应。") }
        guard (200..<300).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "请求失败"
            throw AppFailure("OpenAI \(response.statusCode)：\(message)")
        }
        return data
    }
    func test(model: String) async throws {
        let safe = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        _ = try await checked(request("models/" + safe, method: "GET"))
    }
    func text(model: String, instructions: String, input: String, maxTokens: Int = 4096, jsonSchema: [String: Any]? = nil) async throws -> TextResult {
        var r = request("responses")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["model": model, "instructions": instructions, "input": input, "store": false, "max_output_tokens": maxTokens]
        if let jsonSchema { payload["text"] = ["format": ["type": "json_schema", "name": "lecture_courseware_bindings", "strict": true, "schema": jsonSchema]] }
        if model.hasPrefix("gpt-5.6") { payload["reasoning"] = ["effort": "none"] }
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await checked(r)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AppFailure("无法读取文本响应。") }
        guard json["status"] as? String != "incomplete", json["status"] as? String != "failed" else {
            throw AppFailure("文本生成未完整完成，请重试或调整文本模型。")
        }
        let output = (json["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = output.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("模型没有返回文本。") }
        let usage = json["usage"] as? [String: Any]
        return .init(text: text, inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0)
    }
    func transcribe(file: URL, model: String, vocabulary: String = "") async throws -> String {
        let boundary = "Classnote-" + UUID().uuidString
        var r = request("audio/transcriptions")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ value: String) { body.append(contentsOf: value.utf8) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        for (name, value) in TranscriptionOptions.fileFields(model: model, vocabulary: vocabulary) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: file))
        append("\r\n--\(boundary)--\r\n"); r.httpBody = body
        let data = try await checked(r)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else { throw AppFailure("无法读取转录结果。") }
        return text
    }
}

@MainActor final class RealtimeTranscriber {
    var onFinal: ((UUID, String) -> Void)?
    var onDraft: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var outgoing: AsyncStream<String>.Continuation?
    private var ready: CheckedContinuation<Void, Error>?
    private var router = TranscriptRouter()
    private var drafts: [String: String] = [:]
    private var closed = false

    func connect(key: String, model: String, vocabulary: String, context: String = "") async throws {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let ws = URLSession.shared.webSocketTask(with: request); socket = ws
        let stream = AsyncStream<String> { outgoing = $0 }
        sender = Task { [weak self] in
            do { for await payload in stream { try Task.checkCancellation(); try await ws.send(.string(payload)) } }
            catch { if !Task.isCancelled { self?.fail(error.localizedDescription) } }
        }
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    if let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] { self?.handle(event) }
                }
            } catch { if !Task.isCancelled { self?.fail(error.localizedDescription) } }
        }
        ws.resume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            let transcription = TranscriptionOptions.realtime(model: model, vocabulary: vocabulary, context: context)
            send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24000], "transcription": transcription, "turn_detection": NSNull()]]]])
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, self?.ready != nil else { return }
                self?.fail("连接超时，请检查网络、API Key 和模型权限。")
            }
        }
    }
    func append(_ pcm: Data) { if !pcm.isEmpty { send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]) } }
    func commit(_ id: UUID) { router.enqueue(id); send(["type": "input_audio_buffer.commit"]) }
    func clear() { send(["type": "input_audio_buffer.clear"]) }
    func close() {
        closed = true; timeout?.cancel(); outgoing?.finish(); sender?.cancel(); receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        ready?.resume(throwing: AppFailure("连接已关闭。")); ready = nil
    }
    private func send(_ event: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
        outgoing?.yield(text)
    }
    private func fail(_ message: String) {
        guard !closed else { return }
        let wasConnecting = ready != nil
        ready?.resume(throwing: AppFailure(message)); ready = nil
        close()
        if !wasConnecting { onFailure?(message) }
    }
    private func handle(_ event: [String: Any]) {
        guard !closed, let type = event["type"] as? String else { return }
        let item = event["item_id"] as? String ?? ""
        switch type {
        case "session.updated", "transcription_session.updated":
            ready?.resume(); ready = nil; timeout?.cancel()
        case "input_audio_buffer.committed":
            if let (id, early) = router.acknowledge(item: item), let early { onFinal?(id, early) }
        case "conversation.item.input_audio_transcription.delta":
            drafts[item, default: ""] += event["delta"] as? String ?? ""
            onDraft?(drafts[item] ?? "")
        case "conversation.item.input_audio_transcription.completed":
            drafts.removeValue(forKey: item)
            if let result = router.complete(item: item, text: event["transcript"] as? String ?? "") { onFinal?(result.0, result.1) }
            onDraft?("")
        case "conversation.item.input_audio_transcription.failed", "error":
            let error = event["error"] as? [String: Any]
            fail(error?["message"] as? String ?? "实时转录失败，音频已保存在本机，可重试。")
        default: break
        }
    }
}
