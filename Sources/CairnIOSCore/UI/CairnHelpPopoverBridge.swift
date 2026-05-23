import SwiftUI
#if canImport(UIKit)
import UIKit

/// UIKit bridge that backs `HelpPopover`'s presentation. SwiftUI's
/// `.popover` modifier doesn't expose the underlying
/// `UIPopoverPresentationController`, so we can't set
/// `popoverBackgroundViewClass` from a pure-SwiftUI implementation —
/// which is what's required to stroke the entire popover chrome
/// (including the arrow). Going through UIKit gives us that hook at
/// the cost of a UIViewControllerRepresentable plus a custom
/// `UIPopoverBackgroundView` subclass.
///
/// Two pieces:
///   - `CairnPopoverBackgroundView` — draws the popover chrome (body +
///     arrow) as a single continuous Bezier path. Fills with the
///     active surface tone and strokes the perimeter with a
///     contrasting line so the popover reads as a defined card from
///     both light and dark schemes.
///   - `CairnHelpPopoverPresenter` — a `UIViewControllerRepresentable`
///     wired to a SwiftUI `isPresented` binding. Hosts the help
///     content in a `UIHostingController`, presents it with
///     `modalPresentationStyle = .popover`, and installs our custom
///     background class.

// MARK: - Background view (chrome with stroked outline)

/// Custom `UIPopoverBackgroundView` that draws the full popover
/// outline — body and arrow — as a single perimeter.
///
/// Colors are passed in via class-level mutable storage rather than
/// init params because `UIPopoverPresentationController` instantiates
/// the background class itself with no extension point for
/// per-instance configuration. The presenter sets these statics
/// just before presenting so the values stay coherent across a
/// presentation lifecycle.
final class CairnPopoverBackgroundView: UIPopoverBackgroundView {

    /// Fill color used inside the chrome path. Set by the presenter
    /// from the active `CairnTokens.surface` before the popover is
    /// presented.
    static var fillColor: UIColor = .systemBackground

    /// Stroke color used along the chrome perimeter. Set by the
    /// presenter from the active `CairnTokens.textMuted` so the
    /// outline contrasts the fill in both light and dark schemes.
    static var strokeColor: UIColor = .label

    /// Stroke width along the perimeter. 1pt matches the inline
    /// hairlines elsewhere in the cairn UI (Toggle borders, focused
    /// text inputs) without dominating the chrome.
    static let strokeWidth: CGFloat = 1.0

    /// Corner radius of the body rectangle. Roughly matches iOS's
    /// system popover chrome.
    static let cornerRadius: CGFloat = 12.0

    private var _arrowOffset: CGFloat = 0
    private var _arrowDirection: UIPopoverArrowDirection = .up

    override var arrowOffset: CGFloat {
        get { _arrowOffset }
        set {
            _arrowOffset = newValue
            setNeedsDisplay()
        }
    }

    override var arrowDirection: UIPopoverArrowDirection {
        get { _arrowDirection }
        set {
            _arrowDirection = newValue
            setNeedsDisplay()
        }
    }

    override class func arrowBase() -> CGFloat { 22 }
    override class func arrowHeight() -> CGFloat { 13 }

    /// Insets from the chrome edges to where the popover's content
    /// view is placed. The system pads content out of the arrow
    /// region automatically based on `arrowHeight()`, so we keep
    /// these insets minimal — just a small margin so SwiftUI text
    /// doesn't kiss the rounded-corner edge.
    override class func contentViewInsets() -> UIEdgeInsets {
        UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ rect: CGRect) {
        let path = chromePath()

        Self.fillColor.setFill()
        path.fill()

        Self.strokeColor.setStroke()
        path.lineWidth = Self.strokeWidth
        path.stroke()
    }

    /// Build a single continuous Bezier path for the popover chrome —
    /// rounded rectangle body with the arrow inserted on whichever
    /// edge `arrowDirection` indicates. A continuous perimeter means
    /// `path.stroke()` produces a clean unbroken outline, including
    /// the angled arrow edges, without a seam where the arrow joins
    /// the body.
    private func chromePath() -> UIBezierPath {
        let arrowH = Self.arrowHeight()
        let arrowB = Self.arrowBase()
        let radius = Self.cornerRadius
        // Inset the perimeter by half the stroke width so the stroked
        // line falls entirely inside `bounds` rather than being
        // clipped at the edges.
        let inset = Self.strokeWidth / 2

        // Compute the body rectangle — the rounded-rect portion,
        // shrunk on whichever side the arrow lives on so the arrow
        // protrudes outside the body into the chrome bounds.
        var body = bounds.insetBy(dx: inset, dy: inset)
        switch arrowDirection {
        case .up:    body = CGRect(x: body.minX, y: body.minY + arrowH, width: body.width, height: body.height - arrowH)
        case .down:  body = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height - arrowH)
        case .left:  body = CGRect(x: body.minX + arrowH, y: body.minY, width: body.width - arrowH, height: body.height)
        case .right: body = CGRect(x: body.minX, y: body.minY, width: body.width - arrowH, height: body.height)
        default: break
        }

        // Clamp corner radius so we never overshoot a very small body
        // rect (defensive — shouldn't happen at our preferred content
        // sizes, but protects against pathological 0-height bounds
        // before the system has laid out the popover).
        let r = min(radius, body.width / 2, body.height / 2)

        let path = UIBezierPath()

        // Walk the perimeter clockwise, splicing the arrow into
        // whichever edge it lives on. Reference points are the four
        // body corners; arcs handle the rounded corners; lines fill
        // the straight edges with the arrow triangle inserted into
        // the matching edge.
        let tl = CGPoint(x: body.minX, y: body.minY)
        let tr = CGPoint(x: body.maxX, y: body.minY)
        let br = CGPoint(x: body.maxX, y: body.maxY)
        let bl = CGPoint(x: body.minX, y: body.maxY)

        // Start just past the top-left corner (clockwise).
        path.move(to: CGPoint(x: tl.x + r, y: tl.y))

        // Top edge (with optional arrow up).
        if arrowDirection == .up {
            // `arrowOffset` is the signed horizontal offset of the
            // arrow's center from the popover's center, per UIKit's
            // convention. Convert to absolute X.
            let cx = bounds.midX + arrowOffset
            path.addLine(to: CGPoint(x: cx - arrowB / 2, y: tl.y))
            path.addLine(to: CGPoint(x: cx, y: bounds.minY + inset))
            path.addLine(to: CGPoint(x: cx + arrowB / 2, y: tl.y))
        }
        path.addLine(to: CGPoint(x: tr.x - r, y: tr.y))

        // Top-right corner.
        path.addArc(withCenter: CGPoint(x: tr.x - r, y: tr.y + r),
                    radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)

        // Right edge (with optional arrow right).
        if arrowDirection == .right {
            let cy = bounds.midY + arrowOffset
            path.addLine(to: CGPoint(x: tr.x, y: cy - arrowB / 2))
            path.addLine(to: CGPoint(x: bounds.maxX - inset, y: cy))
            path.addLine(to: CGPoint(x: tr.x, y: cy + arrowB / 2))
        }
        path.addLine(to: CGPoint(x: br.x, y: br.y - r))

        // Bottom-right corner.
        path.addArc(withCenter: CGPoint(x: br.x - r, y: br.y - r),
                    radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)

        // Bottom edge (with optional arrow down). Walking
        // right-to-left here so the arrow base ordering matches the
        // direction of travel.
        if arrowDirection == .down {
            let cx = bounds.midX + arrowOffset
            path.addLine(to: CGPoint(x: cx + arrowB / 2, y: br.y))
            path.addLine(to: CGPoint(x: cx, y: bounds.maxY - inset))
            path.addLine(to: CGPoint(x: cx - arrowB / 2, y: br.y))
        }
        path.addLine(to: CGPoint(x: bl.x + r, y: bl.y))

        // Bottom-left corner.
        path.addArc(withCenter: CGPoint(x: bl.x + r, y: bl.y - r),
                    radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)

        // Left edge (with optional arrow left). Walking bottom-to-top.
        if arrowDirection == .left {
            let cy = bounds.midY + arrowOffset
            path.addLine(to: CGPoint(x: bl.x, y: cy + arrowB / 2))
            path.addLine(to: CGPoint(x: bounds.minX + inset, y: cy))
            path.addLine(to: CGPoint(x: bl.x, y: cy - arrowB / 2))
        }
        path.addLine(to: CGPoint(x: tl.x, y: tl.y + r))

        // Top-left corner.
        path.addArc(withCenter: CGPoint(x: tl.x + r, y: tl.y + r),
                    radius: r, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)

        path.close()
        return path
    }
}

// MARK: - Representable presenter

/// SwiftUI bridge that presents a popover from a UIKit host so we can
/// install our custom background class. Used as a `.background` view
/// from `HelpPopover` so the visible (?) button stays SwiftUI; only
/// the popover presentation crosses into UIKit.
struct CairnHelpPopoverPresenter<HelpContent: View>: UIViewControllerRepresentable {

    @Binding var isPresented: Bool

    /// Color tokens captured at construction time. `presentationBackground`
    /// equivalents go straight into the static color slots on
    /// `CairnPopoverBackgroundView` before presentation.
    let fillColor: Color
    let strokeColor: Color

    /// Help content. The closure is invoked when the popover is
    /// presented; subsequent SwiftUI state changes inside the host
    /// re-render the hosted view in place.
    let content: () -> HelpContent

    func makeUIViewController(context: Context) -> CairnPopoverHostViewController {
        let host = CairnPopoverHostViewController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(_ uiViewController: CairnPopoverHostViewController, context: Context) {
        context.coordinator.isPresentedBinding = $isPresented
        if isPresented {
            CairnPopoverBackgroundView.fillColor = UIColor(fillColor)
            CairnPopoverBackgroundView.strokeColor = UIColor(strokeColor)
            uiViewController.present(
                content: AnyView(content()),
                strokeColor: UIColor(strokeColor)
            )
        } else {
            uiViewController.dismissPopover()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var isPresentedBinding: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresentedBinding = isPresented
        }

        /// Force popover style on iPhone so the help content adopts
        /// the popover chrome (with our custom background) rather
        /// than UIKit's default sheet adaptation for compact size
        /// classes.
        func adaptivePresentationStyle(
            for controller: UIPresentationController,
            traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            .none
        }

        /// Outside-tap dismissal arrives as a delegate callback,
        /// after the system has already dismissed the popover. Flip
        /// the binding so SwiftUI's state matches.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            DispatchQueue.main.async {
                self.isPresentedBinding.wrappedValue = false
            }
        }
    }
}

/// Transparent UIKit host that anchors the popover's source rect.
/// Held as the `UIViewControllerRepresentable`'s view controller so
/// the popover presentation has a real `UIViewController` to attach
/// to — SwiftUI doesn't expose `UIViewController` references at
/// arbitrary view sites, and presenting from an ad-hoc found
/// controller (rootViewController traversal) is brittle.
final class CairnPopoverHostViewController: UIViewController {

    weak var coordinator: (any UIPopoverPresentationControllerDelegate)?

    private var hosted: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false  // touches pass through to SwiftUI (?) button
    }

    func present(content: AnyView, strokeColor: UIColor) {
        // If the system flipped the popover (e.g., the (?) button is
        // near the screen edge and UIKit reflowed to a different arrow
        // direction) the same hosted controller can stay; just refresh
        // its content.
        if let existing = hosted, presentedViewController === existing {
            existing.rootView = content
            return
        }

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 300, height: 240)

        if let pop = host.popoverPresentationController {
            pop.sourceView = view.superview ?? view
            pop.sourceRect = (view.superview ?? view).bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.popoverBackgroundViewClass = CairnPopoverBackgroundView.self
            pop.delegate = coordinator
            pop.backgroundColor = CairnPopoverBackgroundView.fillColor
        }

        hosted = host
        present(host, animated: true)
    }

    func dismissPopover() {
        // Two paths reach here:
        //   1. User flipped the SwiftUI `isPresented` binding back
        //      to false (programmatic dismissal) — `presentedViewController`
        //      still matches the hosted controller; tell UIKit to
        //      dismiss it.
        //   2. User tapped outside — UIKit already dismissed and
        //      fired the delegate callback, which flipped the binding
        //      and round-tripped us here. `presentedViewController`
        //      is nil; nothing left to dismiss, but the strong
        //      `hosted` reference still needs to drop so we don't
        //      leak the UIHostingController across opens.
        if let hosted, presentedViewController === hosted {
            hosted.dismiss(animated: true)
        }
        self.hosted = nil
    }
}

#endif
