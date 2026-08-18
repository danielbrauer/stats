//
//  constants.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 15/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public struct Popup_c_s {
    public let width: CGFloat = 264
    public let height: CGFloat = 300
    public let margins: CGFloat = 8
    public let spacing: CGFloat = 2
    public let headerHeight: CGFloat = 42
    public let separatorHeight: CGFloat = 30
    public let radius: CGFloat = 6
    public let processHeight: CGFloat = 22
}

public struct Settings_c_s {
    public let width: CGFloat = 540
    public let height: CGFloat = 480
    public let margin: CGFloat = 10
    
    // the preview/settings choice belongs to the settings window, not to a
    // module, so switching modules keeps showing the same kind of view
    // which tab the module pages are showing, shared the same way. Stored by
    // name rather than index: not every module offers every tab
    public var moduleTab: String {
        get { Store.shared.string(key: "settings_moduleTab", defaultValue: "Module") }
        nonmutating set { Store.shared.set(key: "settings_moduleTab", value: newValue) }
    }
    public var showModuleSettings: Bool {
        get { Store.shared.bool(key: "settings_showModuleSettings", defaultValue: false) }
        nonmutating set { Store.shared.set(key: "settings_showModuleSettings", value: newValue) }
    }
}

public struct Widget_c_s {
    public let width: CGFloat = 32
    public var height: CGFloat {
        get {
            let systemHeight = NSApplication.shared.mainMenu?.menuBarHeight
            return (systemHeight == 0 ? 22 : systemHeight) ?? 22
        }
    }
    public var margin: CGPoint {
        get { CGPoint(x: 0, y: 2) }
    }
    public let spacing: CGFloat = 2
    
    // the chart width grows with the number of reads, so every read keeps the
    // same horizontal space instead of being squeezed as the history gets longer
    public let minHistoryCount: Int = 10
    public let maxHistoryCount: Int = 120
    public let historyReadWidth: CGFloat = 0.5
    public var devicePixel: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 1) }
    
    // n reads are drawn as n points joined by n-1 intervals, so the span they
    // need is n-1 reads wide. Reserving n would make every interval slightly
    // wider than a read, and only the first and last point would land on a
    // whole pixel: the leading edge blurs until the chart is full.
    public func chartWidth(_ historyCount: Int) -> CGFloat {
        CGFloat(min(self.maxHistoryCount, max(self.minHistoryCount, historyCount)) - 1) * self.historyReadWidth
    }
}

public struct Constants {
    public static let Popup: Popup_c_s = Popup_c_s()
    public static let Settings: Settings_c_s = Settings_c_s()
    public static let Widget: Widget_c_s = Widget_c_s()
    
    public static let defaultProcessIcon = NSWorkspace.shared.icon(forFile: "/bin/bash")
}

public enum ModuleType: Int {
    case CPU
    case RAM
    case GPU
    case disk
    case sensors
    case network
    case battery
    case bluetooth
    case clock
    case remote
    
    case combined
    
    public var stringValue: String {
        switch self {
        case .CPU: return "CPU"
        case .RAM: return "RAM"
        case .GPU: return "GPU"
        case .disk: return "Disk"
        case .sensors: return "Sensors"
        case .network: return "Network"
        case .battery: return "Battery"
        case .bluetooth: return "Bluetooth"
        case .clock: return "Clock"
        case .remote: return "Remote"
        case .combined: return ""
        }
    }
    
    public var activityMonitorTab: Int? {
        switch self {
        case .CPU: return 0
        case .RAM: return 1
        case .disk: return 3
        case .network: return 4
        case .battery: return 2
        default: return nil
        }
    }
}
