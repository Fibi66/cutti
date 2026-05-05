import Foundation

/// Agent-facing animation skill — exposes the bundled
/// `Resources/AnimationSkill/` folder (a fork of `.claude/skills/animation/`
/// kept self-contained inside the macOS app target) as two read-only
/// LLM tools:
///
///   • `list_animation_rules`  — TOC of every available markdown file
///                               (rules, style-guide, templates,
///                               plugins, workflow, root SKILL.md)
///   • `read_animation_rule`   — fetch the full markdown of one entry
///
/// The agent picks what it needs on demand — there's no fixed set of
/// topics, so when we add a new rule file all the agent has to do is
/// list and read it.
///
/// **Why a tool rather than a static system-prompt block:**
/// The skill folder contains 50+ markdown files (~150 KB total).
/// Baking that into every chat turn eats context for no reason. The
/// agent pulls only the file it needs, and a user can reach the same
/// content by asking "show me the animation guide / how should I
/// animate this" — the LLM forwards that to `list_animation_rules`
/// and follows up with `read_animation_rule`.
///
/// Source of truth: `Sources/CuttiMac/Resources/AnimationSkill/`.
/// To update guidance, edit the markdown there — no Swift changes
/// required. (The user-facing Claude Code skill at
/// `.claude/skills/animation/` is a separate copy maintained
/// independently.)
enum AnimationSkill {

    // MARK: - Skill-file enumeration

    /// One markdown entry inside the bundled skill.
    struct Entry: Equatable, Sendable {
        /// Stable name the agent passes back to `read_animation_rule`.
        /// Lowercased, slashes preserved (e.g. `rules/cutti-staging`,
        /// `style-guide/aesthetic`, `plugins/claude-typer/skill`).
        let name: String
        /// One-line summary — pulled from the `description:` field in
        /// the markdown's YAML front matter when present, otherwise
        /// from the first non-empty heading. Used in `list_animation_rules`
        /// so the agent can pick without reading the whole file.
        let summary: String
    }

    /// All available skill entries, lazily computed once at first use.
    static let allEntries: [Entry] = computeEntries()

    /// Returns the markdown content for `name` (sans front matter), or
    /// `nil` if no such entry exists.
    static func content(for name: String) -> String? {
        guard let url = url(for: name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tool definitions

    static let listToolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "list_animation_rules",
            description: """
            List every entry in the internal Remotion animation skill — \
            distilled best-practices for building overlay templates in \
            this codebase (timing, staging, house styles, template \
            patterns, text fitting, font loading, ffmpeg, captions, \
            charts, plugins). Returns each entry's `name` and a short \
            summary. Call this BEFORE producing a non-trivial \
            `generate_overlay` request when you're unsure which \
            template fits the spoken content, how to time per-item \
            `atSeconds`, or what the house aesthetic is. Also call \
            this when the user asks "show me the animation guide / \
            动画方法论 / how should I animate this" — list, then \
            `read_animation_rule` the most relevant entries.
            """,
            parameters: .init(
                type: "object",
                properties: [:],
                required: [],
                items: nil
            )
        )
    )

    static let readToolDefinition = ToolDefinition(
        type: "function",
        function: .init(
            name: "read_animation_rule",
            description: """
            Fetch the full markdown of one animation skill entry by \
            its `name` (as returned from `list_animation_rules`). \
            Returns the raw file contents minus the YAML front matter. \
            Use this after `list_animation_rules` to pull the \
            specific rule, style-guide section, template doc, plugin \
            doc, or workflow doc you actually need.
            """,
            parameters: .init(
                type: "object",
                properties: [
                    "name": .init(
                        type: "string",
                        description: "Entry name from `list_animation_rules` (e.g., `rules/cutti-staging`, `style-guide/aesthetic`, `SKILL`).",
                        items: nil
                    ),
                ],
                required: ["name"],
                items: nil
            )
        )
    )

    /// Parsed argument bundle for `read_animation_rule`.
    struct ReadRequest: Equatable, Sendable {
        var name: String

        static func parse(from args: [String: Any]) -> ReadRequest? {
            guard let raw = args["name"] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ReadRequest(name: normalize(trimmed))
        }
    }

    // MARK: - Internals

    /// The bundled skill root. All resource lookups go through here.
    private static let skillRoot: URL? = {
        // `subdirectory` for `urls(forResourcesWithExtension:)` accepts
        // a path relative to the bundle root.
        Bundle.cuttiMacResources.url(forResource: "AnimationSkill", withExtension: nil)
    }()

    /// Maps a public `name` (e.g. `rules/cutti-staging`) to a URL
    /// inside the bundled skill folder. Tries `<name>.md`. Returns
    /// `nil` if the file isn't bundled.
    static func url(for rawName: String) -> URL? {
        guard let root = skillRoot else { return nil }
        let name = normalize(rawName)
        let candidate = root.appendingPathComponent(name + ".md")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Tolerate trailing `.md` already in the name.
        if name.hasSuffix(".md") {
            let alt = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: alt.path) {
                return alt
            }
        }
        return nil
    }

    /// Normalizes a caller-supplied name: lowercase, strip leading
    /// slash, strip trailing `.md` (we add it back in `url(for:)`).
    private static func normalize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("/") { name.removeFirst() }
        if name.lowercased().hasSuffix(".md") {
            name = String(name.dropLast(3))
        }
        return name
    }

    /// Walks the bundled skill folder and parses each `.md` file's
    /// YAML front matter to produce the public TOC. Called once.
    private static func computeEntries() -> [Entry] {
        guard let root = skillRoot else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let relative = url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            // Strip `.md` for the public name. Preserve folder layout
            // so the agent sees `rules/cutti-staging`, not just a
            // flat list with collisions.
            let name = String(relative.dropLast(3))
            let summary = (try? extractSummary(from: url)) ?? ""
            entries.append(Entry(name: name, summary: summary))
        }
        return entries.sorted { $0.name < $1.name }
    }

    /// Extracts a one-line summary for a markdown file. Prefers the
    /// `description:` field from the YAML front matter; falls back to
    /// the first H1/H2 heading; otherwise empty.
    private static func extractSummary(from url: URL) throws -> String {
        let raw = try String(contentsOf: url, encoding: .utf8)
        if raw.hasPrefix("---") {
            // Front matter present — scan up to closing `---`.
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let range = trimmed.range(of: "description:"), range.lowerBound == trimmed.startIndex {
                    return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        // Fall back to first heading line.
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("## ") {
                return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// Strips the YAML front matter (if any) so the agent sees clean
    /// markdown without our internal metadata block.
    static func stripFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---") else { return markdown }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var idx = 1
        while idx < lines.count {
            if lines[idx].trimmingCharacters(in: .whitespaces) == "---" {
                let rest = lines.dropFirst(idx + 1).joined(separator: "\n")
                return rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            idx += 1
        }
        return markdown
    }

    /// The minimum skill content that MUST be in the agent's working
    /// memory before it generates an overlay. Concatenates the
    /// top-level skill manual (taxonomy + routing) and the staging
    /// reference (entrance/hold/exit, stagger, per-item `atSeconds`).
    /// Inlined into `generate_overlay`'s description so the agent
    /// sees it on every call without having to remember to call
    /// `read_animation_rule` first.
    ///
    /// For cloud users the relay injects the FULL bundle (12 catalog
    /// manuals + reference chapters + TSX source); this baked prompt
    /// is therefore primarily for BYOK users whose chat traffic
    /// bypasses the relay.
    ///
    /// ~12 KB of markdown / ~3K tokens — accepted cost for getting
    /// reliable house-style adherence on the most expensive tool we
    /// ship. The richer skill (catalog + reference + TSX source)
    /// stays behind `list_animation_rules` /
    /// `read_animation_rule` for the agent to pull on demand.
    static let bakedIntoOverlayPrompt: String = {
        let parts: [String] = ["SKILL", "reference/staging"]
            .compactMap { name in
                guard let raw = content(for: name) else { return nil }
                let cleaned = stripFrontMatter(raw)
                return "### \(name)\n\n\(cleaned)"
            }
        guard !parts.isEmpty else { return "" }
        return """

        ## Required reading: Cutti animation skill

        The following sections are pulled verbatim from the bundled \
        animation skill (Sources/CuttiMac/Resources/AnimationSkill/). \
        Apply them when picking the template, props, and timing. For \
        deeper rules (per-template manual with TSX source, fonts, \
        style guide, hard constraints, pre-emit checklist) call \
        `list_animation_rules` and `read_animation_rule`.

        \(parts.joined(separator: "\n\n---\n\n"))
        """
    }()
}
