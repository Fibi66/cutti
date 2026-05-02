import SwiftUI
import CuttiKit

struct ProjectDashboardView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var registry: ProjectRegistry
    @StateObject private var summaries = ProjectSummaryStore.shared

    @State private var showingNewProject = false
    @State private var newProjectName = ""
    @State private var errorMessage: String?
    @State private var showingSettings = false
    @ObservedObject private var relaySession = RelaySession.shared

    private var sortedProjects: [ProjectInfo] {
        registry.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        heroBanner
                        featuresShowcase
                        projectsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Cutti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                        Task { await relaySession.refreshMe() }
                    } label: {
                        if let c = relaySession.credits, relaySession.isSignedIn {
                            Label("\(c.remaining)", systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                                .font(.callout.monospacedDigit())
                        } else {
                            Label("设置", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newProjectName = ""
                        showingNewProject = true
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
            }
            .alert("New Project", isPresented: $showingNewProject) {
                TextField("Project name", text: $newProjectName)
                Button("Create") { createProject() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(L(errorMessage ?? ""))
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.06, blue: 0.10),
                Color(red: 0.02, green: 0.02, blue: 0.04),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Hero banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.30, blue: 0.55),
                    Color(red: 0.55, green: 0.30, blue: 0.95),
                    Color(red: 0.25, green: 0.35, blue: 0.95),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Decorative orbs for the premium "marketing" feel.
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: 140, y: -80)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 180, height: 180)
                .blur(radius: 40)
                .offset(x: -80, y: 80)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(L("AI · 智能剪辑"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                }
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.white.opacity(0.20))
                )

                Text(L("让 AI 帮你剪出好视频"))
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(L("一键裁掉停顿重复,自动生成字幕和章节"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)

                Button {
                    newProjectName = ""
                    showingNewProject = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text(L("开始新项目"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color(red: 0.15, green: 0.10, blue: 0.30))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Color.white)
                    )
                }
                .padding(.top, 4)
            }
            .padding(22)
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.pink.opacity(0.25), radius: 18, y: 8)
    }

    // MARK: - Features showcase

    private var featuresShowcase: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("热门 AI 玩法"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(L("全部"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.features) { f in
                        Button {
                            newProjectName = ""
                            showingNewProject = true
                        } label: {
                            FeatureTile(feature: f)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Projects section

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("我的项目"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                if !registry.projects.isEmpty {
                    Text("\(registry.projects.count)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.white.opacity(0.10))
                        )
                }
                Spacer()
            }
            if registry.projects.isEmpty {
                emptyProjectsCard
            } else {
                projectGridContent
            }
        }
    }

    private var emptyProjectsCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            Text(L("还没有项目"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(L("点击上方开始新项目,或挑一个 AI 玩法试试"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var projectGridContent: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 14)],
            spacing: 14
        ) {
            ForEach(sortedProjects) { project in
                Button {
                    open(project)
                } label: {
                    ProjectCard(
                        project: project,
                        summary: summaries.summary(for: project.id)
                    )
                }
                .buttonStyle(.plain)
                .onAppear {
                    summaries.prime(
                        projectID: project.id,
                        projectRoot: registry.projectRoot(for: project.id)
                    )
                }
                .contextMenu {
                    Button(role: .destructive) {
                        delete(project)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func createProject() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespaces)
        do {
            let info = try registry.createProject(name: trimmed)
            appState.open(info)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ project: ProjectInfo) {
        appState.open(project)
    }

    private func delete(_ project: ProjectInfo) {
        do {
            try registry.deleteProject(id: project.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Featured AI showcase data

    struct FeatureShowcase: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let gradient: [Color]
    }

    /// Six marketing tiles shown horizontally under the hero. Each
    /// previews one of the AI presets that's fully wired inside the
    /// editor's AI toolbox; tapping any of them routes to the
    /// new-project alert so the user can start editing. We
    /// deliberately stop short of auto-opening the AI sheet with a
    /// preset pre-selected — that would promise an end-to-end flow
    /// we haven't shipped.
    static let features: [FeatureShowcase] = [
        .init(
            id: "home.feature.smartCut",
            title: "一键首剪",
            subtitle: "AI 自动裁掉停顿、重复、半句",
            icon: "sparkles",
            gradient: [
                Color(red: 1.0, green: 0.44, blue: 0.55),
                Color(red: 0.95, green: 0.28, blue: 0.78),
            ]
        ),
        .init(
            id: "home.feature.subtitles",
            title: "智能字幕",
            subtitle: "本机 SFSpeech · 秒级识别",
            icon: "captions.bubble.fill",
            gradient: [
                Color(red: 0.28, green: 0.58, blue: 0.98),
                Color(red: 0.24, green: 0.85, blue: 0.95),
            ]
        ),
        .init(
            id: "home.feature.fillers",
            title: "去除口癖",
            subtitle: "uh / um / 嗯 / 那个 一键净化",
            icon: "text.badge.minus",
            gradient: [
                Color(red: 0.56, green: 0.40, blue: 0.98),
                Color(red: 0.88, green: 0.38, blue: 0.98),
            ]
        ),
        .init(
            id: "home.feature.bilingual",
            title: "双语字幕",
            subtitle: "中英互译 · 云端 AI",
            icon: "character.book.closed.fill",
            gradient: [
                Color(red: 0.98, green: 0.58, blue: 0.28),
                Color(red: 1.0, green: 0.78, blue: 0.28),
            ]
        ),
        .init(
            id: "home.feature.tts",
            title: "文字配音",
            subtitle: "Apple TTS · 多语种旁白",
            icon: "speaker.wave.2.bubble.fill",
            gradient: [
                Color(red: 0.25, green: 0.78, blue: 0.60),
                Color(red: 0.20, green: 0.65, blue: 0.90),
            ]
        ),
        .init(
            id: "home.feature.aiImage",
            title: "AI 图像",
            subtitle: "输入描述 · 生成贴图 / 封面",
            icon: "photo.badge.plus.fill",
            gradient: [
                Color(red: 0.30, green: 0.40, blue: 0.98),
                Color(red: 0.58, green: 0.40, blue: 0.98),
            ]
        ),
    ]
}

private struct FeatureTile: View {
    let feature: ProjectDashboardView.FeatureShowcase

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: feature.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Inner glossy highlight.
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 80, height: 80)
                .blur(radius: 16)
                .offset(x: 90, y: -40)

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: feature.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                    )
                Spacer(minLength: 0)
                Text(L(feature.title))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(L(feature.subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(width: 150, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: feature.gradient.last?.opacity(0.35) ?? .clear, radius: 10, y: 6)
    }
}

private struct ProjectCard: View {
    let project: ProjectInfo
    let summary: ProjectSummaryStore.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.14))
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let thumb = summary?.thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let s = summary, s.durationSeconds > 0 {
                        Text(formatDuration(s.durationSeconds))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.6))
                            )
                            .padding(6)
                    }
                }
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(project.lastOpenedAt.formatted(date: .abbreviated, time: .omitted))
                if let s = summary, s.clipCount > 0 {
                    Text("·")
                    Text("\(s.clipCount) 个片段")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
