import QtQuick
import QtTest
import "../core/Define.js" as Define

TestCase {
  name: "Define"
  readonly property string primaryBody: JSON.stringify([{
    word: "serendipity", phonetic: "/ˌsɛ.ɹən.ˈdɪ.pɪ.ti/",
    phonetics: [{ text: "/ˌsɛ.ɹən.ˈdɪ.pɪ.ti/", audio: "" }, { text: "", audio: "https://api.dictionaryapi.dev/media/pronunciations/en/serendipity-us.mp3" }],
    meanings: [{ partOfSpeech: "noun", definitions: [
      { definition: "A combination of events which have come together by chance to make a surprisingly good outcome." },
      { definition: "An unexpected, fortunate discovery.", example: "Finding the book was pure serendipity." }] }],
    sourceUrls: ["https://en.wiktionary.org/wiki/serendipity"] }])
  readonly property string fallbackBody: JSON.stringify({ en: [
    { partOfSpeech: "Noun", language: "English", definitions: [
      { definition: "The <a rel=\"mw:WikiLink\" href=\"/wiki/phenomenon\">phenomenon</a> of making an <b>unplanned</b> discovery &amp; more.",
        examples: ["<i>It was</i> serendipity."] },
      { definition: "" }] }] })

  function test_clean() {
    compare(Define.clean("  ad   hoc "), "ad hoc")
    compare(Define.clean(""), "")
    compare(Define.clean(new Array(50).join("x")), "")
  }

  function test_request() {
    var a = Define.requestArgv("ad hoc", "primary")
    compare(a[0], "curl")
    compare(a[a.length - 1], "https://api.dictionaryapi.dev/api/v2/entries/en/ad%20hoc")
    verify(Define.requestArgv("run", "fallback")[a.length - 1].indexOf("en.wiktionary.org/api/rest_v1/page/definition/run") > 0)
    compare(Define.splitStatus("{}\n__STATUS__404"), { status: 404, body: "{}" })
    compare(Define.splitStatus("garbage").status, 0)
  }

  function test_primary() {
    var e = Define.parsePrimary(primaryBody)
    compare(e.word, "serendipity")
    compare(e.phonetic, "/ˌsɛ.ɹən.ˈdɪ.pɪ.ti/")
    verify(e.audio.indexOf("serendipity-us.mp3") > 0)
    compare(e.meanings[0].pos, "noun")
    compare(e.meanings[0].definitions.length, 2)
    compare(e.meanings[0].definitions[1].example, "Finding the book was pure serendipity.")
    compare(Define.parsePrimary("{\"title\":\"No Definitions Found\"}"), null)
    compare(Define.parsePrimary("not json"), null)
  }

  function test_fallback() {
    var e = Define.parseFallback(fallbackBody, "serendipity")
    compare(e.meanings[0].pos, "noun")
    compare(e.meanings[0].definitions.length, 1)
    compare(e.meanings[0].definitions[0].text, "The phenomenon of making an unplanned discovery & more.")
    compare(e.meanings[0].definitions[0].example, "It was serendipity.")
    compare(e.url, "https://en.wiktionary.org/wiki/serendipity")
    compare(Define.parseFallback("{\"fr\":[]}", "x"), null)
  }

  function test_audio() {
    var body = JSON.stringify([{ word: "tomato", phonetics: [
      { text: "/təˈmɑːtəʊ/", audio: "https://api.dictionaryapi.dev/media/pronunciations/en/tomato-uk.mp3", sourceUrl: "https://commons.wikimedia.org/w/index.php?curid=111" },
      { text: "/təˈmeɪtoʊ/", audio: "https://api.dictionaryapi.dev/media/pronunciations/en/tomato-us.mp3", sourceUrl: "https://commons.wikimedia.org/w/index.php?curid=222" },
      { text: "", audio: "https://api.dictionaryapi.dev/media/pronunciations/en/tomato-au.mp3" }],
      meanings: [{ partOfSpeech: "noun", definitions: [{ definition: "A fruit." }] }] }])
    var e = Define.parsePrimary(body)
    verify(e.audio.indexOf("tomato-us.mp3") > 0, "the US recording wins")
    compare(e.commonsId, "222")
    var argv = Define.playArgv(e)
    compare(argv.slice(0, 2), ["sh", "-c"])
    compare(argv[4], e.audio)
    compare(argv[5], "222")
    compare(argv[7].indexOf("https://commons.wikimedia.org/w/api.php"), 0)
    verify(argv[2].indexOf('exec mpv --no-video --really-quiet --ytdl=no -- "${u:-$1}"') > 0)
  }

  function test_suggestions() {
    var body = JSON.stringify(["serendipty", ["serendipity", "Serendipty", "serendipitous", "serenity", "Serendip", "serene", "x"]])
    compare(Define.parseSuggestions(body, "serendipty"), ["serendipity", "serendipitous", "serenity", "Serendip", "serene"])
    compare(Define.parseSuggestions("nope", "x"), [])
    verify(Define.requestArgv("serendipty", "suggest")[8].indexOf("action=opensearch") > 0)
  }

  function test_judge() {
    verify(Define.judge("primary", 200, primaryBody, "serendipity").entry)
    compare(Define.judge("primary", 502, "", "run").next, "fallback")
    compare(Define.judge("primary", 404, "{}", "qwzxv").next, "fallback")
    compare(Define.judge("primary", 0, "", "run").next, "fallback")
    verify(Define.judge("fallback", 200, fallbackBody, "serendipity").entry)
    compare(Define.judge("fallback", 404, "", "qwzxv").next, "suggest")
    compare(Define.judge("fallback", 200, "{\"fr\":[]}", "qwzxv").next, "suggest")
    compare(Define.judge("fallback", 503, "", "run").error, "Wiktionary answered HTTP 503")
    compare(Define.judge("fallback", 0, "", "run").error, "No connection to the dictionary")
    compare(Define.judge("suggest", 200, "[\"qw\",[\"qwerty\"]]", "qw"), { notFound: true, suggestions: ["qwerty"] })
    compare(Define.judge("suggest", 0, "", "qw"), { notFound: true, suggestions: [] })
  }

  function test_rows() {
    var hint = Define.rows({ word: "", state: undefined, key: "define", canPlay: true })
    compare(hint.length, 1)
    verify(hint[0].disabled)
    compare(Define.rows({ word: "run", state: undefined, key: "define" })[0].title, "Looking up “run”…")

    var missing = Define.rows({ word: "serendipty", state: { notFound: true, suggestions: ["serendipity", "serenity"] }, key: "define", prefix: "def" })
    compare(missing[0].title, "No definition for “serendipty”")
    compare(missing[0].subtitle, "Did you mean one of these?")
    compare(missing[1].title, "serendipity")
    compare(missing[1].action, { type: "query", text: "def serendipity" })
    compare(missing[3].action.url, "https://en.wiktionary.org/wiki/serendipty")
    compare(Define.rows({ word: "qwzxv", state: { notFound: true, suggestions: [] }, key: "define" })[0].subtitle, "Check the spelling")

    var entry = Define.parsePrimary(primaryBody)
    var r = Define.rows({ word: "serendipity", state: { entry: entry }, key: "define", canPlay: true })
    compare(r.length, 3, "one definition row, play, open")
    compare(r[0].title, "serendipity")
    compare(r[0].subtitle, "noun · /ˌsɛ.ɹən.ˈdɪ.pɪ.ti/ · 2 definitions")
    compare(r[0].tier, "answer")
    compare(r[0].action, { type: "copy", text: entry.meanings[0].definitions[0].text })
    verify(r[0].preview.indexOf("\n2. An unexpected, fortunate discovery.") > 0)
    compare(r[0].previewStyle, "prose")
    for (var i = 1; i < r.length; i++) compare(r[i].preview, r[0].preview, "every row keeps the pane: " + r[i].id)
    compare(r[1].id, "define/say")
    compare(r[1].action.argv[0], "sh")
    compare(r[2].title, "Open in Wiktionary")
    compare(r[2].action.url, "https://en.wiktionary.org/wiki/serendipity")
    compare(Define.rows({ word: "serendipity", state: { entry: entry }, key: "define", canPlay: false }).length, 2)
  }
}
