//
// Created by Jeff Craighead on 3/23/16.
// Copyright (c) 2016 Silent Partner Technologies. All rights reserved.
//

import Foundation
import CoreBluetooth

public enum Gen2MemoryBank {
    case epc
    case user
    case tid
    case reserved
    case notSpecified
}

public enum ReaderButtonStates : Int {
    case unknown = 0
    case off  = 1
    case single = 2
    case double = 3
    
    public static func enumFromInt(_ value : Int) -> ReaderButtonStates{
        switch(value){
        case 0:
            return .unknown
        case 1:
            return .off
        case 2:
            return .single
        case 3:
            return .double
        default:
            return .unknown
        }
    }
}

protocol RFIDReader {
    var currentAccessory: Any? {get set}
    //var bleAccessory: CBPeripheral? {get set}
    //var btAccessory: EAAccessory? {get set}
    var versionString: String {get set}
    var readerOn:Bool {get set}
    
    func connect(anyAccessory:Any?)
    func resetConnectedDevice(completion: ((Bool)->Void)?)
    func updateBatteryStatus()
    func updateVersionInfo()
    func setRfidPower(power: Int32, completion: ((Bool)->Void)?)
    func getRfidPower()->Int32
    func getMinRfidPower()->Int32
    func getMaxRfidPower()->Int32
    func writeEPC(epcData: String, tagFilter: String, accessPassword: String, completion: ((Bool)->Void)?)
    func burnTag(newPC: String, newEPC: String, startAddress: Int32, tagFilter : String, accessPassword: String, memoryBank: Gen2MemoryBank, completion: ((Bool)->Void)?)
    func seekTagWithInventoryCommand(tagFilter : String)
    func readTagWithInventoryCommand(tagFilter : String, includeRSSI : Bool)
    func readTag(tagFilter : String?, accessPassword: String?, memoryBank: Gen2MemoryBank)
    func readBarcode()
    func setRfidParameters(session: Int, target:String, qAlgorithm:String, q: Int32)
    func outputPowerFromSliderValue(power: Float) -> Int32
    func sliderValueFromOutputPower(power: Int32) -> Float
    func disconnect(permanant:Bool, completion: (()->Void)?)
    func isConnected() -> Bool
    func setAlertEnabled(enabled:Bool)
    func enableTriggerDefaults(singlePress: Bool, doublePress: Bool, reporting: Bool)
    func resetTriggerToDefaults()
    func buttonPressSingle()
    func buttonPressDouble()
    func startContinuousInventory()
    func stopContinuousInventory()
    func abort()
}
