import SwiftUI

// MARK: - Card

/// Generic dark panel container used as the wrapper for nearly every
/// content block in the redesigned Settings. Mirrors `Card({padding})`
/// from the Obsidian-Pro mockup.
///
/// `padding == nil` means "no internal padding"; the caller supplies its
/// own row-by-row padding. This is necessary for cards that contain
/// `SettingsRow` strips (which manage their own horizontal padding so
/// the bottom divider can run edge-to-edge).
struct SettingsCard<Content: View>: View {
    var padding: CGFloat? = SettingsTheme.cardPaddingH
    @ViewBuilder var content: () -> Content

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if let p = padding {
                inner.padding(p)
            } else {
                inner
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(SettingsTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(SettingsTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Row

/// A label + content row inside a `SettingsCard(padding: nil)`. Provides
/// the fixed-width label column on the left, optional `sub` caption
/// underneath, optional bottom divider, and right-aligned trailing
/// content. Mirrors `Row({label, sub, divider, align})` from the mockup.
struct SettingsRow<Trailing: View>: View {
    let label: LocalizedStringKey
    var sub: LocalizedStringKey? = nil
    var divider: Bool = true
    var align: VerticalAlignment = .center
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: align, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    T(label)
                        .font(SettingsTheme.rowLabel)
                        .foregroundStyle(SettingsTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sub {
                        T(sub)
                            .font(SettingsTheme.rowSub)
                            .foregroundStyle(SettingsTheme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: SettingsTheme.rowLabelWidth, alignment: .leading)

                Spacer(minLength: 8)

                trailing()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, SettingsTheme.rowVerticalPadding)
            .padding(.horizontal, SettingsTheme.cardPaddingH)
            .frame(minHeight: SettingsTheme.rowMinHeight)

            if divider {
                Rectangle()
                    .fill(SettingsTheme.borderSoft)
                    .frame(height: 1)
            }
        }
    }
}

// MARK: - Section header / group title

/// Title strip at the top of every detail page: 18pt semibold title +
/// 12pt dim subtitle + optional trailing action area.
struct SettingsSectionHeader<Action: View>: View {
    let title: LocalizedStringKey
    var sub: LocalizedStringKey? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                T(title)
                    .font(SettingsTheme.sectionTitle)
                    .foregroundStyle(SettingsTheme.text)
                if let sub {
                    T(sub)
                        .font(SettingsTheme.sectionSub)
                        .foregroundStyle(SettingsTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            action()
        }
        .padding(.bottom, 16)
    }
}

extension SettingsSectionHeader where Action == EmptyView {
    /// Convenience init for headers without a trailing action.
    init(title: LocalizedStringKey, sub: LocalizedStringKey? = nil) {
        self.init(title: title, sub: sub, action: { EmptyView() })
    }
}

/// Faint uppercase label used to title a sub-group inside a section
/// (e.g. "CHAT / LLM" above the LLM credentials card).
struct SettingsGroupTitle: View {
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil

    var body: some View {
        HStack(spacing: 8) {
            T(title)
                .font(SettingsTheme.groupTitle)
                .foregroundStyle(SettingsTheme.textFaint)
                .textCase(.uppercase)
                .tracking(0.7)
            if let hint {
                T(hint)
                    .font(SettingsTheme.captionFaint)
                    .foregroundStyle(SettingsTheme.textFaint)
            }
            Spacer()
        }
        .padding(.bottom, 6)
        .padding(.top, 14)
    }
}

// MARK: - Buttons

/// Visual variants of `SettingsButton`, in order of decreasing prominence.
enum SettingsButtonVariant {
    case primary    // accent fill on bg=panel, used for the main action
    case secondary  // panel3 fill, used for secondary affordances
    case danger     // red fill, used for destructive actions
    case ghost      // text-only, used for tertiary actions
}

/// Three sizes match the mockup's `sm`/`md`/`lg` heights.
enum SettingsButtonSize {
    case small
    case medium
    case large

    var height: CGFloat {
        switch self {
        case .small:  return SettingsTheme.controlHeightSmall
        case .medium: return SettingsTheme.controlHeightMedium
        case .large:  return SettingsTheme.controlHeightLarge
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 13
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small:  return 10
        case .medium: return 12
        case .large:  return 16
        }
    }
}

/// Custom button matching the mockup's `Btn` component. SwiftUI
/// `Button` + a `.buttonStyle(SettingsButtonStyle(...))` would also
/// work but we've found custom-overlay buttons more reliable for
/// fitting non-standard heights / chrome.
struct SettingsButton<Label: View>: View {
    var variant: SettingsButtonVariant = .secondary
    var size: SettingsButtonSize = .medium
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(textColor)
                }
                label()
                    .font(SettingsTheme.ui(size.fontSize, weight: .medium))
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(backgroundShape)
            .overlay(borderOverlay)
            .overlay(focusOverlay)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading || disabled)
        .opacity(disabled ? 0.45 : 1.0)
        .focusable()
        .focused($focused)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var backgroundShape: some View {
        let r = RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
        switch variant {
        case .primary:   r.fill(SettingsTheme.accent)
        case .secondary: r.fill(SettingsTheme.panel3)
        case .danger:    r.fill(SettingsTheme.red)
        case .ghost:     r.fill(Color.clear)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let r = RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
        switch variant {
        case .primary, .danger: r.strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        case .secondary:        r.strokeBorder(SettingsTheme.border, lineWidth: 1)
        case .ghost:            r.strokeBorder(Color.clear, lineWidth: 0)
        }
    }

    @ViewBuilder
    private var focusOverlay: some View {
        if focused {
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius + 1, style: .continuous)
                .strokeBorder(SettingsTheme.accent.opacity(0.55), lineWidth: 2)
                .padding(-2)
        }
    }

    private var textColor: Color {
        switch variant {
        case .primary:   return Color(.sRGB, red: 0.04, green: 0.04, blue: 0.05, opacity: 1)
        case .secondary: return SettingsTheme.text
        case .danger:    return Color.white
        case .ghost:     return SettingsTheme.textDim
        }
    }
}

extension SettingsButton where Label == Text {
    /// Convenience: `SettingsButton("Cancel", variant: .ghost) { ... }`.
    init(_ titleKey: LocalizedStringKey,
         variant: SettingsButtonVariant = .secondary,
         size: SettingsButtonSize = .medium,
         loading: Bool = false,
         disabled: Bool = false,
         action: @escaping () -> Void) {
        self.init(variant: variant, size: size, loading: loading,
                  disabled: disabled, action: action,
                  label: { T(titleKey) })
    }
}

// MARK: - Toggle

/// Custom 28×16 pill toggle. Wraps a `Bool` binding and looks identical
/// to the mockup's `Toggle({on, label})`. Uses the system `Toggle` for
/// accessibility / keyboard support and overlays the custom visuals.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var label: LocalizedStringKey? = nil

    var body: some View {
        // SwiftUI `Toggle` with a custom style would be cleanest, but
        // SwiftUI on macOS 14 doesn't honor custom `ToggleStyle` for
        // keyboard focus rings consistently. Stamp the visuals on top
        // of an invisible-but-accessible Toggle instead.
        ZStack {
            // Visible custom switch:
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? SettingsTheme.accent : SettingsTheme.panel3)
                    .frame(width: 28, height: 16)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.12), value: isOn)

            // Invisible Toggle stays in the responder chain so VoiceOver,
            // Tab focus, and ⎵/Return all "just work". Hidden visually
            // but receives every input event because it's drawn over
            // the custom switch with full opacity 0.
            Toggle(isOn: $isOn) {
                if let label { T(label) }
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .opacity(0.0)
            .frame(width: 28, height: 16)
            .accessibilityLabel(label.map { Text($0, bundle: nil) } ?? Text(""))
        }
        .frame(width: 28, height: 16)
    }
}

// MARK: - Field (text + secure)

/// Single-line text input. Use `secure: true` for API keys / passwords.
/// `mono: true` swaps to JetBrains Mono. The mockup's `Field` component.
struct SettingsField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey? = nil
    var secure: Bool = false
    var mono: Bool = false
    var maxWidth: CGFloat? = 340

    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            // Field background + border
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                .fill(SettingsTheme.panel2)
            RoundedRectangle(cornerRadius: SettingsTheme.controlRadius, style: .continuous)
                .strokeBorder(focused ? SettingsTheme.accent.opacity(0.55) : SettingsTheme.border,
                              lineWidth: focused ? 2 : 1)

            HStack(spacing: 0) {
                Group {
                    if secure {
                        SecureField("", text: $text, prompt: placeholder.map { T($0) })
                    } else {
                        TextField("", text: $text, prompt: placeholder.map { T($0) })
                    }
                }
                .textFieldStyle(.plain)
                .font(mono ? SettingsTheme.mono(11) : SettingsTheme.ui(12))
                .foregroundStyle(SettingsTheme.text)
                .focused($focused)
                .padding(.horizontal, 10)
            }
        }
        .frame(height: SettingsTheme.controlHeightMedium)
        .frame(maxWidth: maxWidth ?? .infinity)
    }
}

// MARK: - Status dot

enum SettingsStatusTone {
    case green
    case red
    case amber
    case neutral

    var color: Color {
        switch self {
        case .green:   return SettingsTheme.green
        case .red:     return SettingsTheme.red
        case .amber:   return SettingsTheme.amber
        case .neutral: return SettingsTheme.textFaint
        }
    }
}

/// 6pt colored dot + halo + caption. Mirrors the mockup's `StatusDot`.
struct SettingsStatusDot: View {
    let tone: SettingsStatusTone
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tone.color.opacity(0.25))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
            }
            T(label)
                .font(SettingsTheme.caption)
                .foregroundStyle(SettingsTheme.textDim)
        }
    }
}

/// Variant of `SettingsStatusDot` for cases where the label isn't a
/// localized key (e.g. a runtime "last test" timestamp).
struct SettingsStatusDotRaw: View {
    let tone: SettingsStatusTone
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tone.color.opacity(0.25))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(tone.color)
                    .frame(width: 6, height: 6)
            }
            Text(label)
                .font(SettingsTheme.caption)
                .foregroundStyle(SettingsTheme.textDim)
        }
    }
}

// MARK: - Progress bar

/// 6pt-tall progress bar with an amber/red tint when the bar gets full.
/// Mirrors the mockup's `ProgressBar({pct})`. Pct is 0…1.
struct SettingsProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, value))
            let tint: Color = {
                if clamped > 0.95 { return SettingsTheme.red }
                if clamped > 0.70 { return SettingsTheme.amber }
                return SettingsTheme.accent
            }()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(SettingsTheme.panel3)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * clamped))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text("\(Int(value * 100)) percent"))
    }
}

// MARK: - Radio card

/// Selectable card used by `ProviderSection`'s mode picker and
/// `QualitySection`'s quality picker. Big tappable target with a small
/// radio bullet, title, subtitle, and optional "Recommended"-style tag.
///
/// To stay accessible, the *visual* card is a Button with `.buttonStyle(.plain)`,
/// and call sites should wrap the group of radio cards in
/// `.accessibilityRepresentation { Picker(...) }` so VoiceOver users
/// see a real radio group.
struct SettingsRadioCard: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var tag: LocalizedStringKey? = nil
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    radioBullet
                    T(title)
                        .font(SettingsTheme.bodyMedium)
                        .foregroundStyle(SettingsTheme.text)
                    Spacer(minLength: 6)
                    if let tag {
                        T(tag)
                            .font(SettingsTheme.ui(9.5, weight: .semibold))
                            .foregroundStyle(selected ? SettingsTheme.accent : SettingsTheme.textFaint)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                }
                if let subtitle {
                    T(subtitle)
                        .font(SettingsTheme.captionFaint)
                        .foregroundStyle(SettingsTheme.textDim)
                        .padding(.leading, 22)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                    .fill(selected ? SettingsTheme.accentSoft : SettingsTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(selected ? SettingsTheme.accent : SettingsTheme.border,
                                  lineWidth: 1)
            )
            .overlay(focusOverlay)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
    }

    private var radioBullet: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? SettingsTheme.accent : SettingsTheme.textFaint,
                              lineWidth: 1.5)
                .frame(width: 14, height: 14)
            if selected {
                Circle()
                    .fill(SettingsTheme.accent)
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var focusOverlay: some View {
        if focused {
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius + 1, style: .continuous)
                .strokeBorder(SettingsTheme.accent.opacity(0.45), lineWidth: 2)
                .padding(-2)
        }
    }
}

// MARK: - Callouts

/// Soft amber "limitations" / warning callout. Used inside the BYOK
/// section to flag features that only run on Cutti Cloud.
struct SettingsWarningCallout: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SettingsTheme.amber)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                T(title)
                    .font(SettingsTheme.bodyMedium)
                    .foregroundStyle(SettingsTheme.text)
                T(message)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .fill(SettingsTheme.amberSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(SettingsTheme.amber.opacity(0.2), lineWidth: 1)
        )
    }
}

/// Soft accent callout for informational / "what's enabled" content.
struct SettingsInfoCallout<Content: View>: View {
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(SettingsTheme.accent)
                .padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
