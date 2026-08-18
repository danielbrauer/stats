//
//  main.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 06/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import IOKit.ps

struct Battery_Usage: Codable {
    var powerSource: String = ""
    var state: String? = nil
    var isCharged: Bool = false
    var isCharging: Bool = false
    var isBatteryPowered: Bool = false
    var optimizedChargingEngaged: Bool = false
    var level: Double = 0
    var cycles: Int = 0
    var health: Int = 0
    
    var designedCapacity: Int = 0
    var maxCapacity: Int = 0
    var currentCapacity: Int = 0
    
    var current: Int = 0
    var voltage: Double = 0
    var temperature: Double = 0
    var batteryPower: Double = 0

    var ACwatts: Int = 0
    var chargingCurrent: Int = 0
    var chargingVoltage: Int = 0
    var adapterPower: Double = 0
    var adapterVoltage: Double = 0
    
    var timeToEmpty: Int = 0
    var timeToCharge: Int = 0
    var timeOnACPower: Date? = nil
}

internal struct Battery_Charge: Codable, Equatable {
    var level: Double = 0
    var isCharging: Bool = false
    // the cable being in is not the same as charging: a full battery, or one
    // held at 80% by optimised charging, is plugged in and not charging
    var isPlugged: Bool = false
    // the system keeps no log of this one, so it is only known for the
    // stretches Stats itself was watching
    var lowPowerMode: Bool = false
}

internal struct ChargePoint {
    let ts: Date
    let value: Battery_Charge
}

// the charge level over the last few hours, from two sources: what Stats has
// read itself, kept in its own store so it survives a restart, and the log
// macOS keeps of its own, which covers the hours before Stats was started. The
// reader only hears from the system when something changes, so a level that
// stays put is written down once a minute anyway, and a stretch neither source
// has anything for is left as a gap rather than a line nobody can vouch for
internal class ChargeHistory {
    // as far back as any of the charts is able to look
    public static let window: TimeInterval = 12*60*60
    // how often an unchanged level is written down again
    public static let interval: TimeInterval = 60
    private static let key: String = "Battery@charge"
    
    public var callback: (() -> Void)? = nil
    // the heartbeat repeats a level nobody is reading any more otherwise, and
    // a module that is off or paused is one the chart has nothing to say about
    public var isWatching: (() -> Bool)? = nil
    
    // how often the system's own log is read again, in heartbeats: a stretch
    // of sleep is one Stats has no readings for but powerd does
    private static let primeEvery: Int = 5
    // how long a reading stands for after it was taken. The system logs every
    // five or six minutes, so its readings have to carry further than the
    // minute Stats' own do
    private static let hold: TimeInterval = 10*60
    
    private let queue = DispatchQueue(label: "eu.exelban.Stats.Battery.chargeHistory")
    private var points: [ChargePoint] = []
    private var primed: [ChargePoint] = []
    private var last: Battery_Charge? = nil
    private var writes: Int = 0
    private var beats: Int = 0
    private var timer: DispatchSourceTimer? = nil
    
    public init() {
        DB.shared.setup(Battery_Charge.self, ChargeHistory.key, ttl: Int(ChargeHistory.window))
        let stored = DB.shared.find(
            Battery_Charge.self,
            key: ChargeHistory.key,
            since: Date().addingTimeInterval(-ChargeHistory.window)
        )
        self.queue.sync {
            self.points = stored.map { ChargePoint(ts: $0.ts, value: $0.value) }
        }
        DispatchQueue.global(qos: .utility).async {
            self.prime()
        }
        
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "eu.exelban.Stats.Battery.chargeHistory.timer")
        )
        timer.schedule(
            deadline: .now() + ChargeHistory.interval,
            repeating: .seconds(Int(ChargeHistory.interval)),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.isWatching?() ?? false else { return }
            
            let (last, prime) = self.queue.sync { () -> (Battery_Charge?, Bool) in
                self.beats += 1
                return (self.last, self.beats % ChargeHistory.primeEvery == 0)
            }
            if prime {
                self.prime()
            }
            guard let last else { return }
            self.store(last, heartbeat: true)
        }
        timer.resume()
        self.timer = timer
    }
    
    deinit {
        self.timer?.setEventHandler {}
        self.timer?.cancel()
    }
    
    public func record(_ usage: Battery_Usage) {
        self.store(Battery_Charge(
            level: abs(usage.level),
            isCharging: usage.isCharging,
            isPlugged: !usage.isBatteryPowered,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        ))
    }
    
    public var latest: Battery_Charge? {
        self.queue.sync { self.last }
    }
    
    public func readings(since: Date) -> [ChargePoint] {
        self.queue.sync { self.points.filter { $0.ts >= since } }
    }
    
    // the readings land whenever the level moves, so they are laid out on an
    // even grid of time here: each column takes the last reading inside it,
    // and is left empty when no reading landed there at all
    public func series(columns: Int, columnPeriod: TimeInterval) -> [ChargePoint?] {
        guard columns > 0 else { return [] }
        
        let start = Date().addingTimeInterval(-columnPeriod * Double(columns))
        return self.series(buckets: (0..<columns).map { i in
            (
                from: start.addingTimeInterval(columnPeriod * Double(i)),
                to: start.addingTimeInterval(columnPeriod * Double(i+1))
            )
        })
    }
    
    // buckets in the order they are to be drawn, which need be neither the
    // same length as each other nor a whole number of anything: a chart is
    // free to hold its columns to the clock and keep the last one live
    public func series(buckets: [(from: Date, to: Date)]) -> [ChargePoint?] {
        guard let start = buckets.first?.from else { return [] }
        
        // the system's log goes down first and Stats' own readings over it, so
        // a column Stats watched shows what Stats saw, and the rest of the
        // chart is the log's account of the hours before it was watching
        let readings = self.queue.sync { self.primed + self.points }
            .filter { $0.ts >= start }
            .sorted { $0.ts < $1.ts }
        
        var series: [ChargePoint?] = Array(repeating: nil, count: buckets.count)
        var i: Int = 0
        for reading in readings {
            while i < buckets.count, reading.ts >= buckets[i].to { i += 1 }
            guard i < buckets.count, reading.ts >= buckets[i].from else { continue }
            series[i] = reading
        }
        
        // a level holds until something moves it, and the sources write it
        // down more slowly than the chart draws columns, so a column with no
        // reading of its own carries the last one forward. Past the hold the
        // readings have run out altogether and the chart breaks instead
        var held: ChargePoint? = nil
        for i in 0..<buckets.count {
            if let reading = series[i] {
                held = reading
                continue
            }
            guard let held else { continue }
            let span = buckets[i].to.timeIntervalSince(buckets[i].from)
            guard buckets[i].from.timeIntervalSince(held.ts) <= max(ChargeHistory.hold, span*2) else { continue }
            series[i] = ChargePoint(
                ts: buckets[i].from.addingTimeInterval(span/2),
                value: held.value
            )
        }
        
        return series
    }
    
    // the stretches the cable was in for, from both sources, as they happened:
    // a chart draws them where they fell rather than rounding them out to
    // whichever columns they touch
    public func plugged(since: Date) -> [(from: Date, to: Date)] {
        let readings = self.queue.sync { self.primed + self.points }
            .filter { $0.ts >= since }
            .sorted { $0.ts < $1.ts }
        
        var spans: [(from: Date, to: Date)] = []
        var start: Date? = nil
        for reading in readings {
            if reading.value.isPlugged, start == nil {
                start = reading.ts
            } else if !reading.value.isPlugged, let from = start {
                spans.append((from: from, to: reading.ts))
                start = nil
            }
        }
        // still plugged in as of the last reading, so the span runs to now
        if let from = start {
            spans.append((from: from, to: Date()))
        }
        
        return spans
    }
    
    private func prime() {
        let readings = PowerlogReader.read(since: Date().addingTimeInterval(-ChargeHistory.window))
        guard !readings.isEmpty else { return }
        self.queue.sync { self.primed = readings }
        self.callback?()
    }
    
    // a change is written down as it arrives, and a level that holds is
    // written down again by the heartbeat. Readings that repeat in between are
    // dropped: the system sends them whenever anything about the power source
    // moves, which is far more often than a chart of hours needs
    private func store(_ value: Battery_Charge, heartbeat: Bool = false) {
        let now = Date()
        let stored: (write: Bool, prune: Bool) = self.queue.sync {
            let held = self.last == value
            self.last = value
            guard !held || heartbeat else { return (false, false) }
            
            self.points.append(ChargePoint(ts: now, value: value))
            
            let oldest = now.addingTimeInterval(-ChargeHistory.window)
            if let i = self.points.firstIndex(where: { $0.ts >= oldest }), i > 0 {
                self.points.removeFirst(i)
            }
            
            self.writes += 1
            return (true, self.writes % 60 == 0)
        }
        guard stored.write else { return }
        
        DB.shared.insert(key: ChargeHistory.key, value: value, ts: true)
        if stored.prune {
            DB.shared.prune(ChargeHistory.key)
        }
        self.callback?()
    }
}

public class Battery: Module {
    // the widget's width slider reads as a span of time: 20 minutes at its
    // narrowest, four hours at its widest
    fileprivate static let widgetColumnPeriod: TimeInterval = 2*60
    
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    
    private var chargeHistory: ChargeHistory? = nil
    
    public init() {
        self.settingsView = Settings(.battery)
        self.popupView = Popup(.battery)
        self.portalView = Portal(.battery, height: 70)
        self.notificationsView = Notifications(.battery)
        
        super.init(
            moduleType: .battery,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        let chargeHistory = ChargeHistory()
        chargeHistory.callback = { [weak self] in
            self?.chargeCallback()
        }
        chargeHistory.isWatching = { [weak self] in
            self?.enabled ?? false
        }
        self.portalView.setChargeHistory(chargeHistory)
        self.chargeHistory = chargeHistory
        self.popupView.setChargeHistory(chargeHistory)
        
        self.usageReader = UsageReader(.battery) { [weak self] value in
            self?.usageCallback(value)
        }
        self.processReader = ProcessReader(.battery) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
            }
        }
        
        self.settingsView.callback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.usageReader?.read()
            }
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async {
                self?.processReader?.read()
            }
        }
        
        self.setReaders([self.usageReader, self.processReader])
    }
    
    public override func willTerminate() {
        guard self.isAvailable() else { return }
        self.notificationsView.willTerminate()
    }
    
    public override func isAvailable() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        return !sources.isEmpty
    }
    
    // the widget draws hours rather than the last few reads, so it is handed
    // the whole series whenever the history takes a reading down, instead of
    // being fed a column per read like the other modules' charts
    private func chargeCallback() {
        self.popupView.chargeHistoryCallback()
        
        guard let history = self.chargeHistory, self.enabled else { return }
        
        self.portalView.chargeCallback()
        
        let widgets = self.menuBar.widgets.filter{ $0.isActive }.compactMap{ $0.item as? LineChart }
        guard !widgets.isEmpty else { return }
        
        let lowPowerMode = history.latest?.lowPowerMode ?? false
        widgets.forEach { (widget: LineChart) in
            widget.setColorFunc { $0.batteryColorV2(lowPowerMode: lowPowerMode) }
            let series = history.series(columns: widget.historyCount, columnPeriod: Battery.widgetColumnPeriod)
            widget.setPoints(series.map { reading in
                guard let reading else { return nil }
                var value = DoubleValue(reading.value.level)
                value.ts = reading.ts
                return value
            }, value: history.latest?.level)
        }
    }
    
    private func usageCallback(_ raw: Battery_Usage?) {
        guard let value = raw, self.enabled else { return }
        
        self.chargeHistory?.record(value)
        self.popupView.usageCallback(value)
        self.portalView.loadCallback(value)
        self.notificationsView.usageCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                widget.setValue(abs(value.level))
                widget.setColorZones((0.15, 0.3))
            case let widget as BarChart:
                widget.setValue([[ColorValue(value.level)]])
                widget.setColorZones((0.15, 0.3))
            case let widget as BatteryWidget:
                widget.setValue(
                    percentage: value.level,
                    ACStatus: !value.isBatteryPowered,
                    isCharging: value.isCharging,
                    optimizedCharging: value.optimizedChargingEngaged,
                    time: value.isBatteryPowered ? value.timeToEmpty : value.timeToCharge,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                )
            case let widget as BatteryDetailsWidget:
                widget.setValue(
                    percentage: value.level,
                    time: value.isBatteryPowered ? value.timeToEmpty : value.timeToCharge
                )
            default: break
            }
        }
    }
}
