//
//  portal.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 16/03/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Portal: PortalWrapper {
    // eleven hours of the clock and then the level as it stands, so the
    // columns line up with hours a person can name rather than with however
    // long ago twelve hours happens to be
    public static let columns: Int = 12
    private static let hour: TimeInterval = 60*60
    
    // the stretches the cable was in for sit on a green ground behind the
    // columns, running from the moment it went in to the moment it came out
    private static let pluggedColor: NSColor = NSColor.systemGreen.withAlphaComponent(0.2)
    
    private let chart: ColumnChartView = ColumnChartView(num: Portal.columns, animation: false)
    private var chargeHistory: ChargeHistory? = nil
    
    private var levelField: NSTextField? = nil
    private var statusField: NSTextField? = nil
    private var healthField: NSTextField? = nil
    
    public override func load() {
        let chart = self.chartView()
        let details = self.detailsView()
        
        self.body.addArrangedSubview(chart)
        self.body.addArrangedSubview(details)
    }
    
    private func chartView() -> NSView {
        let view = NSStackView()
        view.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        self.chart.setTooltipDateFormat("HH:mm")
        // every column holds a reading, so there is no empty ground to show
        self.chart.setTrack(false)
        view.addArrangedSubview(self.chart)
        return view
    }
    
    private func detailsView() -> NSView {
        let view = NSStackView()
        
        view.orientation = .vertical
        view.distribution = .fillEqually
        view.spacing = Constants.Popup.spacing*2
        
        self.levelField = portalRow(view, title: "\(localizedString("Level")):").1
        self.statusField = portalRow(view, title: "\(localizedString("Status")):").1
        self.healthField = portalRow(view, title: "\(localizedString("Health")):").1
        
        return view
    }
    
    // an hour with no reading behind it keeps an empty column rather than a
    // bar of nothing, which reads as a flat battery
    public func setChargeHistory(_ history: ChargeHistory) {
        self.chargeHistory = history
        self.chargeCallback()
    }
    
    public func chargeCallback() {
        guard let history = self.chargeHistory else { return }
        
        let now = Date()
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        // the hours behind us, each one whole, and then the hour in progress
        var buckets: [(from: Date, to: Date)] = (1..<Portal.columns).reversed().map { back in
            let from = hour.addingTimeInterval(-Portal.hour * Double(back))
            return (from: from, to: from.addingTimeInterval(Portal.hour))
        }
        buckets.append((from: hour, to: now))
        
        let series = history.series(buckets: buckets)
        let values: [ColorValue?] = series.enumerated().map { (i, reading) in
            guard let reading else { return nil }
            var value = ColorValue(
                reading.value.level,
                color: reading.value.level.batteryColorV2(lowPowerMode: reading.value.lowPowerMode)
            )
            // a whole hour is named by the hour, the live one by the moment
            // the reading in it was taken
            value.ts = i == series.count-1 ? reading.ts : buckets[i].from
            return value
        }
        
        // the last column stands for however much of this hour has passed, and
        // is drawn as wide as the whole hours beside it, so the spans behind
        // the columns are placed against the columns rather than against time
        let axis = buckets[0].from
        let elapsed = max(1, now.timeIntervalSince(hour))
        let columns = Double(Portal.columns)
        func fraction(_ date: Date) -> Double {
            if date <= hour {
                return (date.timeIntervalSince(axis) / Portal.hour) / columns
            }
            return ((columns - 1) + date.timeIntervalSince(hour) / elapsed) / columns
        }
        
        let spans: [ChartSpan] = history.plugged(since: axis).map { period in
            ChartSpan(from: fraction(period.from), to: fraction(period.to), color: Portal.pluggedColor)
        }
        
        DispatchQueue.main.async(execute: {
            self.chart.setValues(values, spans: spans)
        })
    }
    
    public func loadCallback(_ value: Battery_Usage) {
        DispatchQueue.main.async(execute: {
            self.levelField?.stringValue = "\(Int(abs(value.level) * 100))%"
            self.levelField?.toolTip = "\(value.currentCapacity) mAh"
            
            var status: String = localizedString("Charging")
            var color: NSColor = .systemGreen
            if value.isBatteryPowered {
                status = localizedString("On battery")
                color = value.level > 0.15 ? .textColor : .systemRed
            } else if !value.isCharging {
                if value.isCharged && value.level >= 1 {
                    status = localizedString("Plugged in")
                } else if value.optimizedChargingEngaged {
                    status = localizedString("On hold")
                    color = .systemGray
                }
            }
            self.statusField?.stringValue = status
            self.statusField?.textColor = color
            
            self.healthField?.stringValue = "\(value.health)%"
        })
    }
}
