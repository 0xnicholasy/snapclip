import AppKit
import SnapClipCore

/// NSWindow that closes on Esc.
private final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

/// Compact About window: icon, name, version, one tagline, a short hint list and two links.
@MainActor
final class AboutWindow: NSObject {
    private static let width: CGFloat = 300
    private static let githubURL = "https://github.com/0xnicholasy/snapclip"
    private static let websiteURL = "https://www.0xnicholasy.xyz/en"

    private let window: NSWindow
    private var hasCentered = false

    override init() {
        window = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = makeContent()
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width: Self.width, height: 300))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !hasCentered {
            window.center()
            hasCentered = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func makeContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(icon)

        stack.addArrangedSubview(label("SnapClip", font: .systemFont(ofSize: 17, weight: .semibold), color: .labelColor))

        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            stack.addArrangedSubview(
                label("Version \(version)", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }

        let tagline = label(
            "Copies screenshots to the clipboard and tidies them up after "
                + "\(Int(SnapClipConstants.maxAge / 60)) minutes.",
            font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        tagline.alignment = .center
        tagline.maximumNumberOfLines = 0
        tagline.lineBreakMode = .byWordWrapping
        tagline.preferredMaxLayoutWidth = Self.width - 48
        stack.addArrangedSubview(tagline)

        stack.setCustomSpacing(18, after: tagline)
        let rows = NSStackView(views: [
            hintRow(symbol: "cursorarrow.click", text: "Click a row to copy"),
            hintRow(symbol: "eye", text: "Open in Preview (keeps it)"),
            hintRow(symbol: "pin", text: "Keep (never trash)"),
            hintRow(symbol: "trash", text: "Move to Trash now"),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        stack.addArrangedSubview(rows)

        let links = NSStackView(views: [
            linkButton("GitHub", action: #selector(openGitHub)),
            label("\u{00B7}", font: .systemFont(ofSize: 12), color: .secondaryLabelColor),
            linkButton("Website", action: #selector(openWebsite)),
        ])
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 6
        stack.setCustomSpacing(18, after: rows)
        stack.addArrangedSubview(links)

        let credit = label(
            "Made by 0xnicholasy \u{00B7} MIT License", font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor)
        stack.setCustomSpacing(12, after: links)
        stack.addArrangedSubview(credit)

        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    private func hintRow(symbol: String, text: String) -> NSView {
        let image = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let row = NSStackView(views: [image, label(text, font: .systemFont(ofSize: 12), color: .labelColor)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .controlAccentColor
        return button
    }

    @objc private func openGitHub() { open(Self.githubURL) }
    @objc private func openWebsite() { open(Self.websiteURL) }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
