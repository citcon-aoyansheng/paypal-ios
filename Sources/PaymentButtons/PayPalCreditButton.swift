import UIKit
import SwiftUI

/// Configuration for PayPal Credit button
public final class PayPalCreditButton: PaymentButton {

    /**
    Available colors for PayPalCreditButton.
    */
    public enum Color: String {
        case gold
        case white

        var color: PaymentButtonColor {
            PaymentButtonColor(rawValue: rawValue) ?? .white
        }
    }

    /// Initialize a PayPalCreditButton
    /// - Parameters:
    ///   - insets: Edge insets of the button, defining the spacing of the button's edges relative to its content.
    ///   - color: Color of the button. Default to gold if not provided.
    ///   - edges: Edges of the button. Default to softEdges if not provided.
    ///   - size: Size of the button. Default to standard if not provided.
    public convenience init(
        insets: NSDirectionalEdgeInsets? = nil,
        color: Color = .gold,
        edges: PaymentButtonEdges = .rounded,
        size: PaymentButtonSize = .standard
    ) {
        self.init(
            fundingSource: PaymentButtonFundingSource.credit,
            color: color.color,
            edges: edges,
            size: size,
            insets: insets,
            label: nil
        )
    }

    deinit {}
}

/// PayPalCreditButton for SwiftUI
public struct PayPalCreditButtonView: UIViewRepresentable {

    private let button: PayPalCreditButton
    private var action: () -> Void = { }

    /// Initialize a PayPalCreditButton
    /// - Parameters:
    ///   - insets: Edge insets of the button, defining the spacing of the button's edges relative to its content.
    ///   - color: Color of the button. Default to gold if not provided.
    ///   - edges: Edges of the button. Default to softEdges if not provided.
    ///   - size: Size of the button. Default to standard if not provided.
    public init(
        insets: NSDirectionalEdgeInsets? = nil,
        color: PayPalCreditButton.Color = .gold,
        edges: PaymentButtonEdges = .rounded,
        size: PaymentButtonSize = .standard,
        _ action: @escaping () -> Void = { }
    ) {
        self.button = PayPalCreditButton(
            fundingSource: .credit,
            color: color.color,
            edges: edges,
            size: size,
            insets: insets,
            label: nil
        )
        self.action = action
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    public func makeUIView(context: Context) -> PaymentButton {
        let button = button
        button.addTarget(context.coordinator, action: #selector(Coordinator.onAction(_:)), for: .touchUpInside)
        return button
    }

    public func updateUIView(_ uiView: PaymentButton, context: Context) {
        context.coordinator.action = action
    }
}

// MARK: PayPalCreditButton Preview

struct PayPalCreditButtonUIView: View {

    var body: some View {
        PayPalCreditButtonView()
    }
}

struct PayPalCreditButtonView_Preview: PreviewProvider {

    static var previews: some View {
        PayPalCreditButtonView()
    }
}
