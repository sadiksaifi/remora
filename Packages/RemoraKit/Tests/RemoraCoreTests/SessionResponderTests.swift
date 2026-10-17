import Dispatch
import RemoraCore
import Synchronization
import Testing

@Test func competingChallengeAnswersRunTheCallbackOnce() {
    let answers = Mutex<[Int?]>([])
    let responder = SessionResponder<Int?> { answer in
        answers.withLock { $0.append(answer) }
    }
    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
        responder.respond(nil)
    }
    responder.respond(42)
    #expect(answers.withLock { $0.count == 1 && $0[0] == nil })
}
