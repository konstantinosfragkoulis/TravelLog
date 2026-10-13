//
//  TravelLogApp.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import TipKit
import os.log

@main
struct TravelLogApp: App {
 
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
 
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(AppDelegate.initializeCloudKitSchemaArgument) {
            AppDelegate.initializeCloudKitSchemaAndExit()
        }
        #endif
        do {
            try Tips.configure([.displayFrequency(.daily)])
        } catch {
            Logger(subsystem: "com.travellog.app", category: "Tips")
                .error("TipKit configuration failed: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // SwiftUI otherwise inherits a region-combined Locale that
                // can lose an explicit pt-BR/pt-PT or zh script selection.
                .environment(\.locale, AppLanguagePreference.currentLocale())
        }
        .modelContainer(AppDelegate.modelContainer)
    }
}
