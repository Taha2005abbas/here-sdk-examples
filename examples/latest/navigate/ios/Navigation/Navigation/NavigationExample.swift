/*
 * Copyright (C) 2019-2021 HERE Europe B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 * License-Filename: LICENSE
 */

import AVFoundation
import heresdk
import UIKit

// Shows how to start and stop turn-by-turn navigation on a car route.
// By default, tracking mode is enabled. When navigation is stopped, tracking mode is enabled again.
// The preferred device language determines the language for voice notifications used for TTS.
// (Make sure to set language + region in device settings.)
class NavigationExample : NavigableLocationDelegate,
                          DestinationReachedDelegate,
                          MilestoneReachedDelegate,
                          SpeedWarningDelegate,
                          SpeedLimitDelegate,
                          RouteProgressDelegate,
                          RouteDeviationDelegate,
                          ManeuverNotificationDelegate,
                          LaneAssistanceDelegate,
                          RoadAttributesDelegate {

    private let viewController: UIViewController
    private let mapView: MapView
    private let visualNavigator: VisualNavigator
    private let herePositioningProvider: HEREPositioningProvider
    private let herePositioningSimulator: HEREPositioningSimulator
    private let voiceAssistant: VoiceAssistant
    private let routeCalculator: RouteCalculator
    private var previousManeuverIndex: Int32 = -1

    init(viewController: UIViewController, mapView: MapView) {
        self.viewController = viewController
        self.mapView = mapView

        // Needed for rerouting, when user leaves route.
        routeCalculator = RouteCalculator()

        do {
            // Without a route set, this starts tracking mode.
            try visualNavigator = VisualNavigator()
        } catch let engineInstantiationError {
            fatalError("Failed to initialize VisualNavigator. Cause: \(engineInstantiationError)")
        }

        visualNavigator.startRendering(mapView: mapView)

        // A class to receive real location events.
        herePositioningProvider = HEREPositioningProvider()
        // A class to receive simulated location events.
        herePositioningSimulator = HEREPositioningSimulator()

        // A helper class for TTS.
        voiceAssistant = VoiceAssistant()

        visualNavigator.navigableLocationDelegate = self
        visualNavigator.routeDeviationDelegate = self
        visualNavigator.routeProgressDelegate = self
        visualNavigator.maneuverNotificationDelegate = self
        visualNavigator.destinationReachedDelegate = self
        visualNavigator.milestoneReachedDelegate = self
        visualNavigator.speedWarningDelegate = self
        visualNavigator.speedLimitDelegate = self
        visualNavigator.laneAssistanceDelegate = self
        visualNavigator.roadAttributesDelegate = self
    }

    func startLocationProvider() {
        // Set navigator as delegate to receive locations from HERE Positioning.
        herePositioningProvider.startLocating(locationDelegate: visualNavigator,
                                              // Choose the best accuracy for the tbt navigation use case.
                                              accuracy: .navigation)
    }

    // Conform to RouteProgressDelegate.
    // Notifies on the progress along the route including maneuver instructions.
    func onRouteProgressUpdated(_ routeProgress: RouteProgress) {
        // [SectionProgress] is guaranteed to be non-empty.
        let distanceToDestination = routeProgress.sectionProgress.last!.remainingDistanceInMeters
        print("Distance to destination in meters: \(distanceToDestination)")
        let trafficDelayAhead = routeProgress.sectionProgress.last!.trafficDelayInSeconds
        print("Traffic delay ahead in seconds: \(trafficDelayAhead)")

        // Contains the progress for the next maneuver ahead and the next-next maneuvers, if any.
        let nextManeuverList = routeProgress.maneuverProgress
        guard let nextManeuverProgress = nextManeuverList.first else {
            print("No next maneuver available.")
            return
        }

        let nextManeuverIndex = nextManeuverProgress.maneuverIndex
        guard let nextManeuver = visualNavigator.getManeuver(index: nextManeuverIndex) else {
            // Should never happen as we retrieved the next maneuver progress above.
            return
        }

        let action = nextManeuver.action
        let nextRoadName = nextManeuver.nextRoadName
        var road = nextRoadName == nil ? nextManeuver.nextRoadNumber : nextRoadName

        // On highways, we want to show the highway number instead of a possible street name,
        // while for inner city and urban areas street names are preferred over road numbers.
        if nextManeuver.nextRoadType == RoadType.highway {
            road = nextManeuver.nextRoadNumber == nil ? nextRoadName : nextManeuver.nextRoadNumber
        }

        if action == ManeuverAction.arrive {
            // We are reaching destination, so there's no next road.
            let currentRoadName = nextManeuver.roadName
            road = currentRoadName == nil ? nextManeuver.roadNumber : currentRoadName
        }

        let logMessage = "'\(String(describing: action))' on \(road ?? "unnamed road") in \(nextManeuverProgress.remainingDistanceInMeters) meters."

        if previousManeuverIndex != nextManeuverIndex {
            // Log only new maneuvers and ignore changes in distance.
            showMessage("New maneuver: " + logMessage)
        } else {
            // A maneuver update contains a different distance to reach the next maneuver.
            showMessage("Maneuver update: " + logMessage)
        }

        previousManeuverIndex = nextManeuverIndex
    }

    // Conform to DestinationReachedDelegate.
    // Notifies when the destination of the route is reached.
    func onDestinationReached() {
        showMessage("Destination reached. Stopping turn-by-turn navigation.")
        stopNavigation()
    }

    // Conform to MilestoneReachedDelegate.
    // Notifies when a waypoint on the route is reached.
    func onMilestoneReached(_ milestone: Milestone) {
        if let waypointIndex = milestone.waypointIndex {
            print("A user-defined waypoint was reached, index of waypoint: \(waypointIndex)")
            print("Original coordinates: \(String(describing: milestone.originalCoordinates))")
        } else {
            // For example, when transport mode changes due to a ferry.
            print("A system defined waypoint was reached at \(milestone.mapMatchedCoordinates)")
        }
    }

    // Conform to SpeedWarningDelegate.
    // Notifies when the current speed limit is exceeded.
    func onSpeedWarningStatusChanged(_ status: SpeedWarningStatus) {
        if status == SpeedWarningStatus.speedLimitExceeded {
            // Driver is faster than current speed limit (plus an optional offset).
            // Play a notification sound to alert the driver.
            // Note that this may not include temporary special speed limits, see SpeedLimitDelegate.
            AudioServicesPlaySystemSound(SystemSoundID(1016))
        }

        if status == SpeedWarningStatus.speedLimitRestored {
            print("Driver is again slower than current speed limit (plus an optional offset).")
        }
    }

    // Conform to SpeedLimitDelegate.
    // Notifies on the current speed limit valid on the current road.
    func onSpeedLimitUpdated(_ speedLimit: SpeedLimit) {
        let speedLimit = getCurrentSpeedLimit(speedLimit)

        if speedLimit == nil {
            print("Warning: Speed limits unkown, data could not be retrieved.")
        } else if speedLimit == 0 {
            print("No speed limits on this road! Drive as fast as you feel safe ...")
        } else {
            print("Current speed limit (m/s): \(String(describing: speedLimit))")
        }
    }

    private func getCurrentSpeedLimit(_ speedLimit: SpeedLimit) -> Double? {
        // If available, it is recommended to show this value as speed limit to the user.
        // Note that the SpeedWarningStatus only warns when speedLimit.speedLimitInMetersPerSecond is exceeded.
        if let specialSpeedLimit = getSpecialSpeedLimit(speedLimit.specialSpeedSituations) {
            return specialSpeedLimit
        }

        // If no special speed limit is available, show the standard speed limit.
        return speedLimit.speedLimitInMetersPerSecond
    }

    // An example implementation that will retrieve the slowest speed limit, including advisory speed limits and
    // weather-dependent speed limits that may or may not be valid due to the actual weather condition while driving.
    private func getSpecialSpeedLimit(_ specialSpeedSituations: [SpecialSpeedSituation]) -> Double? {
        var specialSpeedLimit: Double?
        
        // Iterates through the list of applicable special speed limits, if available.
        for specialSpeedSituation in specialSpeedSituations {

            // Check if a time restriction is available and if it is currently active.
            var timeRestrictionisPresent = false
            var timeRestrictionisActive = false
            for timeDomain in specialSpeedSituation.appliesDuring {
                timeRestrictionisPresent = true
                if timeDomain.isActive(at: Date()) {
                    timeRestrictionisActive = true
                }
            }

            if timeRestrictionisPresent && !timeRestrictionisActive {
                // We are not interested in currently inactive special speed limits.
                continue
            }
            
            if (specialSpeedSituation.type == .advisorySpeed) {
                print("Contains an advisory speed limit. For safety reasons it is recommended to respect it.")
            }

            if (specialSpeedSituation.type == .rain ||
                    specialSpeedSituation.type == .snow ||
                    specialSpeedSituation.type == .fog) {
                // The HERE SDK cannot detect the current weather condition, so a driver must decide
                // based on the situation if this speed limit applies.
                // Note: For this example we respect weather related speed limits, even if not applicable
                // due to the current weather condition.
                print("Attention: This road has weather dependent speed limits!")
            }

            let newSpecialSpeedLimit = specialSpeedSituation.specialSpeedLimitInMetersPerSecond
            print("Found special speed limit: \(newSpecialSpeedLimit) m/s, type \(specialSpeedSituation.type).")
            
            if specialSpeedLimit != nil && specialSpeedLimit! > newSpecialSpeedLimit {
                // For this example, we are only interested in the slowest special speed limit value,
                // regardless if it is legal, advisory or bound to conditions that may require the decision
                // of the driver.
                specialSpeedLimit = newSpecialSpeedLimit
            }
        }
        
        print("Slowest special speed limit (m/s): \(String(describing: specialSpeedLimit)))")
        return specialSpeedLimit
    }
    
    // Conform to NavigableLocationDelegate.
    // Notifies on the current map-matched location and other useful information while driving or walking.
    func onNavigableLocationUpdated(_ navigableLocation: NavigableLocation) {
        guard navigableLocation.mapMatchedLocation != nil else {
            print("The currentNavigableLocation could not be map-matched. Are you off-road?")
            return
        }

        let speed = navigableLocation.originalLocation.speedInMetersPerSecond
        let accuracy = navigableLocation.originalLocation.speedAccuracyInMetersPerSecond
        print("Driving speed: \(String(describing: speed)) plus/minus accuracy of \(String(describing: accuracy)).")
    }

    // Conform to RouteDeviationDelegate.
    // Notifies on a possible deviation from the route.
    func onRouteDeviation(_ routeDeviation: RouteDeviation) {
        guard let route = visualNavigator.route else {
            // May happen in rare cases when route was set to nil inbetween.
            return
        }

        // Get current geographic coordinates.
        var currentGeoCoordinates = routeDeviation.currentLocation.originalLocation.coordinates
        if let currentMapMatchedLocation = routeDeviation.currentLocation.mapMatchedLocation {
            currentGeoCoordinates = currentMapMatchedLocation.coordinates
        }

        // Get last geographic coordinates on route.
        var lastGeoCoordinates: GeoCoordinates?
        if let lastLocationOnRoute = routeDeviation.lastLocationOnRoute {
            lastGeoCoordinates = lastLocationOnRoute.originalLocation.coordinates
            if let lastMapMatchedLocationOnRoute = lastLocationOnRoute.mapMatchedLocation {
                lastGeoCoordinates = lastMapMatchedLocationOnRoute.coordinates
            }
        } else {
            print("User was never following the route. So, we take the start of the route instead.")
            lastGeoCoordinates = route.sections.first?.departurePlace.originalCoordinates
        }

        guard let lastGeoCoordinatesOnRoute = lastGeoCoordinates else {
            print("No lastGeoCoordinatesOnRoute found. Should never happen.")
            return
        }

        let distanceInMeters = currentGeoCoordinates.distance(to: lastGeoCoordinatesOnRoute)
        print("RouteDeviation in meters is \(distanceInMeters)")

        // Calculate a new route when deviation is too large. Note that this ignores route alternatives
        // and always takes the first route. Route alternatives are not supported for this example app.
        if (distanceInMeters > 30) {
            let destination = visualNavigator.route?.sections.last?.arrivalPlace.originalCoordinates
            routeCalculator.calculateRoute(start: currentGeoCoordinates,
                                           destination: destination!) { (routingError, routes) in
                if routingError == nil {
                    // When routingError is nil, routes is guaranteed to contain at least one route.
                    self.visualNavigator.route = routes!.first
                    self.showMessage("Rerouting completed.")
                    print("A new route was calculated, length: \(String(describing: self.visualNavigator.route?.lengthInMeters)) m.")
                }
            }
        }
    }

    // Conform to ManeuverNotificationDelegate.
    // Notifies on voice maneuver messages.
    func onManeuverNotification(_ text: String) {
        voiceAssistant.speak(message: text)
    }

    // Conform to the LaneAssistanceDelegate.
    // Notifies which lane(s) lead to the next (next) maneuvers.
    // Note: This feature is in BETA state and thus there can be bugs and unexpected behavior.
    // Related APIs may change for new releases without a deprecation process.
    func onLaneAssistanceUpdated(_ laneAssistance: LaneAssistance) {
        // This lane list is guaranteed to be non-empty.
        let lanes = laneAssistance.lanesForNextManeuver
        logLaneRecommendations(lanes)

        let nextLanes = laneAssistance.lanesForNextNextManeuver
        if !nextLanes.isEmpty {
            print("Attention, the next next maneuver is very close.")
            print("Please take the following lane(s) after the next maneuver: ")
            logLaneRecommendations(nextLanes)
        }
    }

    private func logLaneRecommendations(_ lanes: [Lane]) {
        // The lane at index 0 is the leftmost lane adjacent to the middle of the road.
        // The lane at the last index is the rightmost lane.
        // Note: Left-hand countries are not yet supported.
        var laneNumber = 0
        for lane in lanes {
            // This state is only possible if laneAssistance.lanesForNextNextManeuver is not empty.
            // For example, when two lanes go left, this lanes leads only to the next maneuver,
            // but not to the maneuver after the next maneuver, while the highly recommended lane also leads
            // to this next next maneuver.
            if lane.recommendationState == .recommended {
                print("Lane \(laneNumber) leads to next maneuver, but not to the next next maneuver.")
            }

            // If laneAssistance.lanesForNextNextManeuver is not empty, this lane leads also to the
            // maneuver after the next maneuver.
            if lane.recommendationState == .highlyRecommended {
                print("Lane \(laneNumber) leads to next maneuver and eventually to the next next maneuver.")
            }

            if lane.recommendationState == .notRecommended {
                print("Do not take lane \(laneNumber) to follow the route.")
            }

            laneNumber += 1
        }
    }
    
    // Conform to the RoadAttributesDelegate.
    // Notifies on the attributes of the current road including usage and physical characteristics.
    func onRoadAttributesUpdated(_ roadAttributes: RoadAttributes) {
        // This is called whenever any road attribute has changed.
        // If all attributes are unchanged, no new event is fired.
        // Note that a road can have more than one attribute at the same time.
        print("Received road attributes update.");

        if (roadAttributes.isBridge) {
          // Identifies a structure that allows a road, railway, or walkway to pass over another road, railway,
          // waterway, or valley serving map display and route guidance functionalities.
            print("Road attributes: This is a bridge.");
        }
        if (roadAttributes.isControlledAccess) {
          // Controlled access roads are roads with limited entrances and exits that allow uninterrupted
          // high-speed traffic flow.
            print("Road attributes: This is a controlled access road.");
        }
        if (roadAttributes.isDirtRoad) {
          // Indicates whether the navigable segment is paved.
            print("Road attributes: This is a dirt road.");
        }
        if (roadAttributes.isDividedRoad) {
          // Indicates if there is a physical structure or painted road marking intended to legally prohibit
          // left turns in right-side driving countries, right turns in left-side driving countries,
          // and U-turns at divided intersections or in the middle of divided segments.
            print("Road attributes: This is a divided road.");
        }
        if (roadAttributes.isNoThrough) {
          // Identifies a no through road.
            print("Road attributes: This is a no through road.");
        }
        if (roadAttributes.isPrivate) {
          // Private identifies roads that are not maintained by an organization responsible for maintenance of
          // public roads.
            print("Road attributes: This is a private road.");
        }
        if (roadAttributes.isRamp) {
          // Range is a ramp: connects roads that do not intersect at grade.
            print("Road attributes: This is a ramp.");
        }
        if (roadAttributes.isRightDrivingSide) {
          // Indicates if vehicles have to drive on the right-hand side of the road or the left-hand side.
          // For example, in New York it is always true and in London always false as the United Kingdom is
          // a left-hand driving country.
            print("Road attributes: isRightDrivingSide = \(roadAttributes.isRightDrivingSide)");
        }
        if (roadAttributes.isRoundabout) {
          // Indicates the presence of a roundabout.
            print("Road attributes: This is a roundabout.");
        }
        if (roadAttributes.isTollway) {
          // Identifies a road for which a fee must be paid to use the road.
            print("Road attributes change: This is a road with toll costs.");
        }
        if (roadAttributes.isTunnel) {
          // Identifies an enclosed (on all sides) passageway through or under an obstruction.
            print("Road attributes: This is a tunnel.");
        }
    }

    func startNavigation(route: Route,
                                isSimulated: Bool) {
        setupSpeedWarnings()
        setupVoiceGuidance()

        // Switches to navigation mode when no route was set before, otherwise navigation mode is kept.
        visualNavigator.route = route

        if isSimulated {
            enableRoutePlayback(route: route)
            showMessage("Starting simulated navgation.")
        } else {
            enableDevicePositioning()
            showMessage("Starting navgation.")
        }
    }

    func stopNavigation() {
        // Switches to tracking mode when a route was set before, otherwise tracking mode is kept.
        // Without a route the navigator will only notify on the current map-matched location
        // including info such as speed and current street name.
        visualNavigator.route = nil
        enableDevicePositioning()
        showMessage("Tracking device's location.")
    }

    // Provides location updates based on the given route.
    func enableRoutePlayback(route: Route) {
        herePositioningProvider.stopLocating()
        herePositioningSimulator.startLocating(locationDelegate: visualNavigator, route: route)
    }

    // Provides location updates based on the device's GPS sensor.
    func enableDevicePositioning() {
        herePositioningSimulator.stopLocating()
        herePositioningProvider.startLocating(locationDelegate: visualNavigator,
                                              accuracy: .navigation)
    }

    func startCameraTracking() {
        // By default, this is enabled.
        visualNavigator.cameraMode = CameraTrackingMode.enabled
    }

    func stopCameraTracking() {
        visualNavigator.cameraMode = CameraTrackingMode.disabled
    }

    func getLastKnownGeoCoordinates() -> GeoCoordinates? {
        return herePositioningProvider.getLastKnownLocation()?.coordinates
    }

    private func setupSpeedWarnings() {
        let speedLimitOffset = SpeedLimitOffset(lowSpeedOffsetInMetersPerSecond: 2,
                                                highSpeedOffsetInMetersPerSecond: 4,
                                                highSpeedBoundaryInMetersPerSecond: 25)
        visualNavigator.speedWarningOptions = SpeedWarningOptions(speedLimitOffset: speedLimitOffset)
    }

    private func setupVoiceGuidance() {
        let ttsLanguageCode = getLanguageCodeForDevice(supportedVoiceSkins: VisualNavigator.availableLanguagesForManeuverNotifications())
        visualNavigator.maneuverNotificationOptions = ManeuverNotificationOptions(language: ttsLanguageCode,
                                                                            unitSystem: UnitSystem.metric)

        print("LanguageCode for maneuver notifications: \(ttsLanguageCode).")

        // Set language to our TextToSpeech engine.
        let locale = LanguageCodeConverter.getLocale(languageCode: ttsLanguageCode)
        if voiceAssistant.setLanguage(locale: locale) {
            print("TextToSpeech engine uses this language: \(locale)")
        } else {
            print("TextToSpeech engine does not support this language: \(locale)")
        }
    }

    // Get the language preferrably used on this device.
    private func getLanguageCodeForDevice(supportedVoiceSkins: [heresdk.LanguageCode]) -> LanguageCode {

        // 1. Determine if preferred device language is supported by our TextToSpeech engine.
        let identifierForCurrenDevice = Locale.preferredLanguages.first!
        var localeForCurrenDevice = Locale(identifier: identifierForCurrenDevice)
        if !voiceAssistant.isLanguageAvailable(identifier: identifierForCurrenDevice) {
            print("TextToSpeech engine does not support: \(identifierForCurrenDevice), falling back to en-US.")
            localeForCurrenDevice = Locale(identifier: "en-US")
        }

        // 2. Determine supported voice skins from HERE SDK.
        var languageCodeForCurrenDevice = LanguageCodeConverter.getLanguageCode(locale: localeForCurrenDevice)
        if !supportedVoiceSkins.contains(languageCodeForCurrenDevice) {
            print("No voice skins available for \(languageCodeForCurrenDevice), falling back to enUs.")
            languageCodeForCurrenDevice = LanguageCode.enUs
        }

        return languageCodeForCurrenDevice
    }

    // A permanent view to show log content.
    private var messageTextView = UITextView()
    private func showMessage(_ message: String) {
        messageTextView.text = message
        messageTextView.textColor = .white
        messageTextView.backgroundColor = UIColor(red: 0, green: 144 / 255, blue: 138 / 255, alpha: 1)
        messageTextView.layer.cornerRadius = 8
        messageTextView.isEditable = false
        messageTextView.textAlignment = NSTextAlignment.center
        messageTextView.font = .systemFont(ofSize: 14)
        messageTextView.frame = CGRect(x: 0, y: 0, width: mapView.frame.width * 0.9, height: 50)
        messageTextView.center = CGPoint(x: mapView.frame.width * 0.5, y: mapView.frame.height * 0.9)

        UIView.transition(with: mapView, duration: 0.2, options: [.transitionCrossDissolve], animations: {
            self.mapView.addSubview(self.messageTextView)
        })
    }
}
