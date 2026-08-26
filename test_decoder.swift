import Foundation
import VideoToolbox

let spsHex = "6764001facb4042044f3cb2905060506d0a135"
let ppsHex = "68ee06f2c0"

func data(fromHex hex: String) -> Data {
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        if nextIndex <= hex.endIndex {
            let byteString = String(hex[index..<nextIndex])
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            }
        }
        index = nextIndex
    }
    return data
}

let sps = data(fromHex: spsHex)
let pps = data(fromHex: ppsHex)

sps.withUnsafeBytes { spsBuffer in
    pps.withUnsafeBytes { ppsBuffer in
        let spsPtr = spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ppsPtr = ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        
        let parameterSetPointers = [spsPtr, ppsPtr]
        let parameterSetSizes = [sps.count, pps.count]
        
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
        
        print("Status: \(status)")
        if status == noErr {
            print("Success!")
        }
    }
}
