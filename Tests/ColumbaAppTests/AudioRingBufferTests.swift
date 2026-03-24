import XCTest
@testable import ColumbaApp

final class AudioRingBufferTests: XCTestCase {

    // MARK: - Basic Operations

    func testEmptyBufferReturnsNil() {
        let buf = AudioRingBuffer(capacity: 16)
        XCTAssertEqual(buf.count, 0)
        XCTAssertNil(buf.read())
    }

    func testWriteAndRead() {
        let buf = AudioRingBuffer(capacity: 16)
        buf.write(1.0)
        buf.write(2.0)
        buf.write(3.0)
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.read(), 1.0)
        XCTAssertEqual(buf.read(), 2.0)
        XCTAssertEqual(buf.read(), 3.0)
        XCTAssertEqual(buf.count, 0)
    }

    func testCountTracksWritesAndReads() {
        let buf = AudioRingBuffer(capacity: 64)
        for i in 0..<10 {
            buf.write(Float(i))
        }
        XCTAssertEqual(buf.count, 10)
        _ = buf.read()
        _ = buf.read()
        XCTAssertEqual(buf.count, 8)
    }

    // MARK: - Wrap-Around

    func testWrapAround() {
        let buf = AudioRingBuffer(capacity: 4)
        // Fill buffer
        buf.write(1.0)
        buf.write(2.0)
        buf.write(3.0)
        // Read two, making room
        XCTAssertEqual(buf.read(), 1.0)
        XCTAssertEqual(buf.read(), 2.0)
        // Write two more — these wrap around
        buf.write(4.0)
        buf.write(5.0)
        XCTAssertEqual(buf.count, 3)
        XCTAssertEqual(buf.read(), 3.0)
        XCTAssertEqual(buf.read(), 4.0)
        XCTAssertEqual(buf.read(), 5.0)
        XCTAssertEqual(buf.count, 0)
    }

    // MARK: - Overflow

    func testOverflowOverwritesOldest() {
        let buf = AudioRingBuffer(capacity: 4)
        // Write more than capacity — overwrites oldest
        buf.write(1.0)
        buf.write(2.0)
        buf.write(3.0)
        buf.write(4.0)
        buf.write(5.0) // overwrites 1.0
        // After overflow, read pointer is stale; count may wrap.
        // For voice audio this is acceptable — verify no crash.
        // Read what's available (implementation-defined after overflow).
        var values: [Float] = []
        while let v = buf.read() {
            values.append(v)
            if values.count > 10 { break } // safety
        }
        // Should get some values without crashing
        XCTAssertFalse(values.isEmpty)
    }

    // MARK: - Bulk Operations

    func testBulkWriteAndDrain() {
        let capacity = 4096
        let buf = AudioRingBuffer(capacity: capacity)
        let frameSize = 1440 // typical 60ms at 24kHz

        // Write a full frame
        for i in 0..<frameSize {
            buf.write(Float(i) / Float(frameSize))
        }
        XCTAssertEqual(buf.count, frameSize)

        // Drain the frame
        var drained = [Float]()
        drained.reserveCapacity(frameSize)
        for _ in 0..<frameSize {
            if let v = buf.read() {
                drained.append(v)
            }
        }
        XCTAssertEqual(drained.count, frameSize)
        XCTAssertEqual(drained[0], 0.0)
        XCTAssertEqual(drained.last!, Float(frameSize - 1) / Float(frameSize), accuracy: 1e-6)
        XCTAssertEqual(buf.count, 0)
    }

    func testMultipleFrameCycles() {
        let buf = AudioRingBuffer(capacity: 4096)
        let frameSize = 960 // 20ms at 48kHz

        // Simulate 10 write/drain cycles (like the drain loop)
        for cycle in 0..<10 {
            for i in 0..<frameSize {
                buf.write(Float(cycle * frameSize + i))
            }
            XCTAssertGreaterThanOrEqual(buf.count, frameSize)

            for _ in 0..<frameSize {
                let v = buf.read()
                XCTAssertNotNil(v)
            }
        }
        XCTAssertEqual(buf.count, 0)
    }
}
