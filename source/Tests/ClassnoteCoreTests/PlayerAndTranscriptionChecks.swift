import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func testCompleteCaptureKeepsQuietSpeechAndSilenceByteForByte() {
        var detector = TurnDetector(mode: .complete)
        detector.threshold = 0.0148 // The old user setting must not remove quiet frames.
        var captured = Data(), sent = Data(), saved = Data()
        var durations: [Double] = []
        for index in 0..<660 {
            let chunk = Data(repeating: UInt8(index % 251), count: 4800)
            captured.append(chunk)
            let result = detector.push(chunk, rms: index % 7 == 0 ? 0.02 : 0.0025)
            sent.append(result.append)
            if let commit = result.commit { saved.append(commit); durations.append(Double(commit.count) / 48000) }
        }
        if let tail = detector.flush() { saved.append(tail) }
        checkEqual(sent, captured); checkEqual(saved, captured)
        checkEqual(Double(saved.count) / 48000, 66)
        checkTrue(durations.allSatisfy { $0 >= 4 && $0 <= 12.1 })
        checkFalse(detector.active); checkTrue(detector.buffer.isEmpty)
    }
    func testCompleteCaptureWaitsForPhraseAndKeepsShortTail() {
        var detector = TurnDetector(mode: .complete); detector.threshold = 0.003
        for _ in 0..<39 {
            let result = detector.push(Data(repeating: 2, count: 4800), rms: 0.001)
            checkEqual(result.append.count, 4800); checkNil(result.commit)
        }
        let boundary = detector.push(Data(repeating: 2, count: 4800), rms: 0.001)
        checkEqual(boundary.commit?.count, 4 * 48000)
        let short = Data(repeating: 3, count: 1000)
        checkEqual(detector.push(short, rms: 0.0001).append, short)
        checkEqual(detector.flush(), short); checkNil(detector.flush())
    }
    func testCompleteCaptureBoundsLongSpeechWithoutGaps() {
        var detector = TurnDetector(mode: .complete)
        let chunk = Data(repeating: 9, count: 4800)
        var all = Data(), committed = Data()
        for _ in 0..<250 {
            all.append(chunk)
            if let turn = detector.push(chunk, rms: 0.1).commit { checkTrue(turn.count <= 12 * 48000); committed.append(turn) }
        }
        if let tail = detector.flush() { committed.append(tail) }
        checkEqual(committed, all); checkEqual(committed.count, 25 * 48000)
    }
    func testFreePlayerPositionAndOptionalEdgeSnap() {
        let bounds = CGRect(x: 14, y: 14, width: 1412, height: 872)
        let floating = CGRect(x: 430, y: 500, width: 278, height: 66)
        checkNil(PlayerGeometry.dockedEdge(for: floating, bounds: bounds))
        let expanded = PlayerGeometry.frame(current: floating, size: CGSize(width: 560, height: 300), bounds: bounds, dockedEdge: nil)
        checkEqual(expanded.minX, floating.minX); checkEqual(expanded.maxY, floating.maxY)
        let collapsed = PlayerGeometry.frame(current: expanded, size: PlayerGeometry.compactSize, bounds: bounds, dockedEdge: nil)
        checkEqual(collapsed, floating)
        let left = CGRect(x: 30, y: 500, width: 278, height: 66)
        checkEqual(PlayerGeometry.dockedEdge(for: left, bounds: bounds), .left)
        let right = CGRect(x: bounds.maxX - 278 - 20, y: 500, width: 278, height: 66)
        checkEqual(PlayerGeometry.dockedEdge(for: right, bounds: bounds), .right)
        let away = CGRect(x: 60, y: 500, width: 278, height: 66)
        checkNil(PlayerGeometry.dockedEdge(for: away, bounds: bounds))
    }
    func testFreePlayerClampsAcrossNegativeScreenCoordinates() {
        let bounds = CGRect(x: -1400, y: 20, width: 1300, height: 800)
        let current = CGRect(x: -900, y: 400, width: 278, height: 66)
        let expanded = PlayerGeometry.frame(current: current, size: CGSize(width: 560, height: 300), bounds: bounds, dockedEdge: nil)
        checkEqual(expanded.minX, -900); checkEqual(expanded.maxY, current.maxY)
        let outside = PlayerGeometry.frame(current: CGRect(x: 2000, y: -500, width: 278, height: 66), size: CGSize(width: 1600, height: 1000), bounds: bounds, dockedEdge: nil)
        checkEqual(outside, bounds)
    }
    func testTranscriptionModelSpecificFieldsAndTerminology() {
        let context = " opportunity cost, elasticity，<Policy>;ELASTICITY\npolitical economy "
        let terms = TranscriptionOptions.keywords(context)
        checkEqual(terms, ["opportunity cost", "elasticity", "Policy", "political economy"])
        let accurate = TranscriptionOptions.realtime(model: "gpt-transcribe", vocabulary: context)
        checkEqual(accurate["languages"] as? [String], ["en"])
        checkEqual(accurate["keywords"] as? [String], terms)
        checkNil(accurate["delay"]); checkNil(accurate["language"])
        let live = TranscriptionOptions.realtime(model: "gpt-live-transcribe", vocabulary: "")
        checkEqual(live["delay"] as? String, "high"); checkNil(live["keywords"])
        let fields = TranscriptionOptions.fileFields(model: "gpt-transcribe", vocabulary: context)
        checkTrue(fields.contains { $0.0 == "languages[]" && $0.1 == "en" })
        checkEqual(fields.filter { $0.0 == "keywords[]" }.map(\.1), terms)
        checkTrue(TranscriptionOptions.fileFields(model: "custom-model", vocabulary: context).isEmpty)
        checkNil(TranscriptionOptions.realtime(model: "custom-model", vocabulary: "")["languages"])
        checkTrue(TranscriptionOptions.prompt(String(repeating: "long term,", count: 3000)).count < 1700)
        let material = Courseware(name: "Week 7.pdf", byteCount: 1, pages: [
            .init(number: 1, text: "Opportunity cost and elasticity"),
            .init(number: 2, text: "")
        ])
        let handout = material.transcriptionContext
        checkTrue(handout.contains("[PDF p.1] Opportunity cost and elasticity"))
        checkFalse(handout.contains("[PDF p.2]"))
        let withHandout = TranscriptionOptions.realtime(model: "gpt-transcribe", vocabulary: "", context: handout)
        checkTrue((withHandout["prompt"] as? String)?.contains("do not add unspoken handout text") == true)
        checkTrue((withHandout["prompt"] as? String)?.contains("Opportunity cost") == true)
    }
}
