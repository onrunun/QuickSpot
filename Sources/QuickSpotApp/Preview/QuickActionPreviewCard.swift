import QuickSpotCore
import SwiftUI

/// Renders rich visual preview cards for calculator, colors, units, timestamps, URLs, terminal, and system actions.
struct QuickActionPreviewCard: View {
    let item: SearchItem

    var body: some View {
        Group {
            if item.matchSource == .clipboard {
                clipboardCard
            } else if item.id.hasPrefix("color:") {
                colorCard
            } else if item.id.hasPrefix("calc:") || item.id.hasPrefix("unit:") {
                calculatorOrUnitCard
            } else if item.id.hasPrefix("pref:") {
                systemSettingsCard
            } else if case .openURL(let url) = item.action {
                webCard(url: url)
            } else if case .runTerminal(let command) = item.action {
                terminalCard(command: command)
            } else {
                systemCard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionCard<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint)
            .overlay { content().padding() }
    }

    private var colorCard: some View {
        let hex = String(item.id.dropFirst(6))
        let swatch = parsedColor(hex: hex)
        return actionCard(tint: swatch.opacity(0.14)) {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(swatch)
                    .frame(width: 92, height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: swatch.opacity(0.35), radius: 8, y: 3)
                Text(item.title)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                Text(item.subtitle)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(L10n.tr("card.color.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var calculatorOrUnitCard: some View {
        actionCard(tint: Color.orange.opacity(0.10)) {
            VStack(spacing: 10) {
                Text(item.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.orange.gradient)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .textSelection(.enabled)
                Text(item.subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(L10n.tr("card.calc.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func webCard(url: URL) -> some View {
        let isSearch = item.id.hasPrefix("web:")
        return actionCard(tint: Color.blue.opacity(0.10)) {
            VStack(spacing: 10) {
                Image(systemName: isSearch ? "magnifyingglass" : "safari")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.blue.gradient)
                Text(item.title).font(.system(size: 13.5, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                Text(url.host ?? url.absoluteString).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(L10n.tr("card.web.hint")).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private func terminalCard(command: String) -> some View {
        actionCard(tint: Color.black.opacity(0.18)) {
            VStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 44))
                Text(command).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center).lineLimit(3).textSelection(.enabled)
                Text(L10n.tr("card.terminal.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var clipboardCard: some View {
        let content = item.matchedSnippet ?? item.title
        return ScrollView([.vertical]) {
            Text(content)
                .font(.system(size: 12, design: content.contains("\n") ? .monospaced : .default))
                .foregroundStyle(.primary.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var systemSettingsCard: some View {
        actionCard(tint: Color.indigo.opacity(0.11)) {
            VStack(spacing: 10) {
                Image(systemName: item.sfSymbol ?? "gearshape.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.indigo.gradient)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(item.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var systemCard: some View {
        actionCard(tint: Color.purple.opacity(0.10)) {
            VStack(spacing: 10) {
                Image(systemName: item.sfSymbol ?? "gearshape.fill")
                    .font(.system(size: 46)).foregroundStyle(Color.purple.gradient)
                Text(item.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func parsedColor(hex: String) -> Color {
        guard let val = UInt32(hex, radix: 16) else { return .accentColor }
        return Color(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}
