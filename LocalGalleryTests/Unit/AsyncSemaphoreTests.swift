import Foundation
import XCTest
@testable import LocalGallery

/// Cancellation must resume a waiter. The previous `withCheckedContinuation`
/// swallow left a cancelled Task parked forever and leaked the slot.
final class AsyncSemaphoreTests: XCTestCase {

    func testACancelledWaiterReturnsAndDoesNotPinTheSemaphore() async {
        let sem = AsyncSemaphore(limit: 1)
        await sem.acquire()

        let waiter = Task {
            await sem.acquire()
            await sem.release()
        }
        // Let the waiter park on the queue before cancelling.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(waiter.isCancelled)
        waiter.cancel()
        await waiter.value

        await sem.release()
        // A third acquire must not hang — the cancelled waiter released.
        let third = Task {
            await sem.acquire()
            await sem.release()
            return true
        }
        let finished = await third.value
        XCTAssertTrue(finished)
    }

    func testAcquireUnderTheLimitIsImmediate() async {
        let sem = AsyncSemaphore(limit: 2)
        await sem.acquire()
        await sem.acquire()
        await sem.release()
        await sem.release()
    }

    func testReleaseWakesOneWaiter() async {
        let sem = AsyncSemaphore(limit: 1)
        await sem.acquire()
        let waiter = Task {
            await sem.acquire()
            await sem.release()
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
        await sem.release()
        XCTAssertTrue(await waiter.value)
    }
}
