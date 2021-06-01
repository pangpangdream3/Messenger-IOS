//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
open class OWSLayerView: UIView {
    @objc
    public var shouldAnimate = true

    @objc
    public var layoutCallback: (UIView) -> Void

    public typealias TapBlock = () -> Void
    private var tapBlock: TapBlock?

    @objc
    public init() {
        self.layoutCallback = { (_) in
        }
        super.init(frame: .zero)
    }

    @objc
    public init(frame: CGRect, layoutCallback : @escaping (UIView) -> Void) {
        self.layoutCallback = layoutCallback
        super.init(frame: frame)
    }

    public required init?(coder aDecoder: NSCoder) {
        self.layoutCallback = { _ in
        }
        super.init(coder: aDecoder)
    }

    @objc
    public static func circleView() -> OWSLayerView {
        circleView(size: nil)
    }

    public static func circleView(size: CGFloat? = nil) -> OWSLayerView {
        let result = OWSLayerView(frame: .zero) { view in
            view.layer.cornerRadius = min(view.width, view.height) * 0.5
        }
        if let size = size {
            result.autoSetDimensions(to: CGSize.square(size))
        }
        return result
    }

    @objc
    public static func pillView() -> OWSLayerView {
        pillView(height: nil)
    }

    public static func pillView(height: CGFloat? = nil) -> OWSLayerView {
        let result = OWSLayerView(frame: .zero) { view in
            view.layer.cornerRadius = min(view.width, view.height) * 0.5
        }
        if let height = height {
            result.autoSetDimension(.height, toSize: height)
        }
        return result
    }

    public override var bounds: CGRect {
        didSet {
            if oldValue != bounds {
                layoutSubviews()
            }
        }
    }

    public override var frame: CGRect {
        didSet {
            if oldValue != frame {
                layoutSubviews()
            }
        }
    }

    public override var center: CGPoint {
        didSet {
            if oldValue != center {
                layoutSubviews()
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        layoutCallback(self)
    }

    public func updateContent() {
        if shouldAnimate {
            layoutSubviews()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutSubviews()
            CATransaction.commit()
        }
    }

    public func addTapGesture(_ tapBlock: @escaping TapBlock) {
        self.tapBlock = tapBlock
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    @objc
    private func didTap() {
        guard let tapBlock = tapBlock else {
            owsFailDebug("Missing tapBlock.")
            return
        }
        tapBlock()
    }

    public func reset() {
        removeAllSubviews()

        self.layoutCallback = { _ in }

        self.tapBlock = nil
        if let gestureRecognizers = self.gestureRecognizers {
            for gestureRecognizer in gestureRecognizers {
                removeGestureRecognizer(gestureRecognizer)
            }
        }
    }
}
