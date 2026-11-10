import Foundation
import RemoraCore
import Testing

@Test func connectionsWithoutResolutionDecodeAsFitToWindow() throws {
    let json = #"{"id":"A0BC1765-1000-4000-8000-000000000001","name":"Legacy","host":"example.test","port":3389,"username":"user","kind":"rdp"}"#
    let connection = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
    #expect(connection.resolution == .fitToWindow)
}

@Test func fixedResolutionRequiresBoundedSidesAndEvenWidth() throws {
    for (width, height, valid) in [
        (200, 200, true), (8192, 8192, true), (1600, 901, true),
        (199, 720, false), (1280, 199, false), (8194, 720, false),
        (1280, 8193, false), (1281, 720, false),
    ] {
        let resolution = ConnectionResolution.fixed(width: width, height: height)
        #expect(resolution.isValid == valid)
        if valid {
            let encoded = try JSONEncoder().encode(resolution)
            #expect(try JSONDecoder().decode(ConnectionResolution.self, from: encoded) == resolution)
        }
    }
}
