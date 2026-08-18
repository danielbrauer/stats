//
//  NetworkChart.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 19/01/2021.
//  Using Swift 5.0.
//  Running on macOS 11.1.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public class NetworkChart: WidgetWrapper {
    private var boxState: Bool = false
    private var frameState: Bool = false
    private var labelState: Bool = false
    private var historyCount: Int = 60
    private var downloadColor: SColor = .secondBlue
    private var uploadColor: SColor = .secondRed
    private var scaleState: Scale = .linear
    private var reverseOrderState: Bool = false
    private var fixedScaleState: Bool = false
    private var invertedState: Bool = false
    private var uploadLimit: Int = 10
    private var uploadLimitUnit: SizeUnit = .MB
    private var downloadLimit: Int = 10
    private var downloadLimitUnit: SizeUnit = .MB
    
    private var uploadLimitBytes: Double { Double(self.uploadLimitUnit.toBytes(self.uploadLimit)) }
    private var downloadLimitBytes: Double { Double(self.downloadLimitUnit.toBytes(self.downloadLimit)) }
    private var limitsSection: PreferencesSection? = nil
    
    private var points: [(Double, Double)] = Array(repeating: (0, 0), count: 60)
    
    private var width: CGFloat {
        get {
            let border = self.boxState || self.frameState ? Constants.Widget.devicePixel*2 : 0
            return Constants.Widget.chartWidth(self.historyCount) + border
        }
    }
    private var historySliderView: NSView? = nil
    
    private var colors: [SColor] = SColor.allCases
    
    private var boxSettingsView: NSSwitch? = nil
    private var frameSettingsView: NSSwitch? = nil
    
    public var NSLabelString: NSAttributedString = NSAttributedString()
    private var label: RasterizedText? = nil
    
    public init(title: String, config: NSDictionary?, preview: Bool = false) {
        var widgetTitle: String = title
        if let config = config {
            if let titleFromConfig = config["Title"] as? String {
                widgetTitle = titleFromConfig
            }
            if let unsupportedColors = config["Unsupported colors"] as? [String] {
                self.colors = self.colors.filter{ !unsupportedColors.contains($0.key) }
            }
        }
        
        super.init(.networkChart, title: widgetTitle, frame: CGRect(
            x: Constants.Widget.margin.x,
            y: Constants.Widget.margin.y,
            width: 30 + (2*Constants.Widget.margin.x),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        
        self.canDrawConcurrently = true
        
        if !preview {
            self.boxState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_box", defaultValue: self.boxState)
            self.frameState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_frame", defaultValue: self.frameState)
            self.labelState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_label", defaultValue: self.labelState)
            self.historyCount = min(Constants.Widget.maxHistoryCount, max(
                Constants.Widget.minHistoryCount,
                Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_historyCount", defaultValue: self.historyCount)
            ))
            self.downloadColor = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_downloadColor", defaultValue: self.downloadColor.key))
            self.uploadColor = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_uploadColor", defaultValue: self.uploadColor.key))
            self.scaleState = Scale.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_scale", defaultValue: self.scaleState.key))
            // `none` reads the raw byte count as a 0-1 fraction below 1 byte/s,
            // so an idle link spikes on noise. It is not offered here any more
            if self.scaleState == .none {
                self.scaleState = .linear
                Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_scale", value: self.scaleState.key)
            }
            self.reverseOrderState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_reverseOrder", defaultValue: self.reverseOrderState)
            self.fixedScaleState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_fixedScale", defaultValue: self.fixedScaleState)
            self.invertedState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_inverted", defaultValue: self.invertedState)
            self.uploadLimit = Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_uploadLimit", defaultValue: self.uploadLimit)
            self.uploadLimitUnit = SizeUnit.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_uploadLimitUnit", defaultValue: self.uploadLimitUnit.key), defaultValue: .MB)
            self.downloadLimit = Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_downloadLimit", defaultValue: self.downloadLimit)
            self.downloadLimitUnit = SizeUnit.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_downloadLimitUnit", defaultValue: self.downloadLimitUnit.key), defaultValue: .MB)
        }
        
        self.points = Array(repeating: (0, 0), count: self.historyCount)
        
        if preview {
            var list: [(Double, Double)] = []
            for _ in 0..<60 {
                list.append((Double.random(in: 0..<23), Double.random(in: 0..<23)))
            }
            self.points = list
        }
        
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let stringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 7, weight: .regular),
            NSAttributedString.Key.foregroundColor: NSColor.textColor,
            NSAttributedString.Key.paragraphStyle: style
        ]
        
        self.NSLabelString = NSAttributedString(
            string: String(self.title.prefix(3)).uppercased(),
            attributes: stringAttributes
        )
        self.label = rasterizedText(self.NSLabelString, appearance: self.effectiveAppearance)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.label = rasterizedText(self.NSLabelString, appearance: self.effectiveAppearance)
        self.needsDisplay = true
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        var points: [(Double, Double)] = []
        var labelState: Bool = false
        var boxState: Bool = false
        var frameState: Bool = false
        var scaleState: Scale = .linear
        var reverseOrderState: Bool = false
        var fixedScaleState: Bool = false
        var invertedState: Bool = false
        var uploadLimitBytes: Double = 0
        var downloadLimitBytes: Double = 0
        var originWidth: CGFloat = 0
        var label: RasterizedText? = nil
        var downloadColor: SColor = .secondBlue
        var uploadColor: SColor = .secondRed
        self.queue.sync {
            points = self.points
            labelState = self.labelState
            boxState = self.boxState
            frameState = self.frameState
            scaleState = self.scaleState
            fixedScaleState = self.fixedScaleState
            invertedState = self.invertedState
            uploadLimitBytes = self.uploadLimitBytes
            downloadLimitBytes = self.downloadLimitBytes
            reverseOrderState = self.reverseOrderState
            label = self.label
            originWidth = self.width
            downloadColor = self.downloadColor
            uploadColor = self.uploadColor
        }
        
        let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let offset = lineWidth / 2
        let boxSize: CGSize = CGSize(width: originWidth - (Constants.Widget.margin.x*2), height: self.frame.size.height)
        var x: CGFloat = 0
        var width = originWidth + (Constants.Widget.margin.x*2)
        
        if labelState, let label = label {
            // a pre-rasterised string turned a quarter turn left: it reads bottom
            // to top and keeps the grid fitting that rotated text throws away.
            // Its first letter starts on the chart's own baseline, not on the
            // widget's: the baseline is the one edge that is always there. The
            // space the font leaves before that letter is taken off the offset,
            // so it is the ink that lands on the baseline, not the string box
            let inset: CGFloat = boxState || frameState ? lineWidth : 0
            let letterWidth: CGFloat = label.image.size.height
            
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .none
            let transform = NSAffineTransform()
            transform.translateX(by: x + letterWidth, yBy: inset - label.bearing)
            transform.rotate(byDegrees: 90)
            transform.concat()
            label.image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            
            width += letterWidth + Constants.Widget.spacing
            x = letterWidth + Constants.Widget.spacing
        }
        
        let box = NSBezierPath(roundedRect: NSRect(
            x: x + offset,
            y: offset,
            width: originWidth - offset*2,
            height: boxSize.height - (offset*2)
        ), xRadius: 2, yRadius: 2)
        
        if boxState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.stroke()
            box.fill()
        }
        
        context.saveGState()
        
        // whole device pixels: `offset` is half a pixel and only ever centres
        // the box stroke, so it must not appear in a fill or a point position
        let inset: CGFloat = boxState || frameState ? lineWidth : 0
        let chartFrame = NSRect(
            x: x + inset,
            y: inset,
            width: originWidth - (inset*2),
            height: boxSize.height - (inset*2)
        )
        // a fixed ceiling makes the chart readable at a glance: without it the
        // scale is whatever the tallest sample in the window happens to be, so
        // the same height means a different speed from one moment to the next
        var topMax: Double
        var bottomMax: Double
        if fixedScaleState {
            topMax = reverseOrderState ? downloadLimitBytes : uploadLimitBytes
            bottomMax = reverseOrderState ? uploadLimitBytes : downloadLimitBytes
        } else {
            topMax = (reverseOrderState ? points.map{ $0.1 }.max() : points.map{ $0.0 }.max()) ?? 0
            bottomMax = (reverseOrderState ? points.map{ $0.0 }.max() : points.map{ $0.1 }.max()) ?? 0
        }
        if topMax <= 0 {
            topMax = 1
        }
        if bottomMax <= 0 {
            bottomMax = 1
        }
        
        // n points are joined by n-1 intervals, so they span the chart exactly
        // and every one of them lands on a whole device pixel
        let xRatio: CGFloat = points.count > 1 ? chartFrame.width / CGFloat(points.count - 1) : 0
        
        // a 1px stroke is crisp when its centre sits half a pixel off the grid,
        // so every line the chart can draw is placed half a stroke inside its
        // edge. The centre line takes the middle row rather than the boundary
        // between the two middle rows, which would split it over both.
        let half: CGFloat = lineWidth/2
        let rows: CGFloat = (chartFrame.height/lineWidth).rounded(.down)
        
        // the middle is the boundary between two rows and each half takes the
        // row on its own side of it. Sharing one row put both lines on the same
        // pixel whenever the traffic was small, and the one drawn second hid
        // the other. Splitting them also makes the two reaches equal.
        let middle: CGFloat = chartFrame.minY + ((rows/2).rounded(.down) * lineWidth)
        let innerTop: CGFloat = middle + half
        let innerBottom: CGFloat = middle - half
        let outerTop: CGFloat = chartFrame.maxY - half
        let outerBottom: CGFloat = chartFrame.minY + half
        
        // normally both halves grow away from the middle; inverted, they hang
        // from the outer edges and the ceiling is the middle instead
        let topBase: CGFloat = invertedState ? outerTop : innerTop
        let bottomBase: CGFloat = invertedState ? outerBottom : innerBottom
        let halfHeight: CGFloat = min(outerTop - innerTop, innerBottom - outerBottom)
        
        // a base is the centre of a 1px stroke, so it sits half a pixel inside
        // the row the line occupies. The area under the line is closed on the
        // far edge of that row instead, or it would stop in the middle of it
        // and leave the chart with a soft edge where the line has a sharp one
        let topFillBase: CGFloat = invertedState ? chartFrame.maxY : middle
        let bottomFillBase: CGFloat = invertedState ? chartFrame.minY : middle
        
        let columnXPoint = { (point: Int) -> CGFloat in
            return chartFrame.minX + (CGFloat(point) * xRatio)
        }
        
        let topYPoint = { (point: Int) -> CGFloat in
            let value = min(reverseOrderState ? points[point].1 : points[point].0, topMax)
            let height = scaleValue(scale: scaleState, value: value, maxValue: topMax, zeroValue: 256.0, maxHeight: halfHeight, limit: 1)
            return invertedState ? topBase - height : topBase + height
        }
        let bottomYPoint = { (point: Int) -> CGFloat in
            let value = min(reverseOrderState ? points[point].0 : points[point].1, bottomMax)
            let height = scaleValue(scale: scaleState, value: value, maxValue: bottomMax, zeroValue: 256.0, maxHeight: halfHeight, limit: 1)
            return invertedState ? bottomBase + height : bottomBase - height
        }
        
        let topLinePath = NSBezierPath()
        topLinePath.move(to: CGPoint(x: columnXPoint(0), y: topYPoint(0)))
        let bottomLinePath = NSBezierPath()
        bottomLinePath.move(to: CGPoint(x: columnXPoint(0), y: bottomYPoint(0)))
        
        for i in 1..<points.count {
            topLinePath.line(to: CGPoint(x: columnXPoint(i), y: topYPoint(i)))
            bottomLinePath.line(to: CGPoint(x: columnXPoint(i), y: bottomYPoint(i)))
        }
        
        let topColor = (reverseOrderState ? self.uploadColor : downloadColor).additional as? NSColor
        let bottomColor = (reverseOrderState ? self.downloadColor : uploadColor).additional as? NSColor
        
        bottomColor?.setStroke()
        topLinePath.lineWidth = lineWidth
        topLinePath.stroke()
        
        topColor?.setStroke()
        bottomLinePath.lineWidth = lineWidth
        bottomLinePath.stroke()
        
        context.restoreGState()
        context.saveGState()
        
        guard let topUnderLinePath = topLinePath.copy() as? NSBezierPath else { return }
        topUnderLinePath.line(to: CGPoint(x: columnXPoint(points.count - 1), y: topFillBase))
        topUnderLinePath.line(to: CGPoint(x: columnXPoint(0), y: topFillBase))
        topUnderLinePath.close()
        topUnderLinePath.addClip()
        bottomColor?.withAlphaComponent(0.5).setFill()
        let topFillRect = chartFrame
        NSBezierPath(rect: topFillRect).fill()
        
        context.restoreGState()
        context.saveGState()
        
        guard let bottomUnderLinePath = bottomLinePath.copy() as? NSBezierPath else { return }
        bottomUnderLinePath.line(to: CGPoint(x: columnXPoint(points.count - 1), y: bottomFillBase))
        bottomUnderLinePath.line(to: CGPoint(x: columnXPoint(0), y: bottomFillBase))
        bottomUnderLinePath.close()
        bottomUnderLinePath.addClip()
        topColor?.withAlphaComponent(0.5).setFill()
        let bottomFillRect = chartFrame
        NSBezierPath(rect: bottomFillRect).fill()
        
        context.restoreGState()
        
        if boxState || frameState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.lineWidth = lineWidth
            box.stroke()
        }
        
        self.setWidth(width)
    }
    
    public func setValue(upload: Double, download: Double) {
        self.queue.sync {
            self.points.remove(at: 0)
            self.points.append((upload, download))
        }
        DispatchQueue.main.async(execute: {
            if self.window?.isVisible ?? false {
                self.needsDisplay = true
            }
        })
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView {
        let view = SettingsContainerView()
        
        let box = switchView(
            action: #selector(self.toggleBox),
            state: self.boxState
        )
        self.boxSettingsView = box
        let frame = switchView(
            action: #selector(self.toggleFrame),
            state: self.frameState
        )
        self.frameSettingsView = frame
        
        let historySlider = sliderView(
            action: #selector(self.toggleHistoryCount),
            value: self.historyCount,
            initialValue: "\(self.historyCount)",
            min: Double(Constants.Widget.minHistoryCount),
            max: Double(Constants.Widget.maxHistoryCount)
        )
        self.historySliderView = historySlider
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Label"), component: switchView(
                action: #selector(self.toggleLabel),
                state: self.labelState
            )),
            PreferencesRow(localizedString("Box"), component: box),
            PreferencesRow(localizedString("Frame"), component: frame),
            PreferencesRow(localizedString("Reverse order"), component: switchView(
                action: #selector(self.toggleReverseOrder),
                state: self.reverseOrderState
            )),
            PreferencesRow(localizedString("Color of download"), component: colorSelectView(
                action: #selector(self.toggleDownloadColor),
                items: self.colors,
                selected: self.downloadColor.key
            )),
            PreferencesRow(localizedString("Color of upload"), component: colorSelectView(
                action: #selector(self.toggleUploadColor),
                items: self.colors,
                selected: self.uploadColor.key
            )),
            PreferencesRow(localizedString("Width"), component: historySlider),
            PreferencesRow(localizedString("Scaling"), component: selectView(
                action: #selector(self.toggleScale),
                items: [Scale.linear, Scale.square, Scale.cube, Scale.logarithmic],
                selected: self.scaleState.key
            )),
            PreferencesRow(localizedString("Peak at center"), component: switchView(
                action: #selector(self.toggleInverted),
                state: self.invertedState
            )),
            PreferencesRow(localizedString("Fixed scale"), component: switchView(
                action: #selector(self.toggleFixedScale),
                state: self.fixedScaleState
            ))
        ]))
        
        let limits = PreferencesSection([
            PreferencesRow(localizedString("Upload limit"), component: StepperInput(
                self.uploadLimit,
                range: NSRange(location: 1, length: 999),
                unit: self.uploadLimitUnit.key,
                units: SizeUnit.allCases,
                callback: self.changeUploadLimit,
                unitCallback: self.toggleUploadLimitUnit
            )),
            PreferencesRow(localizedString("Download limit"), component: StepperInput(
                self.downloadLimit,
                range: NSRange(location: 1, length: 999),
                unit: self.downloadLimitUnit.key,
                units: SizeUnit.allCases,
                callback: self.changeDownloadLimit,
                unitCallback: self.toggleDownloadLimitUnit
            ))
        ])
        limits.isHidden = !self.fixedScaleState
        self.limitsSection = limits
        view.addArrangedSubview(limits)
        
        return view
    }
    
    @objc private func toggleInverted(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync { self.invertedState = state }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_inverted", value: state)
        self.needsDisplay = true
    }
    
    @objc private func toggleFixedScale(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync { self.fixedScaleState = state }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_fixedScale", value: state)
        self.limitsSection?.isHidden = !state
        self.needsDisplay = true
    }
    
    private func changeUploadLimit(_ newValue: Int) {
        self.queue.sync { self.uploadLimit = newValue }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_uploadLimit", value: newValue)
        self.needsDisplay = true
    }
    
    private func toggleUploadLimitUnit(_ newValue: KeyValue_p) {
        guard let unit = newValue as? SizeUnit else { return }
        self.queue.sync { self.uploadLimitUnit = unit }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_uploadLimitUnit", value: unit.key)
        self.needsDisplay = true
    }
    
    private func changeDownloadLimit(_ newValue: Int) {
        self.queue.sync { self.downloadLimit = newValue }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_downloadLimit", value: newValue)
        self.needsDisplay = true
    }
    
    private func toggleDownloadLimitUnit(_ newValue: KeyValue_p) {
        guard let unit = newValue as? SizeUnit else { return }
        self.queue.sync { self.downloadLimitUnit = unit }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_downloadLimitUnit", value: unit.key)
        self.needsDisplay = true
    }
    
    @objc private func toggleLabel(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync {
            self.labelState = state
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_label", value: self.labelState)
        self.needsDisplay = true
    }
    
    @objc private func toggleBox(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync {
            self.boxState = state
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_box", value: self.boxState)
        
        if self.frameState {
            self.frameSettingsView?.state = .off
            self.queue.sync {
                self.frameState = false
            }
            Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_frame", value: self.frameState)
        }
        
        self.needsDisplay = true
    }
    
    @objc private func toggleFrame(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync {
            self.frameState = state
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_frame", value: self.frameState)
        
        if self.boxState {
            self.boxSettingsView?.state = .off
            self.queue.sync {
                self.boxState = false
            }
            Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_box", value: self.boxState)
        }
        
        self.needsDisplay = true
    }
    
    @objc private func toggleHistoryCount(_ sender: NSSlider) {
        let num = Int(sender.doubleValue)
        guard num != self.historyCount else { return }
        
        if let field = self.historySliderView?.subviews.first(where: { $0 is NSTextField }) as? NSTextField {
            field.stringValue = "\(num)"
        }
        
        self.queue.sync {
            self.historyCount = num

            if num < self.points.count {
                self.points = Array(self.points.suffix(num))
            } else if num > self.points.count {
                self.points = Array(repeating: (0, 0), count: num - self.points.count) + self.points
            }
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_historyCount", value: self.historyCount)
        
        self.needsDisplay = true
    }
    
    @objc private func toggleDownloadColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.queue.sync {
            self.downloadColor = SColor.fromString(key, defaultValue: self.downloadColor)
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_downloadColor", value: self.downloadColor.key)
        self.needsDisplay = true
    }
    
    @objc private func toggleUploadColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.queue.sync {
            self.uploadColor = SColor.fromString(key, defaultValue: self.uploadColor)
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_uploadColor", value: self.uploadColor.key)
        self.needsDisplay = true
    }
    
    @objc private func toggleScale(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let value = Scale.allCases.first(where: { $0.key == key }) else { return }
        self.queue.sync {
            self.scaleState = value
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_scale", value: key)
        self.needsDisplay = true
    }
    
    @objc private func toggleReverseOrder(_ sender: NSControl) {
        let state = controlState(sender)
        self.queue.sync {
            self.reverseOrderState = state
        }
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_reverseOrder", value: self.reverseOrderState)
        self.needsDisplay = true
    }
}
