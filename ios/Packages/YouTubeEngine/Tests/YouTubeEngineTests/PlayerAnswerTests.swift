import Foundation
import Testing
@testable import YouTubeEngine

/// US-009: parsing, classification and format selection, on answers recorded on the iPhone
/// (2026-11-25, `--record-answers`) and on synthetic ones for the rules no recording covers.
@Suite struct PlayerAnswerTests {
    static func fixture(_ label: String) throws -> PlayerAnswer {
        let url = try #require(Bundle.module.url(forResource: label, withExtension: "json", subdirectory: "Fixtures/answers"))
        return try PlayerAnswer(json: Data(contentsOf: url))
    }

    static func answer(_ json: String) throws -> PlayerAnswer { try PlayerAnswer(json: Data(json.utf8)) }

    // MARK: Recorded answers

    @Test func ordinaryAnswerParsesAndPicks1080pAVCWithAAC() throws {
        let answer = try Self.fixture("ordinary")
        #expect(answer.kind == .served)
        let details = try #require(answer.details)
        #expect(details.videoID == "dQw4w9WgXcQ")
        #expect(details.title?.hasPrefix("Rick Astley") == true)
        #expect(details.channelID?.hasPrefix("UC") == true)
        #expect(details.lengthSeconds == 213)
        #expect(!details.thumbnails.isEmpty)
        #expect(answer.adaptiveFormats.count == 27)
        #expect(answer.adaptiveFormats.allSatisfy { $0.url != nil && $0.signatureCipher == nil })
        #expect(answer.hlsManifestURL != nil)

        let pick = FormatSelector.select(answer)
        let video = try #require(pick.video)
        #expect(video.codecs.hasPrefix("avc1"))
        #expect(video.shortSide == 1080)
        #expect(video.initRange != nil && video.indexRange != nil && video.contentLength != nil && video.lastModified != nil)
        let audio = try #require(pick.audio)
        #expect(audio.codecs == "mp4a.40.2")
        #expect(audio.audioSampleRate == 44_100)
        #expect(audio.audioChannels == 2)
        #expect(audio.itag == 140)
        #expect(audio.initRange?.start == 0)

        let capped = try #require(FormatSelector.select(answer, maxShortSide: 720).video)
        #expect(capped.shortSide == 720)
    }

    @Test func madeForKidsIsAContentRefusal() throws {
        let answer = try Self.fixture("kids-refused")
        #expect(answer.playability.status == "UNPLAYABLE")
        #expect(answer.kind == .contentRefused)
        #expect(FormatSelector.select(answer) == FormatSelector.Selection(video: nil, audio: nil))
    }

    @Test func eighteenPlusIsAnAgeGate() throws {
        let answer = try Self.fixture("age-gate")
        #expect(answer.playability.status == "LOGIN_REQUIRED")
        #expect(answer.playability.desktopLegacyAgeGateReason != 0)
        #expect(answer.kind == .ageGate)
    }

    @Test func formatsWithoutURLsAreSABROnlyAndNoDelivery() throws {
        let answer = try Self.fixture("sabr-only")
        #expect(answer.isSABROnly)
        #expect(answer.kind == .noDelivery)
        #expect(answer.adaptiveFormats.count == 27)
        #expect(FormatSelector.select(answer).video == nil)
    }

    @Test func liveWithHLSAndNoDASHIsHeld() throws {
        let answer = try Self.fixture("live")
        #expect(answer.isLive)
        #expect(answer.hlsManifestURL != nil)
        #expect(answer.dashManifestURL == nil)
        #expect(answer.kind == .liveWithoutDash)
    }

    @Test func terminalVerdictsAreRecognised() throws {
        #expect(try Self.fixture("terminal-removed").kind == .terminal("removed-by-uploader"))
        #expect(try Self.fixture("terminal-live-gone").kind == .terminal("live-recording-gone"))
    }

    @Test(arguments: ["answers", "browse"]) func fixturesCarryNoAddressOrVisitor(folder: String) throws {
        let directory = try #require(Bundle.module.url(forResource: folder, withExtension: nil, subdirectory: "Fixtures"))
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("visitorData") && !text.contains("responseContext"), "\(file.lastPathComponent)")
            let addresses = AnswerScrubber.addresses(in: text).filter { $0 != AnswerScrubber.placeholderIP }
            #expect(addresses.isEmpty, "\(file.lastPathComponent): \(addresses)")
            #expect(AnswerScrubber.nodeNames(in: text).isEmpty, "\(file.lastPathComponent): cache node names")
            #expect(text.range(of: #"gcr(=|\\?/)(?!scrubbed)"#, options: .regularExpression) == nil, "\(file.lastPathComponent): country")
        }
    }

    // MARK: Classifier rules (BotCheckDetector)

    @Test func loginRequiredWithoutTheMarkerIsASignInOrABotCheck() throws {
        let signIn = try Self.answer(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"This video is private"}}"#)
        #expect(signIn.kind == .signInRequest)
        let bot = try Self.answer(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#)
        #expect(bot.kind == .botChallenge)
        let ageWithBotWord = try Self.answer(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"bot","desktopLegacyAgeGateReason":1}}"#)
        #expect(ageWithBotWord.kind == .ageGate, "the age marker wins")
        let ageStatus = try Self.answer(#"{"playabilityStatus":{"status":"AGE_VERIFICATION_REQUIRED"}}"#)
        #expect(ageStatus.kind == .ageGate)
    }

    @Test func terminalAllowlistAndItsGuards() {
        typealias K = AnswerKind
        #expect(K.terminalKey(status: "UNPLAYABLE", reason: "Join this channel from your computer or mobile app to get access to members-only content like this video.") == "members-only")
        #expect(K.terminalKey(status: "ERROR", reason: "Este vídeo ha sido eliminado por el usuario que lo subió.") == "removed-by-uploader",
                "accents and case don't matter")
        #expect(K.terminalKey(status: "ERROR", reason: "This video has been removed for violating YouTube's policy on spam. Learn more about combating spam.")
                == "removed-for-violation")
        #expect(K.terminalKey(status: "ERROR", reason: "This video has been removed for violating YouTube's Terms of Service on this site.") == nil,
                "a qualified removal isn't the content's verdict")
        #expect(K.terminalKey(status: "UNPLAYABLE", reason: "This video has been removed by the uploader in your country") == nil,
                "a region hint vetoes")
        #expect(K.terminalKey(status: "UNPLAYABLE", reason: "Video unavailable") == nil)
        #expect(K.terminalKey(status: "OK", reason: "This video has been removed by the uploader") == nil)
    }

    @Test func okWithoutFormatsIsNoDeliveryAndOtherStatusesAreUnavailable() throws {
        #expect(try Self.answer(#"{"playabilityStatus":{"status":"OK"}}"#).kind == .noDelivery)
        #expect(try Self.answer(#"{"playabilityStatus":{"status":"LIVE_STREAM_OFFLINE"}}"#).kind == .unavailable("LIVE_STREAM_OFFLINE"))
        #expect(try Self.answer(#"{"playabilityStatus":{"status":"ERROR","reason":"Video unavailable"}}"#).kind == .unavailable("ERROR"))
        #expect(try Self.answer("{}").kind == .unavailable("NO_STATUS"))
    }

    // MARK: Selection rules

    static func format(_ itag: Int, _ mime: String, width: Int? = nil, height: Int? = nil, fps: Int? = nil,
                       bitrate: Int, rate: String? = nil, url: Bool = true) -> String {
        var fields = [#""itag":\#(itag)"#, #""mimeType":"\#(mime.replacingOccurrences(of: "\"", with: "\\\""))""#, #""bitrate":\#(bitrate)"#]
        if let width { fields.append(#""width":\#(width)"#) }
        if let height { fields.append(#""height":\#(height)"#) }
        if let fps { fields.append(#""fps":\#(fps)"#) }
        if let rate { fields.append(#""audioSampleRate":"\#(rate)""#) }
        if url { fields.append(#""url":"https://example.invalid/\#(itag)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test func verticalVideosCountByTheirShortSideAndHighFrameRatesAreSkipped() throws {
        let formats = [
            Self.format(1, #"video/mp4; codecs="avc1.640028""#, width: 1080, height: 1920, fps: 30, bitrate: 3_000_000),
            Self.format(2, #"video/mp4; codecs="avc1.4d401f""#, width: 720, height: 1280, fps: 30, bitrate: 1_500_000),
            Self.format(3, #"video/mp4; codecs="avc1.64002a""#, width: 1920, height: 1080, fps: 120, bitrate: 6_000_000),
            Self.format(4, #"video/webm; codecs="vp9""#, width: 1080, height: 1920, fps: 30, bitrate: 2_000_000),
            Self.format(5, #"video/mp4; codecs="avc1.640028""#, width: 1080, height: 1920, fps: 30, bitrate: 2_500_000, url: false),
        ].joined(separator: ",")
        let answer = try Self.answer(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[\#(formats)]}}"#)
        #expect(FormatSelector.select(answer).video?.itag == 1)
        #expect(FormatSelector.select(answer, maxShortSide: 720).video?.itag == 2)
    }

    @Test func audioPrefersAACLCAt44100ThenAnyMP4A() throws {
        let both = [
            Self.format(10, #"audio/mp4; codecs="mp4a.40.2""#, bitrate: 130_000, rate: "44100"),
            Self.format(11, #"audio/mp4; codecs="mp4a.40.2""#, bitrate: 260_000, rate: "48000"),
            Self.format(12, #"audio/mp4; codecs="mp4a.40.5""#, bitrate: 50_000, rate: "22050"),
            Self.format(13, #"audio/webm; codecs="opus""#, bitrate: 160_000, rate: "48000"),
        ].joined(separator: ",")
        let answer = try Self.answer(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[\#(both)]}}"#)
        #expect(FormatSelector.select(answer).audio?.itag == 10)
        let only48 = [Self.format(11, #"audio/mp4; codecs="mp4a.40.2""#, bitrate: 260_000, rate: "48000"),
                      Self.format(12, #"audio/mp4; codecs="mp4a.40.5""#, bitrate: 50_000, rate: "22050")].joined(separator: ",")
        let fallback = try Self.answer(#"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":[\#(only48)]}}"#)
        #expect(FormatSelector.select(fallback).audio?.itag == 11)
    }

    @Test func scrubberReplacesTheAddressEverywhere() throws {
        let raw = #"{"responseContext":{"visitorData":"Cgt"},"streamingData":{"hlsManifestUrl":"https://m.invalid/api/manifest/ip/2a02%3A1234%3A%3A1/x","adaptiveFormats":[{"itag":1,"mimeType":"audio/mp4","url":"https://rr1.invalid/videoplayback?expire=1&ip=2a02%3A1234%3A%3A1&id=o"}]},"playabilityStatus":{"status":"OK"}}"#
        let text = String(decoding: try AnswerScrubber.scrub(Data(raw.utf8)), as: UTF8.self)
        #expect(!text.contains("2a02"))
        #expect(!text.contains("responseContext"))
        #expect(text.contains("ip=0.0.0.0"))
        let nodes = #"{"streamingData":{"adaptiveFormats":[{"itag":1,"mimeType":"audio/mp4","url":"https://rr5---sn-abc1de-5hhs.googlevideo.com/videoplayback?mn=sn-abc1de-5hhs%2Csn-xyz9-5j%2Csn-abcd1234&ip=1.2.3.4"}]}}"#
        let scrubbed = String(decoding: try AnswerScrubber.scrub(Data(nodes.utf8)), as: UTF8.self)
        #expect(scrubbed.contains("rr5---sn-scrubbed-1.googlevideo.com"))
        #expect(scrubbed.contains("mn=sn-scrubbed-1%2Csn-scrubbed-2%2Csn-scrubbed-3"))
        #expect(AnswerScrubber.nodeNames(in: scrubbed).isEmpty)
        let country = #"{"streamingData":{"hlsManifestUrl":"https://m.invalid/api/manifest/gcr/xx/ei/abc/file/index.m3u8","adaptiveFormats":[{"itag":1,"mimeType":"audio/mp4","url":"https://h.invalid/videoplayback?gcr=xx&itag=140&ei=abc&clen=9"}]}}"#
        let quiet = String(decoding: try AnswerScrubber.scrub(Data(country.utf8)), as: UTF8.self)
        #expect(quiet.contains("gcr=scrubbed") && quiet.contains(#"\/gcr\/scrubbed\/"#) && quiet.contains("ei=scrubbed"),
                "JSON output escapes slashes")
        #expect(!quiet.contains("gcr=xx") && !quiet.contains(#"gcr\/xx"#))
        #expect(quiet.contains("itag=140") && quiet.contains("clen=9"))
    }
}
