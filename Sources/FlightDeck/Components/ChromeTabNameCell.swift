// Chrome tabs: the Processes name cell for a Chrome renderer that hosts tabs, e.g. "youtube.com — Lofi beats (Chrome tab)".
// The page controls its title, so the site and the "(Chrome tab)" suffix are separate labels that always show in full;
// only the title between them truncates. Laid out by hand like FrameCell (no Auto Layout), since rows refresh every
// sample. Its own reuse identifier keeps it from being recycled as a plain name cell.
import AppKit
import FlightDeckCore

final class ChromeTabNameCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("nameChromeTab")
    private let hostLabel = ChromeTabNameCell.label(.byClipping)
    private let titleLabel = ChromeTabNameCell.label(.byTruncatingTail)
    private let suffixLabel = ChromeTabNameCell.label(.byClipping)
    private let icon = NSImageView()

    private static func label(_ mode: NSLineBreakMode) -> NSTextField {
        let l = NSTextField(labelWithString: ""); l.lineBreakMode = mode; l.maximumNumberOfLines = 1
        return l
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID
        for v in [icon, hostLabel, titleLabel, suffixLabel] as [NSView] { addSubview(v) }
        imageView = icon
        suffixLabel.textColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(label: ChromeTabLabel, icon image: NSImage?, font: NSFont, tooltip: String) {
        for l in [hostLabel, titleLabel, suffixLabel] where l.font != font { l.font = font }
        hostLabel.stringValue = label.host
        titleLabel.stringValue = label.title.map { "— \($0)" } ?? ""
        titleLabel.isHidden = label.title == nil
        suffixLabel.stringValue = label.suffix
        suffixLabel.isHidden = label.suffix.isEmpty
        icon.image = image
        toolTip = tooltip
        setAccessibilityLabel(label.plain)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, gap: CGFloat = 5
        icon.frame = NSRect(x: 2, y: (h - 16) / 2, width: 16, height: 16)
        var x: CGFloat = 24
        let end = max(bounds.width - 4, x)
        // Host and suffix take their natural width first; the title gets whatever is left.
        let hostW = min(hostLabel.intrinsicContentSize.width, end - x)
        let suffixW = suffixLabel.isHidden ? 0 : min(suffixLabel.intrinsicContentSize.width, max(end - x - hostW - gap, 0))
        let titleRoom = max(end - x - hostW - suffixW - (suffixLabel.isHidden ? 0 : gap) - (titleLabel.isHidden ? 0 : gap), 0)
        let titleW = titleLabel.isHidden ? 0 : min(titleLabel.intrinsicContentSize.width, titleRoom)
        let th = hostLabel.intrinsicContentSize.height, y = (h - th) / 2
        hostLabel.frame = NSRect(x: x, y: y, width: hostW, height: th); x += hostW
        if !titleLabel.isHidden { x += gap; titleLabel.frame = NSRect(x: x, y: y, width: titleW, height: th); x += titleW }
        if !suffixLabel.isHidden { x += gap; suffixLabel.frame = NSRect(x: x, y: y, width: suffixW, height: th) }
    }
}
