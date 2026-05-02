import Foundation

// MARK: - Editor Chat Message

/// A chat message in the AI editing conversation.
/// Distinct from OpenAIClient's ChatMessage (transport layer).
struct EditorChatMessage: Identifiable, Codable {
    let id: UUID
    let role: Role
    /// `var` so the `runAgentLoop` live-narration bubble can be rewritten
    /// in place as the agent progresses through tool calls. Other bubble
    /// kinds treat this field as immutable after append.
    var content: String
    let timestamp: Date
    /// Links to the checkpoint created by this message's action (if any).
    var checkpointID: UUID?
    /// Links this assistant bubble to a `ProposedBatch` pending user
    /// approval. When non-nil the UI renders the bubble as an
    /// Apply/Reject card instead of a plain text message.
    var proposedBatchID: UUID?
    /// Optional SF Symbol to render inline before `content`. Used by
    /// system-generated progress bubbles (e.g. the One-click first cut
    /// analysis log) so we get crisp tinted icons instead of emoji.
    var iconSystemName: String?
    /// Semantic tint for `iconSystemName`. Falls back to the bubble's
    /// normal foreground when nil.
    var iconTone: IconTone?
    /// Path (relative to project root when possible; absolute otherwise)
    /// of an image attached to this message. Rendered inline as a
    /// thumbnail that opens a fullscreen viewer on tap and exposes a
    /// right-click "Save as…" / "Show in Finder" menu. Populated by the
    /// three image-generation entry points so the user sees the PNG in
    /// the chat log, not just a text confirmation.
    var imageAttachmentPath: String?
    /// True for the single in-place "live status" bubble per agent turn:
    /// its `content` is rewritten as the agent progresses through tool
    /// calls, then locked to a "完成" / "Done" success state before the
    /// real final-reply bubble is appended. Normal bubbles leave this
    /// `false` and are never mutated after append.
    var isLiveNarration: Bool
    /// When non-nil, the chat UI renders this string instead of
    /// `content`. `content` itself is still used for LLM history,
    /// persistence, and programmatic operations. Used by internal
    /// entry points (e.g. "Generate animation from B-roll suggestion")
    /// that build a large scaffolded instruction for the agent but
    /// want to show the user only the part they actually authored.
    var displayContent: String?

    /// The string that should appear in the UI bubble. Falls back to
    /// `content` when no display override was provided.
    var displayedContent: String { displayContent ?? content }

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    enum IconTone: String, Codable {
        case neutral
        case working
        case success
        case warning
        case failure
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        checkpointID: UUID? = nil,
        proposedBatchID: UUID? = nil,
        iconSystemName: String? = nil,
        iconTone: IconTone? = nil,
        imageAttachmentPath: String? = nil,
        isLiveNarration: Bool = false,
        displayContent: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.checkpointID = checkpointID
        self.proposedBatchID = proposedBatchID
        self.iconSystemName = iconSystemName
        self.iconTone = iconTone
        self.imageAttachmentPath = imageAttachmentPath
        self.isLiveNarration = isLiveNarration
        self.displayContent = displayContent
    }

    // Manual Codable: `isLiveNarration` is a late addition so pre-existing
    // persisted chat histories won't have the key. Decoding gracefully
    // defaults it to `false` instead of refusing to decode the log.
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        case checkpointID, proposedBatchID
        case iconSystemName, iconTone
        case imageAttachmentPath
        case isLiveNarration
        case displayContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.checkpointID = try c.decodeIfPresent(UUID.self, forKey: .checkpointID)
        self.proposedBatchID = try c.decodeIfPresent(UUID.self, forKey: .proposedBatchID)
        self.iconSystemName = try c.decodeIfPresent(String.self, forKey: .iconSystemName)
        self.iconTone = try c.decodeIfPresent(IconTone.self, forKey: .iconTone)
        self.imageAttachmentPath = try c.decodeIfPresent(String.self, forKey: .imageAttachmentPath)
        self.isLiveNarration = try c.decodeIfPresent(Bool.self, forKey: .isLiveNarration) ?? false
        self.displayContent = try c.decodeIfPresent(String.self, forKey: .displayContent)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(checkpointID, forKey: .checkpointID)
        try c.encodeIfPresent(proposedBatchID, forKey: .proposedBatchID)
        try c.encodeIfPresent(iconSystemName, forKey: .iconSystemName)
        try c.encodeIfPresent(iconTone, forKey: .iconTone)
        try c.encodeIfPresent(imageAttachmentPath, forKey: .imageAttachmentPath)
        if isLiveNarration {
            try c.encode(isLiveNarration, forKey: .isLiveNarration)
        }
        try c.encodeIfPresent(displayContent, forKey: .displayContent)
    }
}

// MARK: - Chat Store

/// Persists chat history per project.
actor ChatStore {
    private let fileURL: URL
    private var messages: [EditorChatMessage] = []

    init(projectRoot: URL) {
        self.fileURL = projectRoot.appending(path: "media/chat_history.json")
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            messages = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        messages = try decoder.decode([EditorChatMessage].self, from: data)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(messages)
        try data.write(to: fileURL, options: .atomic)
    }

    func append(_ message: EditorChatMessage) throws {
        messages.append(message)
        try save()
    }

    /// Overwrite the entire persisted log with `snapshot`. Used when
    /// the view model retroactively rewrites past bubbles (e.g. moving
    /// a `.working` line to `.success` once its phase completes), so
    /// relaunches see the same resolved state.
    func replace(with snapshot: [EditorChatMessage]) throws {
        messages = snapshot
        try save()
    }

    func all() -> [EditorChatMessage] {
        messages
    }

    func clear() throws {
        messages = []
        try save()
    }
}
