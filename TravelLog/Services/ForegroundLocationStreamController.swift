//
//  ForegroundLocationStreamController.swift
//  TravelLog
//

import CoreLocation
import Foundation
import os.log
import UIKit

nonisolated struct ForegroundLocationThinner {
    static let maximumHorizontalAccuracyMeters: Double = 100
    static let minimumDistanceMeters: Double = 250
    static let maximumIntervalSeconds: TimeInterval = 90

    private var lastKept: CLLocation?

    static func meetsSpacing(
        distanceMeters: CLLocationDistance,
        elapsedSeconds: TimeInterval
    ) -> Bool {
        guard elapsedSeconds >= 0 else { return false }
        return distanceMeters >= minimumDistanceMeters
            || elapsedSeconds >= maximumIntervalSeconds
    }

    mutating func shouldKeep(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maximumHorizontalAccuracyMeters else {
            return false
        }
        guard let previous = lastKept else {
            lastKept = location
            return true
        }

        let elapsed = location.timestamp.timeIntervalSince(previous.timestamp)
        guard Self.meetsSpacing(
            distanceMeters: location.distance(from: previous),
            elapsedSeconds: elapsed
        ) else { return false }

        lastKept = location
        return true
    }

    mutating func reset() {
        lastKept = nil
    }
}

@MainActor
final class ForegroundLocationStreamController {
    enum StartDecision: Equatable, Sendable {
        case noOp
        case requestFallback
        case startStream
    }

    static let shared = ForegroundLocationStreamController()

    nonisolated static let firstFixFallbackDelaySeconds: TimeInterval = 8
    nonisolated static let flushIntervalSeconds: TimeInterval = 30
    nonisolated static let flushCount = 8
    nonisolated static let pendingCapacity = 8
    nonisolated static let fallbackMinimumIntervalSeconds: TimeInterval = 60

    private let logger = Logger(
        subsystem: "com.travellog.app",
        category: "ForegroundLocationStream")

    private var activationIsOpen = false
    private var generation: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var flushTimerTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pressureObserverTokens: [NSObjectProtocol] = []

    private var thinner = ForegroundLocationThinner()
    private var pending: [LiveLocationCandidate] = []
    private var pendingSince: Date?
    private var receivedValidStreamFix = false
    private var fallbackRequestedThisActivation = false
    private var lastFallbackRequestAt: Date?
    private var flushToken: UInt64 = 0

    private init() {}

    nonisolated static func startDecision(
        applicationIsActive: Bool,
        hasPermission: Bool,
        accuracyAuthorization: CLAccuracyAuthorization,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> StartDecision {
        guard applicationIsActive, hasPermission else { return .noOp }
        guard accuracyAuthorization == .fullAccuracy,
              !lowPowerModeEnabled,
              thermalState != .serious,
              thermalState != .critical else {
            return .requestFallback
        }
        return .startStream
    }

    nonisolated static func shouldAcceptUpdate(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        applicationIsActive: Bool
    ) -> Bool {
        capturedGeneration == currentGeneration && applicationIsActive
    }

    nonisolated static func shouldFlush(
        pendingCount: Int,
        pendingSince: Date?,
        now: Date
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        if pendingCount >= flushCount { return true }
        guard let pendingSince else { return false }
        return now.timeIntervalSince(pendingSince) >= flushIntervalSeconds
    }

    @discardableResult
    nonisolated static func appendPending<Element>(
        _ element: Element,
        to pending: inout [Element]
    ) -> Bool {
        pending.append(element)
        guard pending.count > pendingCapacity else { return false }
        pending.removeFirst(pending.count - pendingCapacity)
        return true
    }

    nonisolated static func shouldRequestFallback(
        alreadyRequestedThisActivation: Bool,
        lastRequestedAt: Date?,
        now: Date
    ) -> Bool {
        guard !alreadyRequestedThisActivation else { return false }
        guard let lastRequestedAt else { return true }
        return now.timeIntervalSince(lastRequestedAt)
            >= fallbackMinimumIntervalSeconds
    }

    func applicationDidBecomeActive() {
        if activationIsOpen {
            stopCapture(
                capturedGeneration: generation,
                closeActivation: true,
                requestFallbackWhenEmpty: false)
        }

        activationIsOpen = true
        generation &+= 1
        thinner.reset()
        pending.removeAll(keepingCapacity: true)
        pendingSince = nil
        receivedValidStreamFix = false
        fallbackRequestedThisActivation = false

        let processInfo = ProcessInfo.processInfo
        switch Self.startDecision(
            applicationIsActive: true,
            hasPermission: LocationService.shared.hasAnyPermission,
            accuracyAuthorization: LocationService.shared.accuracyAuthorization,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        ) {
        case .noOp:
            break
        case .requestFallback:
            requestFallbackIfNeeded()
        case .startStream:
            startStream()
        }
    }

    func applicationWillResignActive() {
        guard activationIsOpen else { return }
        stopCapture(
            capturedGeneration: generation,
            closeActivation: true,
            requestFallbackWhenEmpty: false)
    }

    private func startStream() {
        guard streamTask == nil else { return }
        let capturedGeneration = generation

        installPressureObservers(capturedGeneration: capturedGeneration)
        scheduleFirstFixFallback(capturedGeneration: capturedGeneration)

        streamTask = Task { @MainActor [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    guard let self else { return }
                    guard Self.shouldAcceptUpdate(
                        capturedGeneration: capturedGeneration,
                        currentGeneration: self.generation,
                        applicationIsActive:
                            UIApplication.shared.applicationState == .active
                    ) else { return }
                    self.accept(update, capturedGeneration: capturedGeneration)
                }

                guard let self else { return }
                self.streamEnded(capturedGeneration: capturedGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.logger.error(
                    "Foreground location stream failed: \(error.localizedDescription)")
                self.streamEnded(capturedGeneration: capturedGeneration)
            }
        }
    }

    private func accept(
        _ update: CLLocationUpdate,
        capturedGeneration: UInt64
    ) {
        guard Self.shouldAcceptUpdate(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else { return }

        let terminalDiagnostic = update.authorizationDenied
            || update.authorizationDeniedGlobally
            || update.authorizationRestricted
            || update.serviceSessionRequired

        if terminalDiagnostic {
            stopCapture(
                capturedGeneration: capturedGeneration,
                closeActivation: false,
                requestFallbackWhenEmpty: false)
            return
        }

        guard let location = update.location else { return }
        guard LocationService.shared.isValidLiveLocation(location) else {
            return
        }
        guard location.horizontalAccuracy
                <= ForegroundLocationThinner.maximumHorizontalAccuracyMeters else {
            return
        }
        guard thinner.shouldKeep(location) else { return }

        receivedValidStreamFix = true
        fallbackTask?.cancel()
        fallbackTask = nil

        let candidate = LiveLocationCandidate(
            location, source: .foregroundStream)
        enqueue(candidate, now: .now)
    }

    private func streamEnded(capturedGeneration: UInt64) {
        guard Self.shouldAcceptUpdate(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else { return }
        stopCapture(
            capturedGeneration: capturedGeneration,
            closeActivation: false,
            requestFallbackWhenEmpty: true)
    }

    private func scheduleFirstFixFallback(capturedGeneration: UInt64) {
        fallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(Self.firstFixFallbackDelaySeconds))
            } catch {
                return
            }
            // A valid fix can cancel this task after the sleep already
            // returned; without this check the continuation would stop a
            // healthy stream for the rest of the activation.
            guard !Task.isCancelled, let self,
                  Self.shouldAcceptUpdate(
                    capturedGeneration: capturedGeneration,
                    currentGeneration: self.generation,
                    applicationIsActive:
                        UIApplication.shared.applicationState == .active
                  ) else { return }
            self.fallbackTask = nil
            self.stopCapture(
                capturedGeneration: capturedGeneration,
                closeActivation: false,
                requestFallbackWhenEmpty: true)
        }
    }

    private func requestFallbackIfNeeded() {
        guard activationIsOpen,
              LocationService.shared.hasAnyPermission else { return }

        let now = Date.now
        let shouldRequest = Self.shouldRequestFallback(
            alreadyRequestedThisActivation: fallbackRequestedThisActivation,
            lastRequestedAt: lastFallbackRequestAt,
            now: now)
        fallbackRequestedThisActivation = true
        guard shouldRequest else { return }

        lastFallbackRequestAt = now
        LocationService.shared.requestCurrentLocation()
    }

    private func enqueue(_ candidate: LiveLocationCandidate, now: Date) {
        Self.appendPending(candidate, to: &pending)
        if pendingSince == nil { pendingSince = now }

        if Self.shouldFlush(
            pendingCount: pending.count,
            pendingSince: pendingSince,
            now: now) {
            flushPendingIfDue(now: now)
        } else {
            ensureFlushTimer(now: now)
        }
    }

    private func ensureFlushTimer(now: Date) {
        guard flushTimerTask == nil,
              let pendingSince,
              !pending.isEmpty else { return }

        let remaining = max(
            0,
            Self.flushIntervalSeconds - now.timeIntervalSince(pendingSince))
        let capturedGeneration = generation
        flushTimerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            // Cancelled after the sleep returned: a newer timer may own the
            // handle, so leave it alone. Otherwise clear the handle even when
            // the flush is refused, or the 30-second timer never re-arms.
            guard !Task.isCancelled, let self else { return }
            self.flushTimerTask = nil
            guard Self.shouldAcceptUpdate(
                capturedGeneration: capturedGeneration,
                currentGeneration: self.generation,
                applicationIsActive:
                    UIApplication.shared.applicationState == .active
            ) else { return }
            self.flushPendingIfDue(now: .now)
        }
    }

    private func flushPendingIfDue(now: Date) {
        guard flushTask == nil,
              Self.shouldFlush(
                pendingCount: pending.count,
                pendingSince: pendingSince,
                now: now) else { return }

        let batch = detachPending()
        startDelivery(batch)
    }

    private func detachPending() -> [LiveLocationCandidate] {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingSince = nil
        flushTimerTask?.cancel()
        flushTimerTask = nil
        return batch
    }

    private func startDelivery(
        _ batch: [LiveLocationCandidate],
        after priorDelivery: Task<Void, Never>? = nil
    ) {
        guard !batch.isEmpty else { return }
        flushToken &+= 1
        let token = flushToken

        let task = Task { @MainActor [weak self] in
            if let priorDelivery { await priorDelivery.value }
            await LocationService.shared.deliverLocationCandidates(batch)
            self?.deliveryCompleted(token: token)
        }
        flushTask = task
    }

    private func deliveryCompleted(token: UInt64) {
        guard token == flushToken else { return }
        flushTask = nil
        guard activationIsOpen,
              UIApplication.shared.applicationState == .active,
              !pending.isEmpty else { return }

        let now = Date.now
        if Self.shouldFlush(
            pendingCount: pending.count,
            pendingSince: pendingSince,
            now: now) {
            flushPendingIfDue(now: now)
        } else {
            ensureFlushTimer(now: now)
        }
    }

    private func stopCapture(
        capturedGeneration: UInt64,
        closeActivation: Bool,
        requestFallbackWhenEmpty: Bool
    ) {
        guard capturedGeneration == generation,
              activationIsOpen else { return }

        generation &+= 1
        if closeActivation { activationIsOpen = false }
        let shouldFallback = requestFallbackWhenEmpty
            && !receivedValidStreamFix
        let finalBatch = detachPending()
        let priorDelivery = flushTask

        streamTask?.cancel()
        streamTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        removePressureObservers()
        thinner.reset()

        if !finalBatch.isEmpty {
            startDelivery(finalBatch, after: priorDelivery)
        }
        if shouldFallback { requestFallbackIfNeeded() }
    }

    private func installPressureObservers(capturedGeneration: UInt64) {
        removePressureObservers()

        let powerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.powerStateChanged(
                    capturedGeneration: capturedGeneration)
            }
        }
        let thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thermalStateChanged(
                    capturedGeneration: capturedGeneration)
            }
        }
        pressureObserverTokens = [powerToken, thermalToken]
    }

    private func powerStateChanged(capturedGeneration: UInt64) {
        guard Self.shouldAcceptUpdate(
            capturedGeneration: capturedGeneration,
            currentGeneration: generation,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else { return }
        stopCapture(
            capturedGeneration: capturedGeneration,
            closeActivation: false,
            requestFallbackWhenEmpty: true)
    }

    private func thermalStateChanged(capturedGeneration: UInt64) {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState == .serious || thermalState == .critical,
              Self.shouldAcceptUpdate(
                capturedGeneration: capturedGeneration,
                currentGeneration: generation,
                applicationIsActive:
                    UIApplication.shared.applicationState == .active
              ) else { return }
        stopCapture(
            capturedGeneration: capturedGeneration,
            closeActivation: false,
            requestFallbackWhenEmpty: true)
    }

    private func removePressureObservers() {
        for token in pressureObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        pressureObserverTokens.removeAll(keepingCapacity: true)
    }
}
