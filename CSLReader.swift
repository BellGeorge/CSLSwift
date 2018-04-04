//
//  CSLReader.swift
//  IntelliView
//
//  Created by Jeff Craighead on 11/28/17.
//  Copyright © 2017 Silent Partner Technologies. All rights reserved.
//

/**
 Notes:
 1. For RFID 'firmware' commands, multi-byte data is byte swapped vs what is listed in the API document, per the API document. So Register address 0x0001 is sent and received as 0x0100. (see page 29 of the API document)
 2. For RFID 'firmware' commands, some commands require a HST_CMD command to be sent first. The commands that require a HST_CMD activate various GEN2 commands such as Start Inventory, Read, Write, etc. (See page 48 of the API document)
 
 */


import Foundation
import CoreBluetooth

open class CSLReader: NSObject, RFIDReader, CBPeripheralDelegate{
    
    var appDelegate: AppDelegate?
    
    var currentAccessory: Any?
    var bleAccessory: CBPeripheral?
    var versionString: String = ""
    
    //These flags are set when a read is in progress
    var readerOn: Bool = false
    var barcodeOn: Bool = false
    
    var batteryStatus : Int32? = 0
    var serialNumber: String = ""
    var firmwareVersion: String = ""
    var outputPower : Int32 = 300
    fileprivate var minPower : Int32 = 50
    fileprivate var maxPower : Int32 = 300
    private let batteryMaxV = 4100.0
    private let batteryMinV = 3400.0
    private let rssiOffset = 120.0
    
    var seekerMode = false
    var readOneMode = false
    var compactMode = false
    var tagToSeek = ""
    private var lastTagFilter = ""
    
    private var connecting = false
    private var rfidConnected = false //True when a connection to the reader is established (but before characteristics are discovered)
    private var connectionReady = false //Set this to true after characteristics are discovered
    private var displayingAlertMessage = false
    
    private var buttonPressed = false
    private var buttonPressCount = 0
    private let doublePressDelay = 0.5
    private var performSingleButtonPressAction = true
    private var performDoubleButtonPressAction = true
    private var notifyOnButtonPress = false
    
    private var uplinkUuid = CBUUID(string: "9901")
    private var downlinkUuid = CBUUID(string: "9900")
    private var downlinkCharacteristic: CBCharacteristic?
    private var uplinkCharacteristic: CBCharacteristic?
   
    private var barcodeMultiPacketReadInProgress = false
    private var rfidMultiPacketReadInProgress = false
    private var lastPacketType: UInt8 = 0
    private var readingUnderConstruction: Reading? = nil
    private var rfidPacketUnderConstruction: Data? = nil
    private var rfidBytesToGo = 0
    private var uplinkData:[Data] = []
    private var inventorySequenceNumber: UInt8 = 0
    private var uplinkPacketLength: UInt8 = 0 //This is grabbed from a packet header in the decodeUplink function and used to make sure we get all the data for multi-packet data
    
    private var rfidCommandDownlinkData:[Data] = []
    private var rfidCommandInProgress: Bool = false
    private var rfidCommandThreadShouldRun: Bool = false
    private var rfidCommandSemaphore = DispatchSemaphore(value: 1)
    private var rfidCommandInProgressTimer: Timer? = nil
    private var uplinkDecoderThreadShouldRun = false
    private var uplinkDataSemaphore = DispatchSemaphore(value: 1)
    private var uplinkSerialDispatchQueue = DispatchQueue(label:"uplinkQueue")
    private var inventoryAlgorithm: UInt32 = DYNAMIC_Q
    private var linkProfile: UInt32 = PROFILE_UNKNOWN
    private var willWriteTag = false
    private var completion: ((Bool) -> Void)? = nil
    private var executeCompletionUponCommandEnd = false
    
    // MARK: - Init functions
    
    public init(bleAccessory: CBPeripheral){
        super.init() //Call super.init first!
        
        appDelegate = UIApplication.shared.delegate as? AppDelegate
        
        self.bleAccessory = bleAccessory
        self.currentAccessory = bleAccessory
        
        //self.bleAccessory?.delegate = self
        
        connect(anyAccessory: bleAccessory)
        
        //Kick off the uplink processing thread in the background
        DispatchQueue.global(qos: .utility).async {
            self.uplinkDecoderThreadShouldRun = true
            while self.uplinkDecoderThreadShouldRun {
                self.uplinkDataSemaphore.wait() //Acquire the semaphore before poking uplinkData
                if self.uplinkData.count > 0 {
                    let nextPacket = self.uplinkData.removeFirst()
                    self.uplinkDataSemaphore.signal() //Release the semaphore
                    self.decodeUplinkData(data: nextPacket)
                }
                else {
                    self.uplinkDataSemaphore.signal() //Release the semaphore
                    usleep(10000) // Sleep for 10ms if the array is empty
                }
                
            }
        }
        
        //Kick off the rfid downlink processing thread in the background
        DispatchQueue.global(qos: .utility).async {
            self.rfidCommandThreadShouldRun = true
            while self.rfidCommandThreadShouldRun {
                while self.rfidCommandInProgress {
                    usleep(25000) // Sleep for 100ms if a command is in progress, then check again
                }
                //Once the command state is clear, issue the next command if one exists
                self.rfidCommandSemaphore.wait() //Acquire the semaphore before poking uplinkData
                
                if self.rfidCommandDownlinkData.count > 0 && self.downlinkCharacteristic != nil {
                    let command = self.rfidCommandDownlinkData.removeFirst()
                    if self.isConnected() { // Only send the command if we're actually connected to the gun
                        print("Sending \(command.hexEncodedString(separator: " "))")
                        self.rfidCommandInProgress = true
                        self.bleAccessory?.writeValue(command, for: self.downlinkCharacteristic!, type: CBCharacteristicWriteType.withResponse)
                        //Start/Reset a timer to set rfidCommandInProgress to false
                        if self.rfidCommandInProgressTimer != nil {
                            self.rfidCommandInProgressTimer?.invalidate() //Invalidate the current timer
                        }
                        DispatchQueue.main.async {
                            self.rfidCommandInProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false, block: { // and start a new one
                                (timer:Timer) -> Void in
                                self.rfidCommandInProgress = false // After the time interval, assume we missed the End-Command Packet and set rfidCommandInProgress to false)
                            })
                        }
                    }
                    self.rfidCommandSemaphore.signal() //Release the semaphore
                }
                else {
                    if self.displayingAlertMessage {
                        self.displayingAlertMessage = false
                        //This will send the notification to clear a buttonless UIAlertMessage that we're using when the reader is connecting/configuring
                        DispatchQueue.main.async{
                            NotificationCenter.default.post(name: Notification.Name(rawValue: readerConnectingNotification),object: nil)
                        }
                    }

                    self.rfidCommandSemaphore.signal() //Release the semaphore
                    usleep(10000) // Sleep for 10ms if the array is empty
                }
            }
        }
    }
    
    deinit {
        uplinkDecoderThreadShouldRun = false
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - CSLReader specific methods
    func sendDownlink(data: Data){
        guard connectionReady && downlinkCharacteristic != nil else { return }
        print("Sending \(data.hexEncodedString(separator: " "))")
        bleAccessory?.writeValue(data, for: downlinkCharacteristic!, type: CBCharacteristicWriteType.withResponse)
    }
    
    //TODO - Need to create a sendRfidCommandDownlink function - this should enqueue the write into a command queue which waits for the reader to return begin and end command packets, specifically, end command packets, before sending the next command in the queue.
    func sendRfidCommandDownlink(data: Data){
        rfidCommandSemaphore.wait()
        rfidCommandDownlinkData.append(data)
        rfidCommandSemaphore.signal()
    }
    
    //Create a Data packet formatted as needed for the specified command type
    func createCommandPacket(data: Data, commandType: CslCommandType) -> Data {
        var header = Data(count: 8)
        
        header[0] = PREFIX
        header[1] = CslConnectionType.bluetooth.rawValue
        header[2] = UInt8(data.count)
        header[3] = commandType.rawValue // AKA Destination / Source (TYPE_BARCODE, TYPE_RFID, TYPE_NOTIFY, TYPE_SILAB, TYPE_BT)
        header[4] = RESERVE
        header[5] = CslLinkDirection.down.rawValue // Send data down to device
        header[6] = 0 //CRC byte 1 - setting the CRC to 0 disables the CRC check
        header[7] = 0 //CRC byte 2 - setting the CRC to 0 disables the CRC check
        //Create an empty full size packet
        var packet: Data = Data(count: 8 + data.count)
        
        // Put the header in the packet
        for index in 0...7 {
            packet[index] = header[index]
        }
        //Put the data in the packet
        for index in 0..<data.count {
            packet[index+8] = data[index]
        }
        
        return packet
    }
    
    // Create the data for a REG_REG, reverse the bytes for address and data so that they can be specified in the 'normal' order, endianness conversion is handeled here
    func createRegRequestData(write:Bool, address: UInt16, data: UInt32, dataReversed: Bool = true) -> Data{
        var retVal = Data(RFID_COMMAND.toData())
        retVal.append(Data([REG_REQ, write ? 0x01 : 0x00]))
        retVal.append(Data(address.toData().reversed()))
        if dataReversed {
            retVal.append(Data(data.toData().reversed()))
        }
        else {
            retVal.append(Data(data.toData()))
        }
        return retVal
    }
    
    /**
     decodeRfidData attempts to assemble a complete packet and then either send a notification or print some debug output if a command response packet
     OR if the packet contains RFID readings, return a new Reading object to the caller.
     
     parameters: data - Raw data from the BLE uplink, stripped of the uplink header
     returns: nil or a Reading object
     */
    func decodeRfidData(data: Data) -> [Reading]?{
        let startIndex = data.startIndex //Need this because the ArraySlice still has to be indexed with the old index, it does not start at 0
        guard rfidMultiPacketReadInProgress || data[startIndex] == 0x80 || data[startIndex] == 0x81 else {
            return nil
        }

        if !rfidMultiPacketReadInProgress && data[startIndex] == 0x80 { //This branch handles module power on/off responses
            //Handle RFID module power on response
            if data[startIndex+1] == 0x00 && data[startIndex+2] == 0x00 { //Power on success
                print("RFID Power On Success")
                rfidAbort() //Abort any current RFID operations
                updateVersionInfo()
                return nil
            }
            else if data[startIndex+1] == 0x00 && data[startIndex+2] == 0xFF { //Power on failed
                print("RFID Power On Failed")
                return nil
            }
            
            //Handle RFID module power off response
            if data[startIndex+1] == 0x01 && data[startIndex+2] == 0x00 { //Power off success
                print("RFID Power Off Success")
                return nil
            }
            else if data[startIndex+1] == 0x01 && data[startIndex+2] == 0xFF { //Power off failed
                print("RFID Power Off Failed")
                return nil
            }
            
            //Handle RFID firmware command response
            if data[startIndex+1] == 0x02 && (data[startIndex+2] == 0x00 || data[startIndex+2] == 0x01) { //RFID Command success
                print("RFID Command Success")
                
                let packet = data[(startIndex + 2)...]
                let psi = packet.startIndex
                let packetVer = packet[psi]
                
                //Make sure we have enough bytes to decode the packet, otherwise we've probably got garbage from an incomplete transmission and we will return nil
                guard packet.count > 6 else {
                    rfidCommandInProgress = false //Some commands don't have a begin & end response, and are short. We still want to allow a new packet to be sent without waiting for the timer to fire
                    return nil
                }
                
                let flags = packet[psi + 1]
                let packetType: UInt16 = UInt16(packet[psi + 3])<<8 + UInt16(packet[psi + 2])
                let status: UInt16 = UInt16(packet[psi + 13])<<8 + UInt16(packet[psi + 12])
                let errorPort: UInt8 = packet[psi + 14]
                
                switch(packetType){
                case 0x0000: //Command-Begin Response Packet
                    fallthrough
                case 0x8000:
                    break
                    
                case 0x0001: //Command-End Response Packet
                    fallthrough
                case 0x8001:
                    break
                    
                default:
                    break
                }
                
                return nil
            }
            else if data[startIndex+1] == 0x02 && data[startIndex+2] == 0xFF { //RFID Command failed
                print("RFID Command Failed")
                return nil
            }
        }
        else if !rfidMultiPacketReadInProgress && data[startIndex] == 0x81 { //This branch handles uplink data from the reader (inventory reads, command responses, etc)
            if data[startIndex + 1] == 0x00 {
                let packet = data[(startIndex + 2)...]
                let psi = packet.startIndex
                let packetVer = packet[psi]
                
                //Make sure we have enough bytes to decode the packet, otherwise we've probably got garbage from an incomplete transmission and we will return nil
                guard packet.count > 6 else {
                    return nil
                }
                
                let flags = packet[psi + 1]
                let packetType: UInt16 = UInt16(packet[psi + 3])<<8 + UInt16(packet[psi + 2])
                let packetLength: UInt16 = UInt16(packet[psi + 5])<<8 + UInt16(packet[psi + 4])
                let reserve: UInt16 = UInt16(packet[psi + 7])<<8 + UInt16(packet[psi + 6])
                
                //If the packet length is obviously too long (remember to multiply by 4) bail, we have garbage. Here I'm testing for ~240 bytes, I don't think we should ever get a packet bigger than that in real life, however the Abort packet doesn't have length bytes, so we need to allow Abort packets anyway
                guard packetVer == 0x40 || packetLength <= 80 else {
                    return nil
                }
                
                
                let crcError = flags & 0x01 > 0
                let paddingByteCount = (flags & 0xC0) >> 6
                
                switch(packetVer){
                case 0x03:
                    switch(packetType){
                    case 0x0005: //Inventory Response
                        fallthrough
                    case 0x8005: //Inventory Response
                        if uplinkPacketLength > data.count {
                            rfidMultiPacketReadInProgress = true
                            rfidBytesToGo = Int(uplinkPacketLength) - Int(data.count)
                            rfidPacketUnderConstruction = Data(packet)
                        }
                        else {
                            print("THERE SHOULDN'T BE A FULL INVENTORY RESPONSE PACKET THIS SMALL!!")
                        }
                        //This calculates the total data length for an inventory packet as described on page 52 of the API doc
                        
                        //let dataLength = (Int(packetLength) - 3)*4 - Int(paddingByteCount)
                        //let totalDataLength = 20 + dataLength // The Inventory response packet has 20 + n bytes where n is the length of the PC+EPC+DATA1+CRC16 or PC+EPC+DATA1+DATA2+CRC16 depending on the INV_CFG tag_read setting
                        //Put a copy of packet into rfidPacketUnderConstruction
                        //rfidPacketUnderConstruction = Data(packet)
                        
                        //For inventory response, there is always more than one packet.
                        //rfidMultiPacketReadInProgress = true
                        //rfidBytesToGo = Int(packetLength) - 10 //We have 10 bytes of RFID packet data in the first BLE packet
                    default:
                        break
                    }
                case 0x04:
                    switch(packetType){
                    case 0x0005: //Inventory Response
                        fallthrough
                    case 0x8005: //Inventory Response
                        //Put a copy of packet into rfidPacketUnderConstruction
                        rfidPacketUnderConstruction = Data(packet)
                        
                        //For inventory response, there is always more than one packet.
                        rfidMultiPacketReadInProgress = true
                        rfidBytesToGo = Int(packetLength) - 2 //In the compact mode the packetLength bytes are the payload length, there are 2 bytes (the PC of the first tag) in this first packet.
                    default:
                        break
                    }
                case 0x40: //Abort or Reset response
                    switch(flags){
                    case 0x02:
                        print("RESET COMMAND RESPONSE RECEIVED")
                        break
                    case 0x03:
                        print("ABORT ABORT ABORT!")
                        break
                    default:
                        break
                    }
                    break
                case 0x00: //Firmware info response packet (Mac address, firmware version, etc)
                    fallthrough
                case 0x70:
                    if flags == 0x00{
                        let address = packetType
                        let data = UInt32(reserve) << 16 + UInt32(packetLength)
                        switch(address){
                        case 0x00:
                            let major: UInt8 = UInt8(data >> 24)
                            let minor: UInt8 = UInt8((data >> 12) & 0x7FF)
                            let build: UInt8 = UInt8(data & 0x7FF)
                            break
                        default:
                            break
                        }
                    }
                    break
                case 0x01: //Tag Access Packet
                    if uplinkPacketLength > data.count {
                        rfidMultiPacketReadInProgress = true
                        rfidBytesToGo = Int(uplinkPacketLength) - Int(data.count)
                        rfidPacketUnderConstruction = Data(packet)
                    }
                    else {
                        print("TAG ACCESS PACKET")
                    }
                    break
                case 0x02: //Command Packet Response or other info packets
                    switch(packetType){
                    case 0x0000: //Command Packet Begin
                        fallthrough
                    case 0x8000:
                        if uplinkPacketLength > data.count {
                            rfidMultiPacketReadInProgress = true
                            rfidBytesToGo = Int(uplinkPacketLength) - Int(data.count)
                            rfidPacketUnderConstruction = Data(packet)
                        }
                        else {
                            print("COMMAND BEGIN PACKET")
                        }
                        break
                    case 0x0001: //Command Packet End
                        fallthrough
                    case 0x8001:
                        if uplinkPacketLength > data.count {
                            rfidMultiPacketReadInProgress = true
                            rfidBytesToGo = Int(uplinkPacketLength) - Int(data.count)
                            rfidPacketUnderConstruction = Data(packet)
                        }
                        else {
                            rfidCommandInProgress = false
                            let status = packet[psi + 13] << 8 | packet[psi + 12]
                            let success = status == 0
                            print("COMMAND END PACKET")
                            if executeCompletionUponCommandEnd && completion != nil {
                                executeCompletionUponCommandEnd = false
                                completion!(success)
                                completion = nil
                            }
                        }
                        break
                    case 0x0007: //Antenna Cycle End
                        fallthrough
                    case 0x8007:
                        if uplinkPacketLength > data.count {
                            rfidMultiPacketReadInProgress = true
                            rfidBytesToGo = Int(uplinkPacketLength) - Int(data.count)
                            rfidPacketUnderConstruction = Data(packet)
                        }
                        else {
                            print("ANTENNA CYCLE END")
                        }
                        break
                    default:
                        break
                    }
                    break
                default:
                    break
                }
            }
        }
        else if rfidMultiPacketReadInProgress {
            
            //Append the current data to the rfidPacketUnderConstruction Data object, then reduce the packetsToGo count by 1
            rfidPacketUnderConstruction!.append(data)
            rfidBytesToGo -= data.count
            
            //Once we've read all the packets for this message, set the multiread flag to false
            if rfidBytesToGo <= 0 {
                rfidMultiPacketReadInProgress = false
            }
        }
        
        //If this was a single packet or we're done with a multiPacketRead, decode the packet into a Reading? Maybe need to make a CslRfidResponsePacket class
        if !rfidMultiPacketReadInProgress && rfidPacketUnderConstruction != nil {
            let rfidPacket = rfidPacketUnderConstruction
            rfidPacketUnderConstruction = nil
            
            //TODO - check the checksum and return nil if it doesn't match
            
            //Now decode the Data object into a Reading
            return decodeRfidMultiPacket(packet: rfidPacket!)
        }
        return nil
    }
    
    /**
     decodeRfidPacket decodes complete (or at least what we assume to be complete) RFID data packets after a multi-packet read is completed in decodeRfidData
     parameters: packet - a complete Data packet formed from a multi packet read
     returns: Reading?
     */
    func decodeRfidMultiPacket(packet: Data) -> [Reading]?{

        let psi = packet.startIndex
        let packetVer = packet[psi]
        let flags = packet[psi + 1]
        
        let packetType: UInt16 = UInt16(packet[psi + 3])<<8 + UInt16(packet[psi + 2])
        let packetLength: UInt16 = UInt16(packet[psi + 5])<<8 + UInt16(packet[psi + 4])
        
        //print("PACKET: \(packet.hexEncodedString(separator: " "))")
        switch(packetVer){
        case 0x01:
            switch(packetType){
            case 0x0006:
                let accessCommand = packet[psi + 12]
                let success = (flags & 0x0f) == 0
                var commandName = ""
                
                switch(accessCommand){
                case 0xC2:
                    commandName = "Read"
                    break
                case 0xC3:
                    commandName = "Write"
                    break
                case 0xC4:
                    commandName = "Kill"
                    break
                case 0xC5:
                    commandName = "Lock"
                    break
                case 0x04:
                    commandName = "EAS"
                    break
                default:
                    commandName = "Unknown Command"
                }
                
                if success {
                    print(commandName + " Succeeded!")
                }
                else {
                    print(commandName + " Failed with flags: \(flags) and error code: \(packet[psi + 13])!")
                }
                if packetLength == 3 && packet.count > 20 {
                    let _ = decodeRfidMultiPacket(packet: packet[20...])
                }
                return nil
            default:
                break
            }
        case 0x02:
            switch(packetType){
            case 0x0000: //Command Packet Begin
                fallthrough
            case 0x8000:
                print("COMMAND BEGIN PACKET")
                break
            case 0x0001: //Command Packet End
                fallthrough
            case 0x8001:
                rfidCommandInProgress = false
                let status = packet[psi + 13] << 8 | packet[psi + 12]
                let success = status == 0
                print("COMMAND END PACKET")
                if executeCompletionUponCommandEnd && completion != nil {
                    executeCompletionUponCommandEnd = false
                    completion!(success)
                    completion = nil
                }
                break
            case 0x0007: //Antenna Cycle End
                fallthrough
            case 0x8007:
                print("ANTENNA CYCLE END")
                break
            default:
                break
            }
            break
        case 0x03:
            switch(packetType){
            case 0x0005: // Inventory Response Packet
                fallthrough
            case 0x8005:
                var msCounter: UInt32 = UInt32(packet[psi + 11])<<24
                msCounter = msCounter + (UInt32(packet[psi + 10])<<16)
                msCounter = msCounter + (UInt32(packet[psi + 9])<<8)
                msCounter = msCounter + UInt32(packet[psi + 8]) //Firmware millisecond coutner tag was inventoried
                let wbRssiByte: UInt8 = packet[psi + 12]  //Wideband RSSI - See API doc page 51 for conversion formula
                let nbRssiByte: UInt8 = packet[psi + 13] //Narrowband RSSI - See API doc page 51 for conversion formula
                let phase: UInt8 = packet[psi + 14] //See API doc page 52
                let channelIndex: UInt8 = packet[psi + 15]
                let data1Count: UInt8 = packet[psi + 16]
                let data2Count: UInt8 = packet[psi + 17]
                let port: UInt16 = 0xFFFF & (UInt16(packet[psi + 19])<<8) & UInt16(packet[psi + 18])
                let inventoryData: Data = Data(packet[(psi + 20)...]) //This is a new Data object, we can turn this into an array slice if we absolutely need to, to probably improve performance a tiny bit
                let pc = inventoryData[0...1] //This is an ArraySlice
                let pcAsInt = Int(pc[0]) << 8 + Int(pc[1])
                let epcLength = (pcAsInt >> 11) * 2
                let epcEndIndex = 2 + epcLength - 1
                
                //If the epcEndIndex is <= 2 this is an invalid packet, so return nil
                guard epcEndIndex > 2 && epcEndIndex < inventoryData.endIndex else {
                    return nil
                }
                
                let epc = inventoryData[2...epcEndIndex] //This is an ArraySlice
                //TODO - extract data1 and data2
                let crc16 = Data(inventoryData[inventoryData.endIndex.advanced(by: -2)...])
                //TODO - validate CRC
                
                //Calculate RSSI
                let mantissa = Int(nbRssiByte & 0x07)
                let exponent = Int((nbRssiByte & 0xF8) >> 3)
                let rssi = (20.0 * (log(pow(2.0,Double(exponent)) * (1.0 + Double(mantissa)/8.0))/log(10.0))) - rssiOffset
                
                let reading = Reading()
                reading.type = ReadingType.rfid
                reading.tagid = epc.hexEncodedString().uppercased()
                reading.pc = pc.hexEncodedString().uppercased()
                reading.rssi = Int(rssi)
                return [reading]
            default:
                break
            }
        case 0x04:
            switch(packetType){
            case 0x0005: // Inventory Response Packet
                fallthrough
            case 0x8005:
                var readings:[Reading] = []
                //TODO - compact mode returns multiple EPC and RSSI values per packet, need to loop an build a reading array
                let inventoryData: Data = Data(packet[(psi + 8)...]) //This is a new Data object, we can turn this into an array slice if we absolutely need to, to probably improve performance a tiny bit
                var index = inventoryData.startIndex
                while index + 1 < inventoryData.endIndex{
                    let pc = inventoryData[index...index+1] //This is an ArraySlice
                    let pcAsInt = Int(pc[index]) << 8 + Int(pc[index+1])
                    let epcLength = (pcAsInt >> 11) * 2
                    let epcEndIndex = index + 2 + epcLength - 1
                    let nbRssiIndex = index + 2 + epcLength
                    
                    //If the epcEndIndex is <= 2 or the epcEndIndex is past the end of the packet this is an invalid packet, so return nil
                    guard (epcEndIndex > index+2 && epcEndIndex < inventoryData.endIndex) || (epcLength == 0) else {
                        return nil
                    }
                    
                    let epc = epcLength > 0 ? inventoryData[index+2...epcEndIndex] : Data([])//This is an ArraySlice
                    let nbRssi = inventoryData[nbRssiIndex]
                    let mantissa = Int(nbRssi & 0x07)
                    let exponent = Int((nbRssi & 0xF8) >> 3)
                    let rssi = (20.0 * (log(pow(2.0,Double(exponent)) * (1.0 + Double(mantissa)/8.0))/log(10.0))) - rssiOffset
                    //print("ex:\(exponent), mt:\(mantissa), rs:\(rssi)")
                    let reading = Reading()
                    reading.type = ReadingType.rfid
                    reading.tagid = epc.hexEncodedString().uppercased()
                    reading.pc = pc.hexEncodedString().uppercased()
                    reading.rssi = Int(rssi)
                    
                    readings.append(reading)
                    index = nbRssiIndex + 1
                }
                return readings
            default:
                break
            }
        default:
            break
        }
        return nil
    }
    
    func decodeBarcodeData(data: Data) -> [Reading]?{
        let startIndex = data.startIndex //Need this because the ArraySlice still has to be indexed with the old index, it does not start at 0
        guard barcodeMultiPacketReadInProgress || data[startIndex] == 0x90 || data[startIndex] == 0x91 else {
            return nil
        }

        //If we're not reading in a multipacket read, and the first byte of the payload is 0x90, we've got a barcode status packet
        if !barcodeMultiPacketReadInProgress && data[startIndex] == 0x90{
            if data[startIndex + 1] == 0x00 && data[startIndex + 2] == 0x00 {
                print("Barcode On")
                barcodeOn = true
            }
            else if data[startIndex + 1] == 0x01 && data[startIndex + 2] == 0x00 {
                print("Barcode Off")
                barcodeOn = false
            }
            else if data[startIndex + 1] == 0x02 && data[startIndex + 2] == 0x00 {
                print("Barcode Trigger Success")
            }
        }
        //This branch should execute for the first packet of a barcode read, if only one packet, this is the only branch that runs
        else if !barcodeMultiPacketReadInProgress && data[startIndex] == 0x91 {
            if data[startIndex + 1] == 0x00 {
                if data.count > 3 && data.last != 0x0D { barcodeMultiPacketReadInProgress = true }
                else { barcodeMultiPacketReadInProgress = false }
                
                
                //Convert the Data object to a String
                var bcString = String(data: data[(startIndex+2)...], encoding: .utf8)
                if bcString != nil {
                    if bcString == "" || bcString!.contains("\u{06}") {
                        barcodeMultiPacketReadInProgress = false
                    }
                    else {
                        //Create a reading object
                        readingUnderConstruction = Reading()
                        readingUnderConstruction!.type = .barcode
                        //Trim and append the barcode string
                        bcString = bcString?.trim(nil)
                        readingUnderConstruction?.assetNumber.append(bcString!)
                    }
                }
            }
            else if data[startIndex + 1] == 0x01 {
                //TODO turn off barcode reader here?
            }
        }
        //For multi-packet barcodes, the following packets only contain data, no header
        else {
            //Check if this is the final packet in the series, will terminate with "\r"
            if data.last == 0x0D { barcodeMultiPacketReadInProgress = false }
            
            //Convert the Data object to a String
            var bcString = String(data: data, encoding: .utf8)
            if bcString != nil {
                bcString = bcString?.trim(nil)
                readingUnderConstruction?.assetNumber.append(bcString!)
            }
        }
        
        //Once we're done with this reading we can return it, otherwise return nil until we've read all the packets
        if !barcodeMultiPacketReadInProgress && readingUnderConstruction != nil{
            let reading = readingUnderConstruction!
            readingUnderConstruction = nil
            DispatchQueue.main.async {
                self.abortBarcode() //Once we've read a tag, turn off the barcode engine.
            }
            return [reading]
        }
        else {
            return nil
        }
    }
    
    //Notification type messages include battery and trigger status
    func decodeNotificationData(data: Data){
        let startIndex = data.startIndex //Need this because the ArraySlice still has to be indexed with the old index, it does not start at 0
        guard data.count > 0 && (data[startIndex] == 0xA0 || data[startIndex] == 0xA1) else {
            return
        }
        if data[startIndex] == 0xA0 {
            if data[startIndex + 1] == 0x00 { //This is the battery level notification
                let valueIndex = startIndex + 2
                
                let batteryActualV = data.scanValue(at: valueIndex, endianess: Data.Endianness.BigEndian) as UInt16
                print("Battery level is \(batteryActualV)mV")
                self.batteryStatus = min(100, Int32(100*(Double(batteryActualV)-batteryMinV)/(batteryMaxV - batteryMinV))) //calculate and set the battery status as a percentage, don't go over 100%
                NotificationCenter.default.post(name: Notification.Name(rawValue: batteryStatusNotification), object: nil)
                updateVersionString()
            }
            else if data[startIndex + 1] == 0x01 {
            }
        }
        else if data[startIndex] == 0xA1 {
            if data[startIndex + 1] == 0x01 {
                print("ERROR \(data.hexEncodedString())")
            }
            else if data[startIndex + 1] == 0x02 {
                //Trigger pushed
                print("Trigger pushed")
                buttonPressed = true
                buttonPressCount += 1
                
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(doublePressDelay*Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)){
                    if self.buttonPressed == true{
                        if self.buttonPressCount == 1{
                            if self.performSingleButtonPressAction == true{
                                self.buttonPressSingle()
                            }
                            if self.notifyOnButtonPress == true{
                                NotificationCenter.default.post(name: Notification.Name(rawValue: readerButtonPressedNotification), object: Int(ReaderButtonStates.single.rawValue))
                            }
                        }
                        else if self.buttonPressCount == 2{
                            if self.performDoubleButtonPressAction == true {
                                self.buttonPressDouble()
                            }
                            if self.notifyOnButtonPress == true{
                                NotificationCenter.default.post(name: Notification.Name(rawValue: readerButtonPressedNotification), object: Int(ReaderButtonStates.double.rawValue))
                            }
                        }
                    }
                    self.buttonPressCount = 0
                }
            }
            else if data[startIndex + 1] == 0x03 {
                //Trigger released
                print("Trigger released")
                buttonPressed = false
                
                //Turn off the barcode reader once the trigger is released
                if barcodeOn { abortBarcode() }
                else if readerOn { stopContinuousInventory() }
                
                if buttonPressCount == 0 {
                    abort()
                    if self.notifyOnButtonPress == true{
                        NotificationCenter.default.post(name: Notification.Name(rawValue: readerButtonPressedNotification), object: Int(ReaderButtonStates.off.rawValue))
                    }
                }
            }
        }
    }
    
    func decodeUplinkData(data: Data) {
        //print(data.hexEncodedString(separator: " "))
        // Data packet is [0xA7, 0xB3, <payload length>, <device/packet type>, 0x82, 0x9E, <crc1>, <crc2>, <payload>...]
        // let payloadLength = data[2]
        let payload: Data? = data.count > 8 ? data[8...] : nil
        
        let packetType: UInt8
        if barcodeMultiPacketReadInProgress || rfidMultiPacketReadInProgress { packetType = lastPacketType }
        else if data.count > 8 { // to be a valid non-multiread packet, it has to have more than 8 bytes
            uplinkPacketLength = data[2]
            packetType = data[3]
        }
        else {
            print("SMALL PACKET \(data.hexEncodedString(separator: " "))")
            return
        }
//        let upDownLink = data[5]
//        let crc1 = data[6]
//        let crc2 = data[7]

        //Set the lastPacketType to use in multi-packet reads
        lastPacketType = packetType

        var readings: [Reading]? = nil
        //print("Received \(data.hexEncodedString(separator: " ")), rfidMultiPacketReadInProgress: \(rfidMultiPacketReadInProgress)")
        
        switch(packetType){
        case CslCommandType.rfid.rawValue:
            if !rfidMultiPacketReadInProgress {
                inventorySequenceNumber = UInt8(data[4])
                readings = decodeRfidData(data: payload!)
            }
            else {
                readings = decodeRfidData(data: data) //For multi-packet reads, the 2nd, 3rd, Nth packets only contain data, no header
            }
            break
        case CslCommandType.barcode.rawValue:
            if !barcodeMultiPacketReadInProgress {
                readings = decodeBarcodeData(data: payload!)
            }
            else {
                readings = decodeBarcodeData(data: data) //For multi-packet reads, the 2nd, 3rd, Nth packets only contain data, no header
            }
            break
        case CslCommandType.bluetooth.rawValue:
            break
        case CslCommandType.silab.rawValue:
            break
        case CslCommandType.notify.rawValue:
            decodeNotificationData(data: payload!)
            break
        default:
            break
        }
        
        guard readings != nil else {
            return
        }
        
        //Post a notification with the reading
        if packetType != CslCommandType.silab.rawValue && packetType != CslCommandType.bluetooth.rawValue && readings != nil {
            if readOneMode { //If we're in read-one mode, stop reading tags after we read one successfully
                readOneMode = false
                stopContinuousInventory()
            }
            for reading in readings! {
                //print(reading.tagid)
                NotificationCenter.default.post(name: Notification.Name(rawValue: newReadingNotification), object: reading)
            }
            
        }
    }
    
    //Turn the RFID module on or off. The module must be turned on before commands can be sent to it, it is off by default.
    func cslRfidModulePower(on: Bool){
        if on == true {
            sendRfidCommandDownlink(data: createCommandPacket(data: RFID_POWER_ON.toData(), commandType: .rfid)) //RFID Power on
        }
        else {
            sendRfidCommandDownlink(data: createCommandPacket(data: RFID_POWER_OFF.toData(), commandType: .rfid)) //RFID Power off
        }
    }
    
    //Turn the barcode module on or off. The module must be turned on before commands can be sent to it, it is off by default.
    func cslBarcodeModulePower(on: Bool){
        if on == true {
            sendDownlink(data: createCommandPacket(data: BARCODE_POWER_ON.toData(), commandType: .barcode)) //Barcode Power on
        }
        else {
            sendDownlink(data: createCommandPacket(data: BARCODE_POWER_OFF.toData(), commandType: .barcode)) //Barcode Power off
        }
    }
    
    func cslBarcodeModuleFactoryReset(){
        //sendDownlink(data: createCommandPacket(data: BARCODE_POWER_ON.toData(), commandType: .barcode)) //Barcode Power on
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + Data(BARCODE_CMD_SYS_MODE_ENTER), commandType: .barcode))
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + Data(BARCODE_CMD_SCAN_CYCLE_TIME_3000), commandType: .barcode))
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + Data(BARCODE_CMD_PERM_TRIGGER_MODE), commandType: .barcode))
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + Data(BARCODE_CMD_SYS_MODE_EXIT), commandType: .barcode))
        //sendDownlink(data: createCommandPacket(data: BARCODE_POWER_OFF.toData(), commandType: .barcode)) //Barcode Power off
    }
    
    
    //This function will be called by local functions only after they have decoded some updated battery, version, etc data from the reader
    private func updateVersionString() {
        self.versionString = String(format:"Manufacturer: CSL\nSerial Number: %@\nFirmware: %@\nBattery Level: %d%%",
                                    self.serialNumber,
                                    self.firmwareVersion,
                                    self.batteryStatus!)
        print("Connected reader is \(self.versionString)")
        NotificationCenter.default.post(name: Notification.Name(rawValue: readerVersionStringUpdatedNotification), object: self.versionString)
    }
    
    private func rfidAbort(){

        //ABORT, ABORT, ABORT!
        print("Enqueuing ABORT, ABORT, ABORT!")
        var command = RFID_COMMAND.toData()
        command.append(contentsOf: [0x40, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) //RFID module abort
        sendRfidCommandDownlink(data: createCommandPacket(data: command, commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: command, commandType: .rfid))
        readerOn = false
    }
    
    // Set Inventory Config
    private func setInventoryConfig(tagDelay: UInt8, qtMode: Bool, crcErrRead: Bool, tagRead: UInt8, disableInventory: Bool, tagSelect: Bool, stopAfter matchRep: UInt8, inventoryAlgo: UInt32) {
        //Enable compact mode by:
        //Setting Tag Delay to 0
        //Setting bit 26 of INV_CFG to 1
        
        var invConfig: UInt32 = UInt32(compactMode ? 1 : 0) << 26
        invConfig = invConfig | (UInt32(compactMode ? 0 : tagDelay) << 20) | (UInt32(qtMode ? 1 : 0) << 19)
        invConfig = invConfig | (UInt32(crcErrRead ? 1 : 0) << 18) | (UInt32(tagRead) << 16)
        invConfig = invConfig | (UInt32(disableInventory ? 1 : 0) << 15) | (UInt32(tagSelect ? 1 : 0) << 14)
        invConfig = invConfig | (UInt32(matchRep) << 6) | min(inventoryAlgo,3)
        
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_CFG, data: invConfig), commandType: .rfid))
    }
    
    // Set Inventory Algorithm Parameters
    private func setInventoryAlgoParams(inventoryAlgo: UInt32, startQ: UInt32, minQ: UInt32, maxQ: UInt32, retryCount: UInt32, threshholdMult: UInt32, toggleTarget: Bool, runTillZero: Bool) {
        let param0: UInt32 = inventoryAlgo == FIXED_Q ? min(startQ,15) : (min(startQ,15) | (min(maxQ,15) << 4) | (min(minQ,15) << 8) | (min(threshholdMult,63) << 12))
        let param1: UInt32 = retryCount
        let param2: UInt32 = (toggleTarget ? 1 : 0) | ((runTillZero ? 1 : 0) << 1)
        //let param3: UInt32 = 0
        
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_SEL, data: min(inventoryAlgo,3)), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_0, data: param0), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_1, data: param1), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_2, data: param2), commandType: .rfid))
        //sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_3, data: param3), commandType: .rfid))
    }
    
    //Set tag filter / epc mask
    private func setTagFilter(tagFilter: String = ""){
        
        //Set TAGMSK_DESC_SEL to 0 ? This is the power on default, and shouldn't have changed.
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_DESC_SEL, data: 0), commandType: .rfid))
        
        //TODO - finish setting tag mask registers
        if tagFilter != "" && tagFilter != lastTagFilter {
            let paddedEpcWithPc = RFIDUtilities.epcStringToPaddedEpcWithPc(tagFilter)
            
            //Set TAGMSK_DESC_CFG
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_DESC_CFG, data: TAGMSK_ENABLE|TAGMSK_TARGET_SL), commandType: .rfid))
            //Set TAGMSK_BANK to EPC
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_BANK, data: MEMORY_BANK_EPC), commandType: .rfid))
            //Set TAGMSK_PTR to 0x20 - that skips the PC and CRC
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_PTR, data: 0x20), commandType: .rfid))
            //Set TAGMSK_LEN to the number of words in the tag filter
            let byteCount: UInt32 = UInt32(paddedEpcWithPc.epc.count/2)
            let bitCount: UInt32 = UInt32(byteCount * 8) // two characters = 1 byte, byte count * 8 = bitCount
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_LEN, data: bitCount), commandType: .rfid))
            //Set the TAGMSK registers to the PC and EPC
            let registerCount = ((byteCount - 1) / 4) + 1 //The CSL108 uses the R1000, which has 32-bit (4-byte) registers
            let epc = paddedEpcWithPc.epc
            
            //Set the TAGMSK registers to the specified mask. Note that the mask needs to be exact.
            //000DEADBEEF1 does not match 0000000DEADBEEF1 and I don't think there is a way to do that
            for regIndex in 0..<registerCount {
                let startIndex = epc.index(epc.startIndex, offsetBy: Int(regIndex*8))
                let endIndex = epc.index(epc.startIndex, offsetBy: min(Int(regIndex*8 + 8), Int(epc.endIndex.encodedOffset)))
                var regString: String = String(epc[startIndex..<endIndex])
                if regString.count < 8 {
                    regString = regString.rightPad("0", length: 8)
                }
                let regData: UInt32 = UInt32(regString, radix: 16)!
                sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_0_3 + UInt16(regIndex), data: regData, dataReversed: false), commandType: .rfid))
            }
        }
        else if lastTagFilter != tagFilter {
            //Set TAGMSK_DESC_CFG
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_DESC_CFG, data: TAGMSK_DISABLE), commandType: .rfid))
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_PTR, data: 0), commandType: .rfid))
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_LEN, data: 0), commandType: .rfid))
            for regIndex:UInt32 in 0..<8{
                sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_0_3 + UInt16(regIndex), data: 0), commandType: .rfid))
            }
        }
        lastTagFilter = tagFilter
    }
    
    // MARK: - RFIDReaderProtocol functions
    //Connect should get a Peripheral that is advertising with service ID 9800
    func connect(anyAccessory: Any?) {
        // If an object was passed in, make sure it is a CBPeripheral before assigning it to bleAccessory
        if anyAccessory != nil && anyAccessory is CBPeripheral {
            bleAccessory = anyAccessory as? CBPeripheral
        }
        
        // Don't proceed if we don't have a valid BLE peripheral
        guard bleAccessory != nil else {
            return
        }

        //Set the CBPeripheralDelegate to self
        bleAccessory?.delegate = self
        
        connectionReady = false
        rfidConnected = false
        connecting = true
        
        DispatchQueue.main.async{
            NotificationCenter.default.post(name: Notification.Name(rawValue: readerConnectingNotification),object: UIAlertMessage(message: "Attempting connection to the CSL reader.",title:"Connecting!"))
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(CSLReader.bleAccessoryConnected(notification:)), name: Notification.Name(rawValue: bleReaderConnected), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(CSLReader.bleAccessoryDisconnected(notification:)), name: Notification.Name(rawValue: bleReaderDisconnected), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(CSLReader.bleAccessoryReady(notification:)), name: Notification.Name(rawValue: bleReaderReady), object: nil)
        
        // Tell the central manger to connec to this accessory
        appDelegate?.cbcm?.connect(bleAccessory!, options: nil)
        
    }
    
    func resetConnectedDevice(completion: ((Bool) -> Void)?) {
  
        //Soft reset the reader
        print("Enqueuing RESET")
        
        cslBarcodeModuleFactoryReset() //This seems to be a good place to put this and it doesn't bork anything here.
        
        var command = RFID_COMMAND.toData()
        command.append(contentsOf: [0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) //RFID module reset
        sendRfidCommandDownlink(data: createCommandPacket(data: command, commandType: .rfid))
        
        readerOn = false
        seekerMode = false
        willWriteTag = false
        linkProfile = PROFILE_UNKNOWN
        tagToSeek = ""
        
        if completion != nil {
            completion!(true)
        }
    }
    
    func updateBatteryStatus() {
        let packet = createCommandPacket(data: BATTERY_VOLTAGE.toData(), commandType: .notify)
        sendDownlink(data: packet)
    }
    
    // This will be called by external viewControllers and should cause the reader class to go out and fetch updated info and then send the readerVersionStringUpdatedNotification
    func updateVersionInfo() {
        guard connectionReady else {
            return
        }
        let packet = createCommandPacket(data: createRegRequestData(write: false, address: FIRMWARE_VER, data: 0x0), commandType: .notify)  //Read the RFID firmware version
        sendDownlink(data: packet)
        updateBatteryStatus()
    }
    
    func setRfidPower(power: Int32, completion: ((Bool) -> Void)?) {
        outputPower = limitPower(power*10)
        print("CSL SETTING OUTPUT POWER TO \(outputPower)")
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: ANT_PORT_POWER, data: UInt32(outputPower)), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: ANT_PORT_DWELL, data: UInt32(0)), commandType: .rfid))
        if completion != nil {
            completion!(true)
        }
    }
    
    func getRfidPower() -> Int32 {
        return outputPower/10
    }
    
    func limitPower(_ value : Int32) -> Int32{
        if value < minPower {
            return minPower
        }
        if value > maxPower {
            return maxPower
        }
        return value
    }
    
    func getMinRfidPower() -> Int32 {
        return minPower
    }
    
    func getMaxRfidPower() -> Int32 {
        return maxPower
    }
    
    func writeEPC(epcData: String, tagFilter: String, accessPassword: String, completion: ((Bool) -> Void)?) {
        //Get the padded EPC and updated PC
        let paddedEpcAndPc = RFIDUtilities.epcStringToPaddedEpcWithPc(epcData)
        
        //Burn the tag
        self.burnTag(newPC: paddedEpcAndPc.pc, newEPC: paddedEpcAndPc.epc, startAddress: 1, tagFilter: tagFilter, accessPassword: accessPassword, memoryBank: Gen2MemoryBank.epc ,completion: completion)
    }
    
    func burnTag(newPC: String, newEPC: String, startAddress: Int32, tagFilter: String = "", accessPassword: String, memoryBank: Gen2MemoryBank, completion: ((Bool) -> Void)?) {
        
        //Prevent burning a blank tag
        guard newEPC != "" else {
            if completion != nil {
                completion!(false)
            }
            return
        }
        
        //Set Inventory Parameters
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: ANT_CYCLES, data: 0x01), commandType: .rfid))
        let queryCfgValue: UInt32 = tagFilter != "" ? 0x0180 : 0x0
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: QUERY_CFG, data: queryCfgValue), commandType: .rfid))
        
        //Set Inventory Algorithm
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_SEL, data: 0), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_0, data: 0), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_ALG_PARM_2, data: 0), commandType: .rfid))
        
        //Set the tag mask registers
        if tagFilter != ""  {
            let paddedEpcWithPc = RFIDUtilities.epcStringToPaddedEpcWithPc(tagFilter)
            
            //Set TAGMSK_DESC_CFG
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_DESC_CFG, data: TAGMSK_ENABLE|TAGMSK_TARGET_SL), commandType: .rfid))
            //Set TAGMSK_BANK to EPC
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_BANK, data: MEMORY_BANK_EPC), commandType: .rfid))
            //Set TAGMSK_PTR to 0x20 - that skips the PC and CRC
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_PTR, data: 0x20), commandType: .rfid))
            //Set TAGMSK_LEN to the number of words in the tag filter
            let byteCount: UInt32 = UInt32(paddedEpcWithPc.epc.count/2)
            let bitCount: UInt32 = UInt32(byteCount * 8) // two characters = 1 byte, byte count * 8 = bitCount
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_LEN, data: bitCount), commandType: .rfid))
            //Set the TAGMSK registers to the PC and EPC
            let registerCount = ((byteCount - 1) / 4) + 1 //The CSL108 uses the R1000, which has 32-bit (4-byte) registers
            let epc = paddedEpcWithPc.epc
            
            //Set the TAGMSK registers to the specified mask. Note that the mask needs to be exact.
            //000DEADBEEF1 does not match 0000000DEADBEEF1 and I don't think there is a way to do that
            for regIndex in 0..<registerCount {
                let startIndex = epc.index(epc.startIndex, offsetBy: Int(regIndex*8))
                let endIndex = epc.index(epc.startIndex, offsetBy: min(Int(regIndex*8 + 8), Int(epc.endIndex.encodedOffset)))
                var regString: String = String(epc[startIndex..<endIndex])
                if regString.count < 8 {
                    regString = regString.rightPad("0", length: 8)
                }
                let regData: UInt32 = UInt32(regString, radix: 16)!
                sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_0_3 + UInt16(regIndex), data: regData, dataReversed: false), commandType: .rfid))
            }
        }
        else {
            //Set TAGMSK_DESC_CFG
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGMSK_DESC_CFG, data: TAGMSK_DISABLE), commandType: .rfid))
        }
        //Set INV_CFG
        let invCfgVal: UInt32 = tagFilter != "" ? 0x4040 : 0x40 //If there is a tagFilter, enable Select before write.
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: INV_CFG, data: invCfgVal), commandType: .rfid))
        
        //Start writing tag EPC
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_DESC_CFG, data: 0x0f), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_BANK, data: MEMORY_BANK_EPC), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_PTR, data: 0), commandType: .rfid))
        
        let writeString = newPC+newEPC
        let wordCount: UInt32 = UInt32(writeString.count / 4) //Two characters per byte in the string, 4 per word.
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_CNT, data: wordCount), commandType: .rfid))
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_ACCPWD, data: 0), commandType: .rfid))
        
        let registerCount = wordCount
        let offsetStart: UInt32 = 1 //Offset 1 word to skip the CRC and go to the PC
        for regIndex in 0..<registerCount {
            let startIndex = writeString.index(writeString.startIndex, offsetBy: Int(regIndex*4))
            let endIndex = writeString.index(writeString.startIndex, offsetBy: min(Int(regIndex*4 + 4), Int(writeString.endIndex.encodedOffset)))
            var regString: String = String(writeString[startIndex..<endIndex])
            //Reverse the bytes in regString, while the PC and EPC are read from the module in the correct order, they must be reversed in the register when writing
            regString = Data(UInt16(regString, radix:16)!.toData().reversed()).hexEncodedString().uppercased()
      
            //Calculate the "offset" value used to write this word to the correct part of the EPC memory
            let offsetString = String((offsetStart + regIndex), radix: 16).leftPad("0", length: 2).rightPad("0", length: 4)
            regString += offsetString
            let regData: UInt32 = UInt32(regString, radix: 16)!
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGWRDAT_0 + UInt16(regIndex), data: regData, dataReversed: false), commandType: .rfid))
        }
        
        //Tell the rifd module to execute a write command with all the parameters we just set up
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: HST_CMD, data: WRITE), commandType: .rfid))
        self.executeCompletionUponCommandEnd = true
        self.completion = completion
    }

    
    func seekTagWithInventoryCommand(tagFilter: String) {
        if tagFilter != "" {
            seekerMode = true
            outputPower = maxPower
            tagToSeek = RFIDUtilities.epcStringToPaddedEpcWithPc(tagFilter).epc
        }
        else {
            seekerMode = false
            tagToSeek = ""
        }
    }
    
    func readTagWithInventoryCommand(tagFilter: String, includeRSSI: Bool) {
        readOneMode = true
        willWriteTag = false
        seekerMode = false
        //Set tag filter
        if tagFilter != "" {
            tagToSeek = RFIDUtilities.epcStringToPaddedEpcWithPc(tagFilter).epc
        }
        else {
            tagToSeek = ""
        }
        //setTagFilter(tagFilter: tagFilter)
        //setRfidParameters(session: 0, target: "A", qAlgorithm: "fixed", q: 0)
        
        //Set TAGACC_DESC_CFG, disable verify and set to 0 retries
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: TAGACC_DESC_CFG, data: 0), commandType: .rfid))

        //Start reading tag
        startContinuousInventory()
    }
    
    func readTag(tagFilter: String?, accessPassword: String?, memoryBank: Gen2MemoryBank) {
        //Intentionally blank
    }
    
    func readBarcode() {
        //cslBarcodeModulePower(on: true)
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + BARCODE_CMD_START_CONTINUE_MODE.toData(), commandType: .barcode))
    }
    
    func setRfidParameters(session: Int = 0, target: String = "A", qAlgorithm: String = "dynamic", q: Int32 = 7) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3){
            self.displayingAlertMessage = true
            NotificationCenter.default.post(name: Notification.Name(rawValue: readerConnectingNotification),object: UIAlertMessage(message: "Optimizing CSL read parameters",title:"Making magic happen!"))
        }

        //Set link profile - use profile 1 for longest range
        if linkProfile != PROFILE_LONGEST_RANGE {
            linkProfile = PROFILE_LONGEST_RANGE
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: CURRENT_PROFILE, data: linkProfile), commandType: .rfid))
            sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: HST_CMD, data: CHANGE_LINK_PROFILE), commandType: .rfid))
        }
        //Set antenna cycles to continuous or 1 depending readOneMode
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: ANT_CYCLES, data: readOneMode ? 0x1 : 0xFFFF), commandType: .rfid))
        
        //Set query config - session, target, select flag
        let targetBits: UInt32 = (target == "B" ? UInt32(0x01) : UInt32(0x0)) << 4
        let sessionBits: UInt32 = UInt32(session) << 5
        let selectBits: UInt32 = (((tagToSeek != "" || seekerMode)) ? 0x03 : 0x0) << 7
        let queryConfig: UInt32 = 0 | targetBits | sessionBits | selectBits
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: QUERY_CFG, data: queryConfig), commandType: .rfid))
        
        //Set Inventory algorithm - Q n such
        compactMode = true//!readOneMode
        inventoryAlgorithm = qAlgorithm == "dynamic" ? DYNAMIC_Q : FIXED_Q
        let runTillZero: Bool = false //inventoryAlgorithm == DYNAMIC_Q ? false : true
        setInventoryConfig(tagDelay: TAG_DELAY,
                           qtMode: false,
                           crcErrRead: false,
                           tagRead: TAG_READ_NO_BANKS,
                           disableInventory: false,
                           tagSelect: seekerMode || willWriteTag, //need to enable for write
                           stopAfter: willWriteTag || readOneMode ? 1 : 0,
                           inventoryAlgo: inventoryAlgorithm)
        setInventoryAlgoParams(inventoryAlgo: inventoryAlgorithm, startQ: UInt32(q), minQ: 0, maxQ: 15, retryCount: 0, threshholdMult: 2, toggleTarget: tagToSeek != "" && !willWriteTag, runTillZero: runTillZero)
    }
    

    
    func outputPowerFromSliderValue(power: Float) -> Int32 {
        let range : Int32 = maxPower - minPower
        return Int32(power * Float(range) + Float(minPower) + 0.5)/10;
    }
    
    func sliderValueFromOutputPower(power: Int32) -> Float {
        let range : Int32 = maxPower - minPower
        let pwr = Float(power)*10.0
        return Float((pwr - Float(minPower) - 0.5) / Float(range));
    }
    
    func disconnect(permanant: Bool, completion: (() -> Void)?) {
        //Tell the central manger to disconnect
        if isConnected() {
            cslBarcodeModulePower(on: false)
            cslRfidModulePower(on: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.appDelegate?.cbcm?.cancelPeripheralConnection(self.bleAccessory!)
            DispatchQueue.main.async {
                if completion != nil {
                    completion!()
                }
            }
        }
    }
    
    func isConnected() -> Bool {
        return connectionReady
    }
    
    func setAlertEnabled(enabled: Bool) {
        //Intentionally blank
    }
    
    func enableTriggerDefaults(singlePress: Bool, doublePress: Bool, reporting: Bool) {
        //Single Press
        performSingleButtonPressAction = singlePress
        
        //Double Press
        performDoubleButtonPressAction = doublePress
        
        //Reporting/Notification
        notifyOnButtonPress = reporting
    }
    
    func resetTriggerToDefaults() {
        notifyOnButtonPress = false
        performDoubleButtonPressAction = true
        performSingleButtonPressAction = true
    }
    
    func buttonPressSingle() {
        startContinuousInventory()
    }
    
    func buttonPressDouble() {
        readBarcode()
    }
    
    func startContinuousInventory() {
        compactMode = true
        willWriteTag = false
        if seekerMode || readOneMode {
            setTagFilter(tagFilter: tagToSeek)
        }
        else {
            setTagFilter()
        }
        
        readerOn = true //Probably will move this to a response decoder area
        sendRfidCommandDownlink(data: createCommandPacket(data: createRegRequestData(write: true, address: HST_CMD, data: START_INVENTORY), commandType: .rfid)) //RFID Start Inventory HST_CMD
    }
    
    func stopContinuousInventory() {
        rfidAbort()
        compactMode = false
//        setInventoryConfig(tagDelay: TAG_DELAY, qtMode: false, crcErrRead: false, tagRead: TAG_READ_NO_BANKS, disableInventory: false, tagSelect: false, stopAfter: 0, inventoryAlgo: inventoryAlgorithm)
    }
    
    func abort() {
        if readerOn == true{
            stopContinuousInventory()
        }
        if barcodeOn == true {
            abortBarcode()
        }
    }
    
    func abortBarcode(){
        //cslBarcodeModulePower(on: false)
        sendDownlink(data: createCommandPacket(data: BARCODE_RAW_DATA.toData() + BARCODE_CMD_STOP_CONTINUE_MODE.toData(), commandType: .barcode))
    }
    
    // MARK: - CBPeripheralDelegate functions
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        
    }
    
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            print(error as Any)
            return
        }
        
        for service in peripheral.services! {
            print(service)
            bleAccessory?.discoverCharacteristics(nil, for: service)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        
    }
    
    public func  peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics! {
            if characteristic.uuid == uplinkUuid {
                print("Enabling notifications on uplink characteristic")
                self.uplinkCharacteristic = characteristic
            }
            else if characteristic.uuid == downlinkUuid {
                self.downlinkCharacteristic = characteristic
            }
            
            // If both uplink and downlink characteristics are ready, set connection ready and send a Notification event
            if !connectionReady && uplinkCharacteristic != nil && downlinkCharacteristic != nil {
                connectionReady = true
                rfidConnected = true
                
                bleAccessory?.setNotifyValue(true, for: characteristic) //Enable notifications for the Uplink characteristic
                
                rfidAbort() //Make the reader stop reading
                
                NotificationCenter.default.post(name: Notification.Name(rawValue: readerConnectionNotification), object: nil)
                NotificationCenter.default.post(name: Notification.Name(rawValue: bleReaderReady), object: peripheral)
                
            }
            
            peripheral.readValue(for: characteristic)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        
    }
    
    //This will get called whenever the CBPeripheral recevies an updated value - we are listening for Notifications on Service 9800, Characteristic 9901
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        //This is where we should get all traffic from the handheld device
        let newValue = characteristic.value //Quick, grab the characteristics new value
        guard newValue != nil else {
            return
        }
        if characteristic.uuid == uplinkUuid {
            uplinkSerialDispatchQueue.sync { //This should keep packets in the correct order, but append them via a background thread
                self.uplinkDataSemaphore.wait()
                self.uplinkData.append(newValue!)
                self.uplinkDataSemaphore.signal()
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
//        for descriptor in characteristic.descriptors! {
//            print(descriptor)
//            print("Description: \(descriptor)" as Any)
//            print("Value: \(descriptor.value)" as Any)
//        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        print("Updated notification state for \(characteristic) on \(peripheral) is notifying: \(characteristic.isNotifying)")
    }
    
    // MARK: - Notification functions
    @objc func bleAccessoryConnected(notification: Notification) {
        let connectedAccessory =  notification.object as? CBPeripheral
        guard connectedAccessory != nil else {
            return
        }
        
        if connectedAccessory?.identifier == bleAccessory?.identifier {
            connecting = false
            //Discover device services - we need to make sure the device has 9900 and 9901
            bleAccessory?.discoverServices([CBUUID(string: "9800")])
        }
    }
    
    @objc func bleAccessoryDisconnected(notification: Notification) {
        let connectedAccessory =  notification.object as? CBPeripheral
        guard connectedAccessory != nil else {
            return
        }
        
        if connectedAccessory?.identifier == bleAccessory?.identifier {
            connecting = false
            rfidConnected = false
            connectionReady = false
            uplinkDecoderThreadShouldRun = false
            NotificationCenter.default.post(name: Notification.Name(rawValue: readerConnectionNotification), object: nil)
        }
    }
    
    //Call all init functions from here, the connection to the reader has been established and service characteristics discovered
    @objc func bleAccessoryReady(notification: Notification) {
        let connectedAccessory =  notification.object as? CBPeripheral
        guard connectedAccessory != nil else {
            return
        }
        
        if connectedAccessory == bleAccessory {
            cslRfidModulePower(on: true)
            cslBarcodeModulePower(on: true)
            updateVersionInfo()
        }
    }
}
