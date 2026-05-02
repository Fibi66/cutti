import Foundation

/// Built-in sound-effect catalog, tuned for the **口播 / 访谈 / 播客 /
/// 长视频解说** editing context — not the "meme" palette. Every effect
/// here is something you actually hear in a Lex Fridman / Diary of a
/// CEO / Joe Rogan / 东吴同学会-style highlight reel:
///
///   - low cinematic hits under bold statements
///   - subtle whoosh / swish for B-roll cross-cuts
///   - warm chimes and plucks to punctuate key quotes
///   - digital glitches to cover jump cuts
///   - typewriter / clock ticks for on-screen captions
///   - vinyl crackle / heartbeat for atmosphere
///
/// No airhorns, no sad trombones, no MLG boom — those are a different
/// workflow (and almost never appropriate for interviews).
///
/// Everything is generated at runtime by `SFXSynthesizer`; the first
/// use of each kind writes a deterministic .wav into the cache dir
/// and subsequent uses reuse it. Display names + categories + tags
/// are localization keys looked up through `L(...)` at render time;
/// see `en.lproj` / `zh-Hans.lproj` for the bilingual entries.
enum SFXKind: String, CaseIterable, Sendable {
    // Cinematic emphasis
    case braaam
    case subDrop       = "sub_drop"
    case impactHit     = "impact_hit"
    case riser

    // Transitions
    case whoosh
    case swish
    case glitch
    case tapeStop      = "tape_stop"

    // Highlight stingers
    case softChime     = "soft_chime"
    case pluck
    case shimmer
    case pop

    // UI / captions
    case typewriter
    case tick
    case notification
    case beep

    // Atmosphere
    case vinylCrackle  = "vinyl_crackle"
    case heartbeat
}

enum SFXCategory: String, CaseIterable, Sendable {
    case cinematic   // Emphasis under key statements
    case transition  // B-roll / topic crossfades
    case highlight   // Quote / callout stingers
    case ui          // Captions, countdowns, notifications
    case atmosphere  // Background texture

    var displayKey: String {
        switch self {
        case .cinematic:   return "SFX Cinematic"
        case .transition:  return "SFX Transition"
        case .highlight:   return "SFX Highlight"
        case .ui:          return "SFX UI"
        case .atmosphere:  return "SFX Atmosphere"
        }
    }
}

struct SFXDefinition: Identifiable, Sendable {
    let kind: SFXKind
    let category: SFXCategory
    let displayKey: String
    let symbol: String
    let durationSeconds: Double
    let searchTagsEN: [String]
    let searchTagsZH: [String]

    var id: String { kind.rawValue }
}

enum SFXCatalog {
    static let all: [SFXDefinition] = [
        // ── Cinematic emphasis ───────────────────────────────────
        .init(kind: .braaam, category: .cinematic,
              displayKey: "SFX Braaam",
              symbol: "waveform.path.ecg",
              durationSeconds: 2.2,
              searchTagsEN: ["braaam", "brass", "inception", "trailer", "hit", "horn", "cinematic"],
              searchTagsZH: ["铜管", "低音号", "预告片", "电影感", "重音", "氛围"]),
        .init(kind: .subDrop, category: .cinematic,
              displayKey: "SFX Sub drop",
              symbol: "arrow.down.to.line",
              durationSeconds: 1.5,
              searchTagsEN: ["sub", "drop", "bass", "boom", "thump", "punctuate"],
              searchTagsZH: ["低频", "下潜", "低音", "重音", "砸"]),
        .init(kind: .impactHit, category: .cinematic,
              displayKey: "SFX Impact hit",
              symbol: "burst.fill",
              durationSeconds: 0.9,
              searchTagsEN: ["impact", "hit", "thud", "punch", "slam", "cinematic"],
              searchTagsZH: ["冲击", "撞击", "重击", "强调", "砰"]),
        .init(kind: .riser, category: .cinematic,
              displayKey: "SFX Riser",
              symbol: "arrow.up.right",
              durationSeconds: 2.0,
              searchTagsEN: ["riser", "build", "tension", "uplifter", "swell"],
              searchTagsZH: ["上升", "蓄力", "张力", "铺垫", "过渡"]),

        // ── Transitions ──────────────────────────────────────────
        .init(kind: .whoosh, category: .transition,
              displayKey: "SFX Whoosh",
              symbol: "wind",
              durationSeconds: 0.7,
              searchTagsEN: ["whoosh", "swoosh", "air", "transition", "fly-by", "sweep"],
              searchTagsZH: ["嗖", "风", "呼", "过场", "转场", "掠过"]),
        .init(kind: .swish, category: .transition,
              displayKey: "SFX Swish",
              symbol: "wind.circle",
              durationSeconds: 0.35,
              searchTagsEN: ["swish", "soft", "quick", "subtle", "accent"],
              searchTagsZH: ["刷", "轻扫", "轻柔", "细微", "点缀"]),
        .init(kind: .glitch, category: .transition,
              displayKey: "SFX Glitch",
              symbol: "exclamationmark.triangle.fill",
              durationSeconds: 0.35,
              searchTagsEN: ["glitch", "digital", "static", "jumpcut", "error", "crackle"],
              searchTagsZH: ["故障", "电流", "噪点", "跳切", "数字", "抖动"]),
        .init(kind: .tapeStop, category: .transition,
              displayKey: "SFX Tape stop",
              symbol: "pause.rectangle",
              durationSeconds: 1.0,
              searchTagsEN: ["tape", "stop", "slowdown", "vhs", "rewind-stop", "drag"],
              searchTagsZH: ["磁带", "停带", "减速", "VHS", "倒带", "卡带"]),

        // ── Highlight stingers ───────────────────────────────────
        .init(kind: .softChime, category: .highlight,
              displayKey: "SFX Soft chime",
              symbol: "sparkles",
              durationSeconds: 1.4,
              searchTagsEN: ["chime", "bell", "ding", "warm", "highlight", "callout", "quote"],
              searchTagsZH: ["铃声", "钟声", "柔和", "亮点", "引文", "提示"]),
        .init(kind: .pluck, category: .highlight,
              displayKey: "SFX Pluck",
              symbol: "guitars",
              durationSeconds: 1.0,
              searchTagsEN: ["pluck", "string", "stinger", "accent", "note", "quote"],
              searchTagsZH: ["拨弦", "弹", "提示", "强调", "金句"]),
        .init(kind: .shimmer, category: .highlight,
              displayKey: "SFX Shimmer",
              symbol: "sparkle",
              durationSeconds: 1.8,
              searchTagsEN: ["shimmer", "sparkle", "magic", "bells", "tail", "ethereal"],
              searchTagsZH: ["闪烁", "星光", "余韵", "梦幻", "华丽"]),
        .init(kind: .pop, category: .highlight,
              displayKey: "SFX Pop",
              symbol: "circle.circle",
              durationSeconds: 0.25,
              searchTagsEN: ["pop", "bubble", "tap", "bounce", "accent"],
              searchTagsZH: ["啵", "泡", "点", "弹出", "弹窗"]),

        // ── UI / captions ────────────────────────────────────────
        .init(kind: .typewriter, category: .ui,
              displayKey: "SFX Typewriter",
              symbol: "keyboard",
              durationSeconds: 1.4,
              searchTagsEN: ["typewriter", "typing", "keyboard", "caption", "text", "subtitle"],
              searchTagsZH: ["打字机", "打字", "键盘", "字幕", "文字"]),
        .init(kind: .tick, category: .ui,
              displayKey: "SFX Clock tick",
              symbol: "clock",
              durationSeconds: 1.2,
              searchTagsEN: ["tick", "clock", "timer", "countdown", "watch", "second"],
              searchTagsZH: ["秒针", "滴答", "钟", "计时", "倒数"]),
        .init(kind: .notification, category: .ui,
              displayKey: "SFX Notification",
              symbol: "bell.badge.fill",
              durationSeconds: 0.8,
              searchTagsEN: ["notification", "alert", "tone", "message", "ping", "chat"],
              searchTagsZH: ["通知", "提示", "消息", "提醒", "提示音"]),
        .init(kind: .beep, category: .ui,
              displayKey: "SFX Censor beep",
              symbol: "speaker.wave.2",
              durationSeconds: 0.6,
              searchTagsEN: ["beep", "censor", "bleep", "mute", "tone"],
              searchTagsZH: ["哔", "消音", "审查", "遮蔽", "提示音"]),

        // ── Atmosphere ───────────────────────────────────────────
        .init(kind: .vinylCrackle, category: .atmosphere,
              displayKey: "SFX Vinyl crackle",
              symbol: "opticaldisc",
              durationSeconds: 2.5,
              searchTagsEN: ["vinyl", "crackle", "noise", "lofi", "retro", "static", "texture"],
              searchTagsZH: ["黑胶", "底噪", "噼啪", "复古", "年代感", "氛围"]),
        .init(kind: .heartbeat, category: .atmosphere,
              displayKey: "SFX Heartbeat",
              symbol: "heart.fill",
              durationSeconds: 2.0,
              searchTagsEN: ["heartbeat", "heart", "pulse", "tension", "suspense", "thump"],
              searchTagsZH: ["心跳", "脉搏", "紧张", "悬念", "沉重"]),
    ]

    static func definition(for kind: SFXKind) -> SFXDefinition {
        guard let def = all.first(where: { $0.kind == kind }) else {
            fatalError("SFXCatalog: missing definition for \(kind.rawValue)")
        }
        return def
    }
}
