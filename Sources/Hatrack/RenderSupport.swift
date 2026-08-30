import AppKit

/// Offscreen rendering helpers for --render-states and --render-panel.
///
/// Everything is drawn at 3x.
///
/// What matters is pixels per *displayed* pixel, not the multiple of the
/// drawing's own logical size. These sheets are ~690pt wide but get shown far
/// wider than that: ~890 CSS px in a README column, or the full window width
/// when opened on their own, which is ~2940 device pixels on a Retina laptop.
/// 4x covers both without upscaling.
enum Render {
    static let scale: CGFloat = 4

    /// A bitmap with 2x the pixels but the logical size, so drawing code keeps
    /// working in points and the context scales for us.
    static func bitmap(size: CGSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        return rep
    }

    /// Draws into a 2x bitmap using point coordinates, and writes it as a PNG.
    static func png(size: CGSize, to path: String, draw: () -> Void) -> Bool {
        guard let rep = bitmap(size: size),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        NSGraphicsContext.restoreGraphicsState()

        // Advertise the full pixel size, not the logical one: a rep that claims
        // to be 690pt wide invites a viewer to scale it up before display.
        rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            return false
        }
    }

    /// Snapshots a view at `scale`.
    ///
    /// Not `cacheDisplay`: that rasterises at the screen's backing scale, which
    /// caps the result at 2x however large a bitmap it is handed. Drawing the
    /// view into our own scaled context renders its text and vectors at the
    /// sheet's resolution instead.
    @MainActor
    static func image(of view: NSView) -> NSImage? {
        let window = NSWindow(contentRect: view.bounds,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        setContentsScale(view)

        guard let rep = bitmap(size: view.bounds.size),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Layer-backed views rasterise at their layer's contentsScale, so raising
    /// the context's scale alone is not enough.
    private static func setContentsScale(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.contentsScale = scale
        view.subviews.forEach(setContentsScale)
    }
}
