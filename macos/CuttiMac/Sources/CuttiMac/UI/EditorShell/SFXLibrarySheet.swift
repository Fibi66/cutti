import SwiftUI
import AVFoundation

/// Bilingual browser for the built-in sound-effect library.
///
/// Searching happens against the display name (in the current UI
/// language) AND the per-language tag arrays, so a user typing "嗖"
/// in the English UI still finds `whoosh`, and vice versa. Preview
/// plays the cached .wav via a module-local `AVAudioPlayer`.
struct SFXLibrarySheet: View {
    let onInsert: (SFXKind) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var selectedCategory: SFXCategory? = nil
    @State private var previewPlayer: SFXPreviewPlayer = .init()
    @State private var nowPlaying: SFXKind? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchBar
            categoryFilter
            Divider().opacity(0.4)
            list
            footer
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onDisappear { previewPlayer.stop() }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(EditorShellStyle.accentSolid)
            T("Sound effects")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            T("Inserted at the current playhead")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField(L("Search (中文 / English)…"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var categoryFilter: some View {
        HStack(spacing: 6) {
            categoryChip(nil, label: L("All"))
            ForEach(SFXCategory.allCases, id: \.self) { cat in
                categoryChip(cat, label: L(cat.displayKey))
            }
            Spacer()
        }
    }

    private func categoryChip(_ cat: SFXCategory?, label: String) -> some View {
        Button {
            selectedCategory = cat
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selectedCategory == cat
                              ? EditorShellStyle.accentSolid.opacity(0.22)
                              : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(selectedCategory == cat ? EditorShellStyle.accentSolid : .primary)
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredDefinitions, id: \.id) { def in
                    row(for: def)
                }
                if filteredDefinitions.isEmpty {
                    T("No sound effects match your search.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(for def: SFXDefinition) -> some View {
        let isPlaying = nowPlaying == def.kind
        return HStack(spacing: 10) {
            Image(systemName: def.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(EditorShellStyle.accentSolid)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(L(def.displayKey))
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    Text(L(def.category.displayKey))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1fs", def.durationSeconds))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Button {
                preview(def.kind)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Preview"))

            Button {
                onInsert(def.kind)
            } label: {
                Label { T("Add") } icon: { Image(systemName: "plus") }
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var footer: some View {
        HStack {
            T("All effects are synthesized locally — no network, no license fees.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onCancel) { T("Close") }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Logic

    private var filteredDefinitions: [SFXDefinition] {
        var list = SFXCatalog.all
        if let cat = selectedCategory {
            list = list.filter { $0.category == cat }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { def in
            let displayHit = L(def.displayKey).lowercased().contains(q)
            let enHit = def.searchTagsEN.contains { $0.lowercased().contains(q) }
            let zhHit = def.searchTagsZH.contains { $0.contains(q) || $0.lowercased().contains(q) }
            let categoryHit = L(def.category.displayKey).lowercased().contains(q)
            return displayHit || enHit || zhHit || categoryHit
        }
    }

    private func preview(_ kind: SFXKind) {
        if nowPlaying == kind {
            previewPlayer.stop()
            nowPlaying = nil
            return
        }
        do {
            let url = try SFXRenderer.ensureRendered(kind)
            previewPlayer.play(url: url) { [kind] in
                // `self` is a struct — stash via @State so the closure
                // sees the latest wrapper.
                Task { @MainActor in
                    if nowPlaying == kind { nowPlaying = nil }
                }
            }
            nowPlaying = kind
        } catch {
            nowPlaying = nil
        }
    }
}

/// Thin wrapper around AVAudioPlayer so the sheet can preview without
/// exposing AVFoundation concerns to SwiftUI. One-shot: tapping a new
/// row stops the prior preview.
@MainActor
final class SFXPreviewPlayer {
    private var player: AVAudioPlayer?
    private var delegate: Delegate?

    func play(url: URL, onFinish: @escaping () -> Void) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let d = Delegate(onFinish: onFinish)
            p.delegate = d
            p.prepareToPlay()
            p.play()
            self.player = p
            self.delegate = d
        } catch {
            onFinish()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        delegate = nil
    }

    private final class Delegate: NSObject, AVAudioPlayerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}
