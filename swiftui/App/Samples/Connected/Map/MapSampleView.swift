import CatalogCore
@preconcurrency import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

struct MapPlace: Identifiable {
    let id = UUID()
    let name: String
    let mapItem: MKMapItem

    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }
}

@MainActor
@Observable
final class MapSampleModel: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let tokyo = CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)

    private(set) var places: [MapPlace] = []
    private(set) var currentLocation: CLLocation?
    private(set) var route: MKRoute?
    private(set) var selected: MapPlace?
    private(set) var isLocating = false
    private(set) var isWorking = false
    private(set) var usesFixtures = true
    private(set) var showsFixtureLine = false
    private(set) var canOpenSettings = false
    private(set) var status: String?
    var position: MapCameraPosition = .region(MapSampleModel.region(around: MapSampleModel.tokyo))

    @ObservationIgnored private var locationManager: CLLocationManager?
    @ObservationIgnored private var locationTimeout: Task<Void, Never>?
    @ObservationIgnored private var requestedAuthorization = false
    @ObservationIgnored private var locationStarted: ContinuousClock.Instant?
    @ObservationIgnored private var search: MKLocalSearch?
    @ObservationIgnored private var directions: MKDirections?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workDeadline: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored var diagnostics: DiagnosticStore?

    static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 2_400, longitudinalMeters: 2_400)
    }

    var origin: CLLocationCoordinate2D { currentLocation?.coordinate ?? Self.tokyo }

    func showFixtures() {
        let fixtures: [(String, Double, Double)] = [
            ("丸の内の広場（見本）", 35.681080, 139.765735),
            ("和田倉噴水公園（見本）", 35.683725, 139.762275),
            ("二重橋前（見本）", 35.680350, 139.761960)
        ]
        cancelNetwork()
        usesFixtures = true
        places = fixtures.map { name, latitude, longitude in
            MapPlace(name: name, mapItem: MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil))
        }
        selected = nil
        route = nil
        showsFixtureLine = false
        status = nil
        position = .region(Self.region(around: Self.tokyo))
    }

    func requestLocation() {
        guard !isLocating else { return }
        currentLocation = nil
        route = nil
        status = nil
        canOpenSettings = false
        isLocating = true
        locationStarted = .now
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager = manager
        manager.delegate = self
        updateAuthorization(manager)
    }

    func cancelLocation() {
        guard isLocating else { return }
        completeLocation("現在地の取得を中止しました。", outcome: .cancelled)
    }

    func findNearby(_ query: String) {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !text.isEmpty else {
            status = "調べたい場所の名前や種類を入力してください。"
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = Self.region(around: origin)
        let pending = MKLocalSearch(request: request)
        let id = beginNetwork(timeout: .seconds(15))
        search = pending
        let started = ContinuousClock.now
        work = Task {
            do {
                let response = try await pending.start()
                guard operationID == id, !Task.isCancelled else { return }
                usesFixtures = false
                showsFixtureLine = false
                route = nil
                selected = nil
                places = response.mapItems.prefix(12).map {
                    MapPlace(name: $0.name ?? "名称未設定", mapItem: $0)
                }
                if places.isEmpty { status = "場所が見つかりませんでした。検索語を変えてください。" }
                endNetwork()
                await diagnostics?.record(sample: .map, action: .load, outcome: .success,
                                           milliseconds: Self.elapsed(since: started))
            } catch {
                guard operationID == id else { return }
                status = "周辺検索に失敗しました。通信状態を確認し、もう一度検索してください。"
                endNetwork()
                await diagnostics?.record(sample: .map, action: .load, outcome: .failure)
            }
        }
    }

    func select(_ place: MapPlace) {
        cancelNetwork()
        selected = place
        route = nil
        showsFixtureLine = false
        status = nil
        position = .region(Self.region(around: place.coordinate))
    }

    func showRoute() {
        guard let selected else { return }
        if usesFixtures {
            showsFixtureLine = true
            position = .region(Self.region(around: Self.tokyo))
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = selected.mapItem
        request.transportType = .walking
        let pending = MKDirections(request: request)
        let id = beginNetwork(timeout: .seconds(20))
        directions = pending
        let started = ContinuousClock.now
        work = Task {
            do {
                let response = try await pending.calculate()
                guard operationID == id, !Task.isCancelled else { return }
                route = response.routes.first
                if let route {
                    let bounds = route.polyline.boundingMapRect
                    position = .rect(bounds.insetBy(dx: -max(bounds.width * 0.18, 250),
                                                    dy: -max(bounds.height * 0.18, 250)))
                } else {
                    status = "徒歩経路が見つかりませんでした。別の場所を選んでください。"
                }
                endNetwork()
                await diagnostics?.record(sample: .map, action: .process, outcome: route == nil ? .limited : .success,
                                           milliseconds: Self.elapsed(since: started))
            } catch {
                guard operationID == id else { return }
                status = "徒歩経路を取得できませんでした。通信状態を確認し、もう一度お試しください。"
                endNetwork()
                await diagnostics?.record(sample: .map, action: .process, outcome: .failure)
            }
        }
    }

    func cancelNetwork() {
        stopNetwork("取得を中止しました。", outcome: .cancelled)
    }

    private func stopNetwork(_ message: String, outcome: DiagnosticOutcome) {
        let action: DiagnosticAction = search == nil ? .process : .load
        let wasWorking = isWorking
        operationID = UUID()
        search?.cancel()
        directions?.cancel()
        work?.cancel()
        endNetwork()
        if wasWorking {
            status = message
            Task { await diagnostics?.record(sample: .map, action: action, outcome: outcome) }
        }
    }

    private func beginNetwork(timeout: Duration) -> UUID {
        cancelNetwork()
        status = nil
        isWorking = true
        workDeadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.stopNetwork("時間内に取得できませんでした。通信状態を確認して再試行してください。", outcome: .failure)
        }
        return operationID
    }

    private func endNetwork() {
        search = nil
        directions = nil
        work = nil
        workDeadline?.cancel()
        workDeadline = nil
        isWorking = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        updateAuthorization(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager, let location = locations.last else { return }
        currentLocation = location
        route = nil
        position = .region(Self.region(around: location.coordinate))
        completeLocation(nil, outcome: .success)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard manager === locationManager else { return }
        completeLocation("現在地を取得できませんでした。場所を変えて再試行できます。", outcome: .failure)
    }

    private func updateAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            if !requestedAuthorization {
                requestedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            guard locationTimeout == nil else { return }
            locationStarted = .now
            locationTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self?.completeLocation("現在地の取得が時間内に完了しませんでした。再試行できます。", outcome: .failure)
            }
            manager.requestLocation()
        case .denied:
            canOpenSettings = true
            completeLocation("位置情報が使えません。設定で確認するか、東京駅を起点に試してください。", outcome: .limited)
        case .restricted:
            completeLocation("端末の設定で位置情報が制限されています。東京駅を起点に試してください。", outcome: .limited)
        @unknown default:
            completeLocation("現在の位置情報の設定に対応できません。", outcome: .limited)
        }
    }

    private func completeLocation(_ message: String?, outcome: DiagnosticOutcome) {
        let elapsed = locationStarted.map(Self.elapsed(since:))
        locationManager?.delegate = nil
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        locationTimeout?.cancel()
        locationTimeout = nil
        locationStarted = nil
        requestedAuthorization = false
        isLocating = false
        status = message
        Task { await diagnostics?.record(sample: .map, action: .track, outcome: outcome, milliseconds: elapsed) }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}

struct MapSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var model = MapSampleModel()
    @State private var query = "カフェ"
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        @Bindable var model = model
        List {
            Section("地図") {
                Map(position: $model.position) {
                    if let location = model.currentLocation {
                        Marker("現在地", coordinate: location.coordinate).tint(.blue)
                    }
                    ForEach(model.places) { place in
                        Marker(place.name, coordinate: place.coordinate)
                    }
                    if let route = model.route {
                        MapPolyline(route.polyline).stroke(.teal, lineWidth: 5)
                    }
                    if model.showsFixtureLine, let selected = model.selected {
                        MapPolyline(coordinates: [MapSampleModel.tokyo, selected.coordinate])
                            .stroke(.teal, style: StrokeStyle(lineWidth: 4, dash: [6, 6]))
                    }
                }
                .frame(minHeight: 260)
                if let route = model.route {
                    Label(
                        "\(Measurement(value: route.distance, unit: UnitLength.meters).formatted()) · 徒歩 約\(max(1, Int(route.expectedTravelTime / 60)))分",
                        systemImage: "figure.walk"
                    )
                }
                Text(model.usesFixtures ? "場所の見本を表示中。点線は見本の直線です。" :
                        (model.currentLocation == nil ? "徒歩経路の起点は東京駅です。" : "徒歩経路の起点は取得した現在地です。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("周辺を調べる") {
                HStack {
                    TextField("場所の名前や種類", text: $query)
                        .focused($queryIsFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            if !model.isWorking, !model.isLocating { model.findNearby(query) }
                        }
                    if !query.isEmpty {
                        Button {
                            model.cancelNetwork()
                            query = ""
                            queryIsFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("検索語をクリア")
                    }
                }
                Button("周辺を検索", systemImage: "magnifyingglass") { model.findNearby(query) }
                    .disabled(model.isWorking || model.isLocating)
                if model.isWorking {
                    ProgressView("取得しています")
                    Button("取得を中止") { model.cancelNetwork() }
                }
                if model.isLocating {
                    ProgressView("現在地を取得しています")
                    Button("位置取得を中止") { model.cancelLocation() }
                } else {
                    Button("現在地を取得", systemImage: "location") { model.requestLocation() }
                        .disabled(model.isWorking)
                }
                Button("再現用の場所を表示") { model.showFixtures() }
                    .disabled(model.isLocating)
                if let status = model.status { Text(status).foregroundStyle(.secondary) }
                if model.canOpenSettings {
                    Button("位置情報の設定を開く") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                    }
                }
            }
            Section(model.usesFixtures ? "場所の見本" : "検索結果") {
                ForEach(model.places) { place in
                    Button {
                        model.select(place)
                    } label: {
                        Label(place.name, systemImage: model.selected?.id == place.id ? "checkmark.circle.fill" : "mappin")
                    }
                    .accessibilityAddTraits(model.selected?.id == place.id ? [.isSelected] : [])
                }
                if let selected = model.selected {
                    Text("選択中 · \(selected.name)").foregroundStyle(.secondary)
                    Button(model.usesFixtures ? "見本の直線を表示" : "徒歩経路を調べる") { model.showRoute() }
                        .disabled(model.isWorking || model.isLocating)
                } else if model.places.isEmpty {
                    Text("検索結果はここに表示されます。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("場所と経路を調べる")
        .onAppear {
            model.diagnostics = diagnostics
            if model.places.isEmpty, model.usesFixtures { model.showFixtures() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stop() }
        }
        .onDisappear(perform: stop)
    }

    private func stop() {
        model.cancelNetwork()
        model.cancelLocation()
    }
}

#Preview {
    NavigationStack { MapSampleView() }
}
