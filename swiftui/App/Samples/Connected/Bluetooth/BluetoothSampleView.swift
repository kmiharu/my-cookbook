import CatalogCore
@preconcurrency import CoreBluetooth
import Observation
import SwiftUI
import UIKit

private struct NearbyBluetoothDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int?
}

@MainActor
@Observable
private final class BluetoothSampleModel: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum LinkPhase {
        case idle, connecting, connected, disconnecting
    }

    static let deviceLimit = 24
    private static let informationService = CBUUID(string: "180A")
    private static let manufacturerCharacteristic = CBUUID(string: "2A29")
    private static let fixture = NearbyBluetoothDevice(
        id: UUID(uuidString: "A6580FF3-2865-40E9-BEB6-1F18380AAF14")!,
        name: "温度計（見本）", rssi: -56
    )

    private(set) var devices: [NearbyBluetoothDevice] = []
    private(set) var isScanning = false
    private(set) var phase = LinkPhase.idle
    private(set) var selected: NearbyBluetoothDevice?
    private(set) var rssi: Int?
    private(set) var manufacturer: String?
    private(set) var status: String?
    private(set) var isReading = false
    private(set) var canOpenSettings = false
    var usesFixtures = true

    @ObservationIgnored var diagnostics: DiagnosticStore?
    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var known: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var active: CBPeripheral?
    @ObservationIgnored private var scanDeadline: Task<Void, Never>?
    @ObservationIgnored private var linkDeadline: Task<Void, Never>?
    @ObservationIgnored private var manufacturerDeadline: Task<Void, Never>?
    @ObservationIgnored private var readDeadline: Task<Void, Never>?
    @ObservationIgnored private var scanStarted: ContinuousClock.Instant?
    @ObservationIgnored private var connectionStarted: ContinuousClock.Instant?
    @ObservationIgnored private var readStarted: ContinuousClock.Instant?

    func scan() {
        guard !isScanning, phase == .idle else { return }
        devices.removeAll()
        known.removeAll()
        status = nil
        canOpenSettings = false
        if usesFixtures {
            devices = [Self.fixture]
            return
        }

        isScanning = true
        scanStarted = .now
        scanDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self else { return }
            if devices.isEmpty {
                finishScan("機器が見つかりませんでした。近くの機器を探索できる状態にして再試行してください。",
                           outcome: .limited)
            } else {
                finishScan("探索を終了しました。表示された機器を選べます。", outcome: .success)
            }
        }
        if let manager {
            updatePowerState(manager)
        } else {
            manager = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stopScan() {
        guard isScanning else { return }
        finishScan("探索を中止しました。", outcome: .cancelled)
    }

    func connect(_ device: NearbyBluetoothDevice) {
        guard phase == .idle else { return }
        if usesFixtures {
            selected = device
            phase = .connected
            manufacturer = "Cookbook Fixture"
            status = "見本の接続状態です。"
            return
        }
        guard let peripheral = known[device.id], let manager, manager.state == .poweredOn else {
            status = "機器を利用できません。もう一度探索してください。"
            return
        }
        if isScanning { finishScan(nil, outcome: .success) }
        selected = device
        phase = .connecting
        active = peripheral
        status = nil
        connectionStarted = .now
        manager.connect(peripheral)
        linkDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.resetRadio("接続が時間内に完了しませんでした。探索からやり直してください。", outcome: .failure)
        }
    }

    func disconnect() {
        if usesFixtures {
            clearLink()
            status = "見本の接続を終了しました。"
            return
        }
        guard let peripheral = active, let manager, phase == .connecting || phase == .connected else { return }
        if phase == .connecting { recordConnect(.cancelled) }
        phase = .disconnecting
        status = nil
        linkDeadline?.cancel()
        finishRead()
        manager.cancelPeripheralConnection(peripheral)
        linkDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.resetRadio("接続を解除しました。再探索できます。", outcome: .cancelled)
        }
    }

    func readSignal() {
        guard phase == .connected, !isReading else { return }
        if usesFixtures {
            rssi = Self.fixture.rssi
            return
        }
        guard let active else { return }
        isReading = true
        readStarted = .now
        status = nil
        active.readRSSI()
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self else { return }
            let elapsed = readStarted.map(Self.elapsed(since:))
            finishRead()
            status = "電波強度の読み取りが時間内に完了しませんでした。再試行できます。"
            await diagnostics?.record(sample: .bluetooth, action: .process, outcome: .failure, milliseconds: elapsed)
        }
    }

    func stop() {
        resetRadio(nil, outcome: .cancelled)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        updatePowerState(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard central === manager, isScanning, devices.count < Self.deviceLimit, known[peripheral.identifier] == nil else { return }
        known[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "名前のない機器"
        devices.append(NearbyBluetoothDevice(
            id: peripheral.identifier, name: String(name.prefix(80)), rssi: rssi.intValue == 127 ? nil : rssi.intValue
        ))
        if devices.count == 1, let started = scanStarted {
            let milliseconds = Self.elapsed(since: started)
            Task { await diagnostics?.record(sample: .bluetooth, action: .ready, outcome: .success, milliseconds: milliseconds) }
        }
        if devices.count == Self.deviceLimit {
            finishScan("上限の\(Self.deviceLimit)台を表示しています。", outcome: .success)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === manager, peripheral === active, phase == .connecting else { return }
        linkDeadline?.cancel()
        linkDeadline = nil
        phase = .connected
        recordConnect(.success)
        peripheral.delegate = self
        peripheral.discoverServices([Self.informationService])
        manufacturerDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finishManufacturer("時間内に取得できませんでした")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard central === manager, peripheral === active else { return }
        recordConnect(.failure)
        clearLink()
        status = "接続できませんでした。機器の状態を確認して再試行してください。"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        guard central === manager, peripheral === active else { return }
        let expected = phase == .disconnecting
        if phase == .connecting { recordConnect(.failure) }
        clearLink()
        status = expected ? "接続を解除しました。" : "接続が切れました。機器を選び直すと再接続できます。"
        if !expected { Task { await diagnostics?.record(sample: .bluetooth, action: .track, outcome: .limited) } }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === active, phase == .connected, manufacturer == nil else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.informationService }) else {
            finishManufacturer("機器が提供していません")
            return
        }
        peripheral.discoverCharacteristics([Self.manufacturerCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === active, phase == .connected, manufacturer == nil else { return }
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.manufacturerCharacteristic }),
              characteristic.properties.contains(.read) else {
            finishManufacturer("読み取れる製造元情報がありません")
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === active, phase == .connected, manufacturer == nil,
              characteristic.uuid == Self.manufacturerCharacteristic else { return }
        if error == nil, let data = characteristic.value, data.count <= 512,
           let string = String(data: data, encoding: .utf8), !string.isEmpty {
            finishManufacturer(String(string.prefix(100)))
        } else {
            finishManufacturer("製造元情報を読み取れませんでした")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI value: NSNumber, error: (any Error)?) {
        guard peripheral === active, phase == .connected, isReading else { return }
        let elapsed = readStarted.map(Self.elapsed(since:))
        finishRead()
        let measured = error == nil && value.intValue != 127
        if measured {
            rssi = value.intValue
        } else {
            status = "電波強度を読み取れませんでした。再試行できます。"
        }
        Task { await diagnostics?.record(sample: .bluetooth, action: .process,
                                         outcome: measured ? .success : .failure, milliseconds: elapsed) }
    }

    private func updatePowerState(_ central: CBCentralManager) {
        let message: String
        switch central.state {
        case .poweredOn:
            if isScanning, !central.isScanning {
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
            return
        case .unknown, .resetting:
            return
        case .poweredOff:
            message = "Bluetoothがオフです。オンにして再試行してください。"
        case .unauthorized:
            message = "Bluetoothが許可されていません。設定で確認するか、再現用データで試してください。"
        case .unsupported:
            message = "この端末ではBluetooth LEを利用できません。再現用データで試してください。"
        @unknown default:
            message = "現在のBluetooth状態に対応できません。"
        }
        resetRadio(message, outcome: .limited)
        canOpenSettings = central.state == .unauthorized
    }

    private func finishScan(_ message: String?, outcome: DiagnosticOutcome) {
        if let manager, manager.state == .poweredOn, manager.isScanning { manager.stopScan() }
        scanDeadline?.cancel()
        scanDeadline = nil
        isScanning = false
        status = message
        if let started = scanStarted {
            let elapsed = Self.elapsed(since: started)
            Task { await diagnostics?.record(sample: .bluetooth, action: .load, outcome: outcome, milliseconds: elapsed) }
        }
        scanStarted = nil
    }

    private func finishRead() {
        readDeadline?.cancel()
        readDeadline = nil
        readStarted = nil
        isReading = false
    }

    private func finishManufacturer(_ result: String) {
        manufacturerDeadline?.cancel()
        manufacturerDeadline = nil
        manufacturer = result
    }

    private func clearLink() {
        active?.delegate = nil
        active = nil
        selected = nil
        rssi = nil
        manufacturer = nil
        manufacturerDeadline?.cancel()
        manufacturerDeadline = nil
        phase = .idle
        finishRead()
        linkDeadline?.cancel()
        linkDeadline = nil
        connectionStarted = nil
    }

    private func resetRadio(_ message: String?, outcome: DiagnosticOutcome) {
        if isScanning { finishScan(message, outcome: outcome) }
        if phase == .connecting { recordConnect(outcome) }
        if let active, let manager, manager.state == .poweredOn { manager.cancelPeripheralConnection(active) }
        manager?.delegate = nil
        manager = nil
        clearLink()
        known.removeAll()
        devices.removeAll()
        status = message
        canOpenSettings = false
    }

    private func recordConnect(_ outcome: DiagnosticOutcome) {
        guard let started = connectionStarted else { return }
        let milliseconds = Self.elapsed(since: started)
        connectionStarted = nil
        Task { await diagnostics?.record(sample: .bluetooth, action: .track, outcome: outcome, milliseconds: milliseconds) }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}

struct BluetoothSampleView: View {
    @Environment(\.diagnostics) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var model = BluetoothSampleModel()

    var body: some View {
        @Bindable var model = model
        List {
            Section("接続方法") {
                Picker("モード", selection: $model.usesFixtures) {
                    Text("再現用データ").tag(true)
                    Text("近くのBLE機器").tag(false)
                }
                Text(model.usesFixtures ? "探索、接続、読み取りを見本で試せます。" :
                        "接続するには探索可能で、接続を許可するBLE機器が近くに必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("機器を探索") {
                if model.isScanning {
                    ProgressView("機器を探索しています")
                    Button("探索を中止") { model.stopScan() }
                } else {
                    Button(model.usesFixtures ? "見本を探索" : "機器を探索", systemImage: "dot.radiowaves.left.and.right") {
                        model.scan()
                    }
                    .disabled(model.phase != .idle)
                }
                ForEach(model.devices) { device in
                    Button {
                        model.connect(device)
                    } label: {
                        Label(device.name, systemImage: "sensor")
                    }
                    .disabled(model.phase != .idle)
                    .accessibilityHint("機器に接続")
                }
                if let status = model.status { Text(status).foregroundStyle(.secondary) }
                if model.canOpenSettings {
                    Button("Bluetoothの設定を開く") {
                        if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                    }
                }
            }
            if let device = model.selected {
                Section("接続状態") {
                    Text(device.name).font(.headline)
                    switch model.phase {
                    case .idle:
                        EmptyView()
                    case .connecting:
                        ProgressView("接続しています")
                        Button("接続を中止") { model.disconnect() }
                    case .disconnecting:
                        ProgressView("接続を解除しています")
                    case .connected:
                        Label(model.usesFixtures ? "接続中（見本）" : "接続中", systemImage: "checkmark.circle")
                        LabeledContent("製造元", value: model.manufacturer ?? "確認中")
                        LabeledContent("探索時の電波強度", value: device.rssi.map { "\($0) dBm" } ?? "不明")
                        LabeledContent("読み取った電波強度", value: model.rssi.map { "\($0) dBm" } ?? "未取得")
                        Button("電波強度を読み取る") { model.readSignal() }.disabled(model.isReading)
                        if model.isReading { ProgressView("電波強度を読み取っています") }
                        Button("接続を解除") { model.disconnect() }
                    }
                }
            }
        }
        .navigationTitle("Bluetooth機器につなぐ")
        .onAppear { model.diagnostics = diagnostics }
        .onChange(of: model.usesFixtures) { _, _ in model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
        }
        .onDisappear { model.stop() }
    }
}

#Preview {
    NavigationStack { BluetoothSampleView() }
}
