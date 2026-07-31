import Testing
@testable import DroidMate

@Test func smokeProtocolConstants() {
    #expect(StreamId.control == 0x0000)
    #expect(StreamId.files == 0x0003)
    #expect(MsgType.hello == 0x0001)
    #expect(MsgType.pong == 0x0011)
}
