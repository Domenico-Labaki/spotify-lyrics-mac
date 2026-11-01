import Foundation

let url = LyricsText.searchURL(title: "Café + 100% & الحب 🎵", artist: "Björk / 宇多田ヒカル", album: "e\u{301} = #?")
let query = url.absoluteString
precondition(query.contains("%2B") && query.contains("%25") && query.contains("%26") && query.contains("%23"))
let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
precondition(decoded[0].value == "Café + 100% & الحب 🎵")
precondition(decoded[1].value == "Björk / 宇多田ヒカル")
precondition(decoded[2].value == "é = #?")
let raw = "\u{FEFF}[00:01.23]أهلاً بالعالم 🎵\n[00:02.50][00:04.25]你好、世界!\n[00:03.00]Cafe\u{301} — [love] + ♥\n[00:05.00]\n[ar:artist]"
let lines = LyricsText.parse(raw)
precondition(lines.count == 5)
precondition(lines[0].text == "أهلاً بالعالم 🎵" && lines[0].time == 1.23)
precondition(lines[1].text == "你好、世界!" && lines[3].text == "你好、世界!")
precondition(lines[2].text == "Cafe\u{301} — [love] + ♥")
precondition(lines[4].text.isEmpty)
print("Unicode URL encoding and timed lyrics checks passed")
let intro = [Line(time: 0, text: "♪"), Line(time: 12, text: "♫"), Line(time: 20, text: "Hello")]
precondition(OpeningDisplay.showTitle(lines: intro, position: 10))
precondition(!OpeningDisplay.showTitle(lines: intro, position: 20))
precondition(!OpeningDisplay.showTitle(lines: [Line(time: 0, text: "Hello")], position: 0))
precondition(OpeningDisplay.showTitle(lines: [], position: 4))
precondition(OpeningDisplay.showTitle(lines: [], position: 16))
precondition(OpeningDisplay.showTitle(lines: [], position: 4))
precondition(!OpeningDisplay.isInstrumental("I love you 🎵"))
print("Opening title checks passed")

precondition(OpeningDisplay.showTitle(lines: [Line(time: 0, text: "♪")], position: 60))

precondition(LyricScroll.progress(position: 0, start: 0, end: 10) == 0)
precondition(LyricScroll.progress(position: 8.5, start: 0, end: 10) == 1)
precondition(LyricScroll.progress(position: 1.7, start: 0, end: 2) == 1)
precondition(LyricScroll.progress(position: 1.5, start: 0, end: 2) < 1)
precondition(LyricScroll.progress(position: 5, start: 5, end: 5) == 0)
print("Lyric scrolling timing checks passed")
