//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public class CVComponentBodyText: CVComponentBase, CVComponent {

    struct State: Equatable {
        let bodyText: CVComponentState.BodyText
        let isTextExpanded: Bool
        let searchText: String?
        let hasTapForMore: Bool
        let shouldUseAttributedText: Bool
        let hasPendingMessageRequest: Bool
        fileprivate let dataItems: [DataItem]

        public var canUseDedicatedCell: Bool {
            if hasTapForMore || searchText != nil {
                return false
            }
            switch bodyText {
            case .bodyText:
                return true
            case .oversizeTextDownloading:
                return false
            case .remotelyDeleted:
                return false
            }
        }

        var textValue: CVTextValue? {
            bodyText.textValue(isTextExpanded: isTextExpanded)
        }
    }
    private let bodyTextState: State

    private var bodyText: CVComponentState.BodyText {
        bodyTextState.bodyText
    }
    private var textValue: CVTextValue? {
        bodyTextState.textValue
    }
    private var isTextExpanded: Bool {
        bodyTextState.isTextExpanded
    }
    private var searchText: String? {
        bodyTextState.searchText
    }
    private var hasTapForMore: Bool {
        bodyTextState.hasTapForMore
    }
    private var hasPendingMessageRequest: Bool {
        bodyTextState.hasPendingMessageRequest
    }
    public var shouldUseAttributedText: Bool {
        bodyTextState.shouldUseAttributedText
    }

    init(itemModel: CVItemModel, bodyTextState: State) {
        self.bodyTextState = bodyTextState

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewBodyText(componentDelegate: componentDelegate)
    }

    private var isJumbomoji: Bool {
        componentState.isJumbomojiMessage
    }

    private static func buildDataDetector(shouldAllowLinkification: Bool) -> NSDataDetector? {
        var checkingTypes = NSTextCheckingResult.CheckingType()
        if shouldAllowLinkification {
            checkingTypes.insert(.link)
        }
        checkingTypes.insert(.address)
        checkingTypes.insert(.phoneNumber)
        checkingTypes.insert(.date)

        do {
            return try NSDataDetector(types: checkingTypes.rawValue)
        } catch {
            owsFailDebug("Error: \(error)")
            return nil
        }
    }

    private static var dataDetectorWithLinks: NSDataDetector? = {
        buildDataDetector(shouldAllowLinkification: true)
    }()

    private static var dataDetectorWithoutLinks: NSDataDetector? = {
        buildDataDetector(shouldAllowLinkification: false)
    }()

    // DataDetectors are expensive to build, so we reuse them.
    private static func dataDetector(shouldAllowLinkification: Bool) -> NSDataDetector? {
        shouldAllowLinkification ? dataDetectorWithLinks : dataDetectorWithoutLinks
    }

    private static let unfairLock = UnfairLock()

    fileprivate struct DataItem: Equatable {
        enum DataType: UInt, Equatable, CustomStringConvertible {
            case link
            case address
            case phoneNumber
            case date
            case transitInformation

            // MARK: - CustomStringConvertible

            public var description: String {
                switch self {
                case .link:
                    return ".link"
                case .address:
                    return ".address"
                case .phoneNumber:
                    return ".phoneNumber"
                case .date:
                    return ".date"
                case .transitInformation:
                    return ".transitInformation"
                }
            }
        }

        let dataType: DataType
        let range: NSRange
        let snippet: String
        let url: URL
    }

    private static func detectDataItems(text: String,
                                        hasPendingMessageRequest: Bool,
                                        shouldAllowLinkification: Bool) -> [DataItem] {

        // Use a lock to ensure that measurement on and off the main thread
        // don't conflict.
        unfairLock.withLock {
            guard !hasPendingMessageRequest else {
                // Do not linkify if there is a pending message request.
                return []
            }
            // NSDataDetector and UIDataDetector behavior should be aligned.
            //
            // TODO: We might want to move this detection logic into
            // DisplayableText so that we can leverage caching.
            guard let detector = dataDetector(shouldAllowLinkification: shouldAllowLinkification) else {
                // If the data detectors can't be built, default to using attributed text.
                owsFailDebug("Could not build dataDetector.")
                return []
            }
            var dataItems = [DataItem]()
            for match in detector.matches(in: text, options: [], range: text.entireRange) {
                guard let snippet = (text as NSString).substring(with: match.range).strippedOrNil else {
                    owsFailDebug("Invalid snippet.")
                    continue
                }

                let matchUrl = match.url

                let dataType: DataItem.DataType
                var customUrl: URL?
                let resultType: NSTextCheckingResult.CheckingType = match.resultType
                if resultType.contains(.orthography) {
                    Logger.verbose("orthography")
                    continue
                } else if resultType.contains(.spelling) {
                    Logger.verbose("spelling")
                    continue
                } else if resultType.contains(.grammar) {
                    Logger.verbose("grammar")
                    continue
                } else if resultType.contains(.date) {
                    dataType = .date

                    guard matchUrl == nil else {
                        // Skip building customUrl; we already have a URL.
                        break
                    }

                    // NSTextCheckingResult.date is in GMT.
                    guard let gmtDate = match.date else {
                        owsFailDebug("Missing date.")
                        continue
                    }
                    // "calshow:" URLs expect GMT.
                    let timeInterval = gmtDate.timeIntervalSinceReferenceDate
                    guard let calendarUrl = URL(string: "calshow:\(timeInterval)") else {
                        owsFailDebug("Couldn't build calendarUrl.")
                        continue
                    }
                    customUrl = calendarUrl
                } else if resultType.contains(.address) {
                    Logger.verbose("address")

                    dataType = .address

                    guard matchUrl == nil else {
                        // Skip building customUrl; we already have a URL.
                        break
                    }

                    // https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/MapLinks/MapLinks.html
                    guard let urlEncodedAddress = snippet.encodeURIComponent else {
                        owsFailDebug("Could not URL encode address.")
                        continue
                    }
                    let urlString = "https://maps.apple.com/?q=" + urlEncodedAddress
                    guard let mapUrl = URL(string: urlString) else {
                        owsFailDebug("Couldn't build mapUrl.")
                        continue
                    }
                    customUrl = mapUrl
                } else if resultType.contains(.link) {
                    Logger.verbose("link")
                    dataType = .link
                } else if resultType.contains(.quote) {
                    Logger.verbose("quote")
                    continue
                } else if resultType.contains(.dash) {
                    Logger.verbose("dash")
                    continue
                } else if resultType.contains(.replacement) {
                    Logger.verbose("replacement")
                    continue
                } else if resultType.contains(.correction) {
                    Logger.verbose("correction")
                    continue
                } else if resultType.contains(.regularExpression) {
                    Logger.verbose("regularExpression")
                    continue
                } else if resultType.contains(.phoneNumber) {
                    Logger.verbose("phoneNumber")

                    dataType = .phoneNumber

                    guard matchUrl == nil else {
                        // Skip building customUrl; we already have a URL.
                        break
                    }

                    // https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html
                    let characterSet = CharacterSet(charactersIn: "+0123456789")
                    guard let phoneNumber = snippet.components(separatedBy: characterSet.inverted).joined().nilIfEmpty else {
                        owsFailDebug("Invalid phoneNumber.")
                        continue
                    }
                    let urlString = "tel:" + phoneNumber
                    guard let phoneNumberUrl = URL(string: urlString) else {
                        owsFailDebug("Couldn't build phoneNumberUrl.")
                        continue
                    }
                    customUrl = phoneNumberUrl
                } else if resultType.contains(.transitInformation) {
                    Logger.verbose("transitInformation")

                    dataType = .transitInformation

                    guard matchUrl == nil else {
                        // Skip building customUrl; we already have a URL.
                        break
                    }

                    guard let components = match.components,
                          let airline = components[.airline]?.nilIfEmpty,
                          let flight = components[.flight]?.nilIfEmpty else {
                        Logger.warn("Missing components.")
                        continue
                    }
                    let query = airline + " " + flight
                    guard let urlEncodedQuery = query.encodeURIComponent else {
                        owsFailDebug("Could not URL encode query.")
                        continue
                    }
                    let urlString = "https://www.google.com/?q=" + urlEncodedQuery
                    guard let transitUrl = URL(string: urlString) else {
                        owsFailDebug("Couldn't build transitUrl.")
                        continue
                    }
                    customUrl = transitUrl
                } else {
                    let snippet = (text as NSString).substring(with: match.range)
                    Logger.verbose("snippet: '\(snippet)'")
                    owsFailDebug("Unknown link type: \(resultType.rawValue)")
                    continue
                }

                guard let url = customUrl ?? matchUrl else {
                    owsFailDebug("Missing url: \(dataType).")
                    continue
                }

                dataItems.append(DataItem(dataType: dataType,
                                          range: match.range,
                                          snippet: snippet,
                                          url: url))
            }
            return dataItems
        }
    }

    static func buildState(interaction: TSInteraction,
                           bodyText: CVComponentState.BodyText,
                           viewStateSnapshot: CVViewStateSnapshot,
                           hasTapForMore: Bool,
                           hasPendingMessageRequest: Bool) -> State {
        let textExpansion = viewStateSnapshot.textExpansion
        let searchText = viewStateSnapshot.searchText
        let isTextExpanded = textExpansion.isTextExpanded(interactionId: interaction.uniqueId)

        let dataItems: [DataItem]
        var shouldUseAttributedText = false
        if let displayableText = bodyText.displayableText,
           let textValue = bodyText.textValue(isTextExpanded: isTextExpanded) {

            let shouldAllowLinkification = displayableText.shouldAllowLinkification

            switch textValue {
            case .text(let text):
                dataItems = detectDataItems(text: text,
                                            hasPendingMessageRequest: hasPendingMessageRequest,
                                            shouldAllowLinkification: shouldAllowLinkification)

                // UILabels are much cheaper than UITextViews, and we can
                // usually use them for rendering body text.
                //
                // We need to use attributed text in a UITextViews if:
                //
                // * We're displaying search results (and need to highlight matches).
                // * The text value is an attributed string (has mentions).
                // * The text value should be linkified.
                if searchText != nil {
                    shouldUseAttributedText = true
                } else {
                    shouldUseAttributedText = !dataItems.isEmpty
                }
            case .attributedText(let attributedText):
                dataItems = detectDataItems(text: attributedText.string,
                                            hasPendingMessageRequest: hasPendingMessageRequest,
                                            shouldAllowLinkification: shouldAllowLinkification)
                shouldUseAttributedText = true
            }
        } else {
            dataItems = []
        }

        return State(bodyText: bodyText,
                     isTextExpanded: isTextExpanded,
                     searchText: searchText,
                     hasTapForMore: hasTapForMore,
                     shouldUseAttributedText: shouldUseAttributedText,
                     hasPendingMessageRequest: hasPendingMessageRequest,
                     dataItems: dataItems)
    }

    static func buildComponentState(message: TSMessage,
                                    transaction: SDSAnyReadTransaction) throws -> CVComponentState.BodyText? {

        func build(displayableText: DisplayableText) -> CVComponentState.BodyText? {
            guard !displayableText.fullTextValue.stringValue.isEmpty else {
                return nil
            }
            return .bodyText(displayableText: displayableText)
        }

        // TODO: We might want to treat text that is completely stripped
        // as not present.
        if let oversizeTextAttachment = message.oversizeTextAttachment(with: transaction.unwrapGrdbRead) {
            if let oversizeTextAttachmentStream = oversizeTextAttachment as? TSAttachmentStream {
                let displayableText = CVComponentState.displayableBodyText(oversizeTextAttachment: oversizeTextAttachmentStream,
                                                                           ranges: message.bodyRanges,
                                                                           interaction: message,
                                                                           transaction: transaction)
                return build(displayableText: displayableText)
            } else if nil != oversizeTextAttachment as? TSAttachmentPointer {
                // TODO: Handle backup restore.
                // TODO: If there's media, should we display that while the oversize text is downloading?
                return .oversizeTextDownloading
            } else {
                throw OWSAssertionError("Invalid oversizeTextAttachment.")
            }
        } else if let body = message.body, !body.isEmpty {
            let displayableText = CVComponentState.displayableBodyText(text: body,
                                                                       ranges: message.bodyRanges,
                                                                       interaction: message,
                                                                       transaction: transaction)
            return build(displayableText: displayableText)
        } else {
            // No body text.
            return nil
        }
    }

    private var textMessageFont: UIFont {
        owsAssertDebug(DisplayableText.kMaxJumbomojiCount == 5)

        if isJumbomoji, let jumbomojiCount = bodyText.jumbomojiCount {
            let basePointSize = UIFont.ows_dynamicTypeBodyClamped.pointSize
            switch jumbomojiCount {
            case 0:
                break
            case 1:
                return UIFont.ows_regularFont(withSize: basePointSize * 3.5)
            case 2:
                return UIFont.ows_regularFont(withSize: basePointSize * 3.0)
            case 3:
                return UIFont.ows_regularFont(withSize: basePointSize * 2.75)
            case 4:
                return UIFont.ows_regularFont(withSize: basePointSize * 2.5)
            case 5:
                return UIFont.ows_regularFont(withSize: basePointSize * 2.25)
            default:
                owsFailDebug("Unexpected jumbomoji count: \(jumbomojiCount)")
                break
            }
        }

        return UIFont.ows_dynamicTypeBody
    }

    private var bodyTextColor: UIColor {
        guard let message = interaction as? TSMessage else {
            return .black
        }
        return conversationStyle.bubbleTextColor(message: message)
    }

    public func configureForRendering(componentView: CVComponentView,
                                      cellMeasurement: CVCellMeasurement,
                                      componentDelegate: CVComponentDelegate) {
        guard let componentView = componentView as? CVComponentViewBodyText else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        switch bodyText {
        case .bodyText(let displayableText):
            configureForBodyText(componentView: componentView,
                                 displayableText: displayableText,
                                 cellMeasurement: cellMeasurement)
        case .oversizeTextDownloading:
            owsAssertDebug(!componentView.isDedicatedCellView)

            configureForOversizeTextDownloading(componentView: componentView,
                                                cellMeasurement: cellMeasurement)
        case .remotelyDeleted:
            owsAssertDebug(!componentView.isDedicatedCellView)

            configureForRemotelyDeleted(componentView: componentView,
                                        cellMeasurement: cellMeasurement)
        }
    }

    private func configureForRemotelyDeleted(componentView: CVComponentViewBodyText,
                                             cellMeasurement: CVCellMeasurement) {
        _ = configureForLabel(componentView: componentView,
                              labelConfig: labelConfigForRemotelyDeleted,
                              cellMeasurement: cellMeasurement)
    }

    private func configureForOversizeTextDownloading(componentView: CVComponentViewBodyText,
                                                     cellMeasurement: CVCellMeasurement) {
        _ = configureForLabel(componentView: componentView,
                              labelConfig: labelConfigForOversizeTextDownloading,
                              cellMeasurement: cellMeasurement)
    }

    private func configureForLabel(componentView: CVComponentViewBodyText,
                                   labelConfig: CVLabelConfig,
                                   cellMeasurement: CVCellMeasurement) -> UILabel {
        let label = componentView.ensuredLabel
        labelConfig.applyForRendering(label: label)

        if label.superview == nil {
            let stackView = componentView.stackView
            stackView.reset()

            stackView.configure(config: stackViewConfig,
                                cellMeasurement: cellMeasurement,
                                measurementKey: Self.measurementKey_stackView,
                                subviews: [ label ])
        }

        return label
    }

    public func configureForBodyText(componentView: CVComponentViewBodyText,
                                     displayableText: DisplayableText,
                                     cellMeasurement: CVCellMeasurement) {

        switch textConfig(displayableText: displayableText) {
        case .labelConfig(let labelConfig):
            _ = configureForLabel(componentView: componentView,
                                  labelConfig: labelConfig,
                                  cellMeasurement: cellMeasurement)
        case .textViewConfig(let textViewConfig):
            let textView = componentView.ensuredTextView

            var shouldIgnoreEvents = false
            if let outgoingMessage = interaction as? TSOutgoingMessage {
                // Ignore taps on links in outgoing messages that haven't been sent yet, as
                // this interferes with "tap to retry".
                shouldIgnoreEvents = outgoingMessage.messageState != .sent
            }
            textView.shouldIgnoreEvents = shouldIgnoreEvents

            textViewConfig.applyForRendering(textView: textView)

            CVComponentBodyText.configureTextView(textView, displayableText: displayableText)

            if textView.superview == nil {
                let stackView = componentView.stackView
                stackView.reset()
                stackView.configure(config: stackViewConfig,
                                    cellMeasurement: cellMeasurement,
                                    measurementKey: Self.measurementKey_stackView,
                                    subviews: [ textView ])
            }
        }
    }

    private var stackViewConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .vertical,
                          alignment: .fill,
                          spacing: 0,
                          layoutMargins: .zero)
    }

    private var labelConfigForRemotelyDeleted: CVLabelConfig {
        let text = (isIncoming
                        ? NSLocalizedString("THIS_MESSAGE_WAS_DELETED", comment: "text indicating the message was remotely deleted")
                        : NSLocalizedString("YOU_DELETED_THIS_MESSAGE", comment: "text indicating the message was remotely deleted by you"))
        return CVLabelConfig(text: text,
                             font: textMessageFont.ows_italic,
                             textColor: bodyTextColor,
                             numberOfLines: 0,
                             lineBreakMode: .byWordWrapping,
                             textAlignment: .center)
    }

    private var labelConfigForOversizeTextDownloading: CVLabelConfig {
        let text = NSLocalizedString("MESSAGE_STATUS_DOWNLOADING",
                                     comment: "message status while message is downloading.")
        return CVLabelConfig(text: text,
                             font: textMessageFont.ows_italic,
                             textColor: bodyTextColor,
                             numberOfLines: 0,
                             lineBreakMode: .byWordWrapping,
                             textAlignment: .center)
    }

    private enum TextConfig {
        case labelConfig(labelConfig: CVLabelConfig)
        case textViewConfig(textViewConfig: CVTextViewConfig)
    }

    private func textConfig(displayableText: DisplayableText) -> TextConfig {

        let textValue = displayableText.textValue(isTextExpanded: isTextExpanded)

        switch textValue {
        case .text(let text):
            if shouldUseAttributedText {
                let attributedText = NSAttributedString(string: text)
                let textViewConfig = self.textViewConfig(displayableText: displayableText,
                                                         attributedText: attributedText)
                return .textViewConfig(textViewConfig: textViewConfig)
            } else {
                let labelConfig = CVLabelConfig(
                    text: text,
                    font: textMessageFont,
                    textColor: bodyTextColor,
                    numberOfLines: 0,
                    lineBreakMode: .byWordWrapping,
                    textAlignment: isTextExpanded
                        ? displayableText.fullTextNaturalAlignment
                        : displayableText.displayTextNaturalAlignment
                )
                return .labelConfig(labelConfig: labelConfig)
            }
        case .attributedText(let attributedText):
            let textViewConfig = self.textViewConfig(displayableText: displayableText,
                                                     attributedText: attributedText)
            return .textViewConfig(textViewConfig: textViewConfig)
        }
    }

    public static func configureTextView(_ textView: UITextView, displayableText: DisplayableText) {
        let dataDetectorTypes: UIDataDetectorTypes = {
            // If we're link-ifying with NSDataDetector, UITextView doesn't need to do data detection.
            guard !FeatureFlags.linkifyWithNSDataDetector,
                  displayableText.shouldAllowLinkification else {
                return []
            }
            return [.link, .address, .calendarEvent, .phoneNumber]
        }()
        if textView.dataDetectorTypes != dataDetectorTypes {
            // Setting dataDetectorTypes is expensive, so we only
            // update the property if the value has changed.
            textView.dataDetectorTypes = dataDetectorTypes
        }
    }

    private func linkifyData(attributedText: NSMutableAttributedString) {
        Self.linkifyData(attributedText: attributedText, dataItems: bodyTextState.dataItems)
    }

    public static func linkifyData(attributedText: NSMutableAttributedString,
                                   hasPendingMessageRequest: Bool,
                                   shouldAllowLinkification: Bool) {

        let dataItems = detectDataItems(text: attributedText.string,
                                        hasPendingMessageRequest: hasPendingMessageRequest,
                                        shouldAllowLinkification: shouldAllowLinkification)
        Self.linkifyData(attributedText: attributedText, dataItems: dataItems)
    }

    private static func linkifyData(attributedText: NSMutableAttributedString,
                                    dataItems: [DataItem]) {

        guard FeatureFlags.linkifyWithNSDataDetector else {
            return
        }

        // Sort so that we can detect overlap.
        let dataItems = dataItems.sorted { (left, right) in
            left.range.location < right.range.location
        }

        var mentionRanges = [NSRange]()
        attributedText.enumerateMentions { mention, subrange, _ in
            guard nil != mention else { return }
            mentionRanges.append(subrange)
        }
        func shouldSkipDataRange(_ dataRange: NSRange) -> Bool {
            for mentionRange in mentionRanges {
                if NSIntersectionRange(mentionRange, dataRange).length > 0 {
                    return true
                }
            }
            return false
        }

        var lastIndex: Int = 0
        for dataItem in dataItems {
            let range = dataItem.range

            guard range.location >= lastIndex else {
                owsFailDebug("Overlapping ranges.")
                continue
            }
            if shouldSkipDataRange(range) {
                Logger.warn("Not link-ifying range: \(range)")
                continue
            }
            guard let link = dataItem.url.absoluteString.nilIfEmpty else {
                owsFailDebug("Could not build data link.")
                continue
            }
            attributedText.addAttribute(.link, value: link, range: range)

            lastIndex = max(lastIndex, range.location + range.length)
        }
    }

    private func textViewConfig(displayableText: DisplayableText,
                                attributedText attributedTextParam: NSAttributedString) -> CVTextViewConfig {

        // Honor dynamic type in the message bodies.
        let linkTextAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key.foregroundColor: bodyTextColor,
            NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let textAlignment = (isTextExpanded
                                ? displayableText.fullTextNaturalAlignment
                                : displayableText.displayTextNaturalAlignment)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = textAlignment

        let attributedText = attributedTextParam.mutableCopy() as! NSMutableAttributedString
        attributedText.addAttributes(
            [
                .font: textMessageFont,
                .foregroundColor: bodyTextColor,
                .paragraphStyle: paragraphStyle
            ],
            range: attributedText.entireRange
        )
        linkifyData(attributedText: attributedText)

        if let searchText = searchText,
           searchText.count >= ConversationSearchController.kMinimumSearchTextLength {
            let searchableText = FullTextSearchFinder.normalize(text: searchText)
            let pattern = NSRegularExpression.escapedPattern(for: searchableText)
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                for match in regex.matches(in: attributedText.string,
                                           options: [.withoutAnchoringBounds],
                                           range: attributedText.string.entireRange) {
                    owsAssertDebug(match.range.length >= ConversationSearchController.kMinimumSearchTextLength)
                    attributedText.addAttribute(.backgroundColor, value: UIColor.yellow, range: match.range)
                    attributedText.addAttribute(.foregroundColor, value: UIColor.ows_black, range: match.range)
                }
            } catch {
                owsFailDebug("Error: \(error)")
            }
        }

        return CVTextViewConfig(attributedText: attributedText,
                                font: textMessageFont,
                                textColor: bodyTextColor,
                                linkTextAttributes: linkTextAttributes)
    }

    private static let measurementKey_stackView = "CVComponentBodyText.measurementKey_stackView"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let textSize: CGSize = {
            switch bodyText {
            case .bodyText(let displayableText):
                switch textConfig(displayableText: displayableText) {
                case .labelConfig(let labelConfig):
                    return CVText.measureLabel(config: labelConfig, maxWidth: maxWidth).ceil
                case .textViewConfig(let textViewConfig):
                    return CVText.measureTextView(config: textViewConfig, maxWidth: maxWidth).ceil
                }
            case .oversizeTextDownloading:
                return CVText.measureLabel(config: labelConfigForOversizeTextDownloading, maxWidth: maxWidth).ceil
            case .remotelyDeleted:
                return CVText.measureLabel(config: labelConfigForRemotelyDeleted, maxWidth: maxWidth).ceil
            }
        }()
        let textInfo = textSize.asManualSubviewInfo
        let stackMeasurement = ManualStackView.measure(config: stackViewConfig,
                                                       measurementBuilder: measurementBuilder,
                                                       measurementKey: Self.measurementKey_stackView,
                                                       subviewInfos: [ textInfo ],
                                                       maxWidth: maxWidth)
        return stackMeasurement.measuredSize
    }

    // MARK: - Events

    public override func handleTap(sender: UITapGestureRecognizer,
                                   componentDelegate: CVComponentDelegate,
                                   componentView: CVComponentView,
                                   renderItem: CVRenderItem) -> Bool {

        if let mention = tappedMention(sender: sender,
                                       componentView: componentView) {
            componentDelegate.cvc_didTapMention(mention)
            return true
        }

        if hasTapForMore {
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            componentDelegate.cvc_didTapTruncatedTextMessage(itemViewModel)
            return true
        }

        return false
    }

    private func tappedMention(sender: UITapGestureRecognizer,
                               componentView: CVComponentView) -> Mention? {
        guard let message = interaction as? TSMessage,
              let bodyRanges = message.bodyRanges,
              bodyRanges.hasMentions else {
            return nil
        }
        guard let componentView = componentView as? CVComponentViewBodyText else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        guard let textView = componentView.possibleTextView else {
            // Not using a text view.
            return nil
        }
        let location = sender.location(in: textView)
        guard textView.bounds.contains(location) else {
            return nil
        }

        let tappedCharacterIndex = textView.layoutManager.characterIndex(for: location,
                                                                         in: textView.textContainer,
                                                                         fractionOfDistanceBetweenInsertionPoints: nil)
        guard tappedCharacterIndex >= 0,
              tappedCharacterIndex < textView.attributedText.length else {
            return nil
        }
        guard let mention = textView.attributedText.attribute(Mention.attributeKey,
                                                              at: tappedCharacterIndex,
                                                              effectiveRange: nil) as? Mention else {
            owsFailDebug("Missing mention.")
            return nil
        }
        return mention
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    @objc
    public class CVComponentViewBodyText: NSObject, CVComponentView {

        public weak var componentDelegate: CVComponentDelegate?

        fileprivate let stackView = ManualStackView(name: "bodyText")

        private var _textView: OWSMessageTextView?
        fileprivate var possibleTextView: OWSMessageTextView? { _textView }
        fileprivate var ensuredTextView: OWSMessageTextView {
            if let textView = _textView {
                return textView
            }
            let textView = Self.buildTextView()
            textView.delegate = self
            _textView = textView
            return textView
        }

        private var _label: UILabel?
        fileprivate var possibleLabel: UILabel? { _label }
        fileprivate var ensuredLabel: UILabel {
            if let label = _label {
                return label
            }
            let label = CVLabel()
            _label = label
            return label
        }

        public var isDedicatedCellView = false

        public var rootView: UIView {
            stackView
        }

        required init(componentDelegate: CVComponentDelegate) {
            self.componentDelegate = componentDelegate

            super.init()
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        private static func buildTextView() -> OWSMessageTextView {
            let textView = CVText.buildTextView()

            return textView
        }

        public func reset() {
            if !isDedicatedCellView {
                stackView.reset()
            }

            _textView?.text = nil
            _label?.text = nil
        }

        // MARK: - UITextViewDelegate

    }
}

// MARK: -

extension CVComponentBodyText.CVComponentViewBodyText: UITextViewDelegate {

    public func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        shouldInteractWithUrl(url)
    }

    public func textView(_ textView: UITextView, shouldInteractWith url: URL, in characterRange: NSRange) -> Bool {
        shouldInteractWithUrl(url)
    }

    private func shouldInteractWithUrl(_ url: URL) -> Bool {
        guard let componentDelegate = componentDelegate else {
            owsFailDebug("Missing componentDelegate.")
            return true
        }
        guard tsAccountManager.isRegisteredAndReady else {
            return true
        }
        if StickerPackInfo.isStickerPackShare(url) {
            if let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) {
                componentDelegate.cvc_didTapStickerPack(stickerPackInfo)
                return false
            } else {
                owsFailDebug("Invalid URL: \(url)")
                return true
            }
        }
        if GroupManager.isPossibleGroupInviteLink(url) {
            componentDelegate.cvc_didTapGroupInviteLink(url: url)
            return false
        }
        return true
    }
}

// MARK: -

extension CVComponentBodyText: CVAccessibilityComponent {
    public var accessibilityDescription: String {
        switch bodyText {
        case .bodyText(let displayableText):
            // NOTE: we use the full text.
            return displayableText.fullTextValue.stringValue
        case .oversizeTextDownloading:
            return labelConfigForOversizeTextDownloading.stringValue
        case .remotelyDeleted:
            return labelConfigForRemotelyDeleted.stringValue
        }
    }
}
