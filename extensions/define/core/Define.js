.pragma library

// English definitions for the Keystroke palette: the request, the two
// response shapes, and the rows. Pure functions; Service.qml owns the curl
// processes and the cache. tests/tst_define.qml covers everything here.
//
//   define serendipity · define ad hoc

var NAME = "Define"
var ICON = "󰗚"
var COLOR = "#e5c07b"
var DEFAULT_KEY = "define"
// dictionaryapi.dev serves Wiktionary data with phonetics, examples and
// audio, no key. It answers 502 now and then, so Wiktionary's own REST API
// is the fallback: definitions only, as HTML.
var PRIMARY = "https://api.dictionaryapi.dev/api/v2/entries/en/"
var FALLBACK = "https://en.wiktionary.org/api/rest_v1/page/definition/"
// Fuzzy title search, for "did you mean" when neither source has the word.
var SUGGEST = "https://en.wiktionary.org/w/api.php?action=opensearch&profile=fuzzy&namespace=0&limit=6&format=json&search="
// dictionaryapi.dev's own audio files 502 as often as its API; each one
// names its Commons page, which gives the original file on upload.wikimedia.org.
var COMMONS = "https://commons.wikimedia.org/w/api.php?action=query&prop=imageinfo&iiprop=url&format=json&pageids="
var MAX_SUGGESTIONS = 5
var WEB = "https://en.wiktionary.org/wiki/"
var USER_AGENT = "keystroke-define/1.0 (https://github.com/taylorludwig/keystroke)"
var MAX_CHARS = 40
var DEBOUNCE_MS = 350
var TIMEOUT_S = 10
var CACHE_LIMIT = 200

// The word as typed, trimmed and squeezed; "" when there is nothing to look
// up or it is too long to be a word or a short phrase.
function clean(text) {
  var t = String(text || "").replace(/\s+/g, " ").trim()
  return t.length > MAX_CHARS ? "" : t
}
function cacheKey(word) { return word.toLowerCase() }

// source is "primary", "fallback" or "suggest". The -w trailer carries the HTTP status.
function requestArgv(word, source) {
  var base = source === "fallback" ? FALLBACK : source === "suggest" ? SUGGEST : PRIMARY
  return ["curl", "-sS", "--max-time", String(TIMEOUT_S), "-A", USER_AGENT, "-w", "\n__STATUS__%{http_code}",
          base + encodeURIComponent(word)]
}

function splitStatus(output) {
  var s = String(output || ""), at = s.lastIndexOf("\n__STATUS__")
  if (at < 0) return { status: 0, body: s }
  return { status: Number(s.slice(at + 11).trim()) || 0, body: s.slice(0, at) }
}

// Wiktionary's definitions are HTML; the palette shows plain text.
function stripHtml(html) {
  return String(html || "")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"").replace(/&#0?39;/g, "'").replace(/&amp;/g, "&")
    .replace(/\s+/g, " ").trim()
}

// Both parsers return the same entry, or null when the shape is not there:
// { word, phonetic, audio, commonsId, url, meanings: [{ pos, definitions: [{ text, example }] }] }
// audio is the US recording when there is one, else the first.
function parsePrimary(body) {
  var b
  try { b = JSON.parse(String(body || "")) } catch (e) { return null }
  if (!Array.isArray(b) || !b.length) return null
  var entry = { word: String(b[0].word || ""), phonetic: "", audio: "", commonsId: "", url: "", meanings: [] }
  for (var i = 0; i < b.length; i++) {
    var e = b[i] || {}
    if (!entry.phonetic && e.phonetic) entry.phonetic = String(e.phonetic)
    var ph = Array.isArray(e.phonetics) ? e.phonetics : []
    for (var p = 0; p < ph.length; p++) {
      if (!entry.phonetic && ph[p] && ph[p].text) entry.phonetic = String(ph[p].text)
      var audio = ph[p] ? String(ph[p].audio || "") : ""
      if (!/^https:\/\//.test(audio) || (entry.audio && (/-us\.mp3$/.test(entry.audio) || !/-us\.mp3$/.test(audio)))) continue
      entry.audio = audio
      var id = /[?&]curid=(\d+)/.exec(String(ph[p].sourceUrl || ""))
      entry.commonsId = id ? id[1] : ""
    }
    if (!entry.url && Array.isArray(e.sourceUrls) && e.sourceUrls.length) entry.url = String(e.sourceUrls[0])
    var ms = Array.isArray(e.meanings) ? e.meanings : []
    for (var m = 0; m < ms.length; m++) {
      var defs = (Array.isArray(ms[m].definitions) ? ms[m].definitions : [])
        .filter(function(d) { return d && d.definition })
        .map(function(d) { return { text: String(d.definition).trim(), example: d.example ? String(d.example).trim() : "" } })
      if (defs.length) entry.meanings.push({ pos: String(ms[m].partOfSpeech || "").toLowerCase(), definitions: defs })
    }
  }
  return entry.meanings.length ? entry : null
}

function parseFallback(body, word) {
  var b
  try { b = JSON.parse(String(body || "")) } catch (e) { return null }
  var en = b && Array.isArray(b.en) ? b.en : []
  var entry = { word: String(word || ""), phonetic: "", audio: "", commonsId: "", url: WEB + encodeURIComponent(word), meanings: [] }
  for (var i = 0; i < en.length; i++) {
    var defs = []
    var list = Array.isArray(en[i].definitions) ? en[i].definitions : []
    for (var d = 0; d < list.length; d++) {
      var text = stripHtml(list[d].definition)
      if (!text) continue
      var ex = Array.isArray(list[d].examples) && list[d].examples.length ? stripHtml(list[d].examples[0]) : ""
      defs.push({ text: text, example: ex })
    }
    if (defs.length) entry.meanings.push({ pos: String(en[i].partOfSpeech || "").toLowerCase(), definitions: defs })
  }
  return entry.meanings.length ? entry : null
}

// opensearch → up to MAX_SUGGESTIONS titles other than the word itself.
function parseSuggestions(body, word) {
  var b
  try { b = JSON.parse(String(body || "")) } catch (e) { return [] }
  var titles = Array.isArray(b) && Array.isArray(b[1]) ? b[1] : [], out = [], seen = {}
  seen[cacheKey(word)] = true
  for (var i = 0; i < titles.length && out.length < MAX_SUGGESTIONS; i++) {
    var t = String(titles[i] || "").trim(), k = cacheKey(t)
    if (!t || seen[k]) continue
    seen[k] = true
    out.push(t)
  }
  return out
}

// One answer from curl → { entry } | { notFound, suggestions } | { error } | { next: source }.
// The primary's failures (any non-200) go to the fallback; the fallback's
// 404 goes to the suggestions, and anything else from it is an error. The
// suggestions never fail the lookup: no answer is an empty list.
function judge(source, status, body, word) {
  if (source === "primary") {
    if (status === 200) { var e = parsePrimary(body); if (e) return { entry: e } }
    return { next: "fallback" }
  }
  if (source === "suggest") return { notFound: true, suggestions: status === 200 ? parseSuggestions(body, word) : [] }
  if (status === 200) {
    var f = parseFallback(body, word)
    return f ? { entry: f } : { next: "suggest" }
  }
  if (status === 404) return { next: "suggest" }
  return { error: status ? "Wiktionary answered HTTP " + status : "No connection to the dictionary" }
}

// Plays the recording: the Commons original when the entry names its page,
// dictionaryapi.dev's copy when that lookup fails or there is none.
function playArgv(entry) {
  var script = 'u=""\n'
    + 'if [ -n "$2" ]; then u=$(curl -sS --max-time ' + TIMEOUT_S + ' -A "$3" "$4$2" | grep -o \'"url":"[^"]*"\' | head -n 1 | cut -d \'"\' -f 4); fi\n'
    + 'exec mpv --no-video --really-quiet --ytdl=no -- "${u:-$1}"'
  return ["sh", "-c", script, "define-play", entry.audio, entry.commonsId || "", USER_AGENT, COMMONS]
}

// "noun: 1. … 2. …" for the preview pane and the "copy entry" effect.
function summary(entry) {
  var lines = []
  if (entry.phonetic) lines.push(entry.phonetic, "")
  for (var m = 0; m < entry.meanings.length; m++) {
    var mean = entry.meanings[m]
    lines.push(mean.pos || "definition")
    for (var d = 0; d < mean.definitions.length; d++) {
      var def = mean.definitions[d]
      lines.push((d + 1) + ". " + def.text + (def.example ? "\n“" + def.example + "”" : ""))
    }
    if (m < entry.meanings.length - 1) lines.push("")
  }
  return lines.join("\n")
}

function webUrl(word) { return WEB + encodeURIComponent(word) }

// "noun, verb · /ˈrʌn/ · 12 definitions" for the definition row.
function headline(entry) {
  var pos = [], count = 0
  for (var m = 0; m < entry.meanings.length; m++) {
    count += entry.meanings[m].definitions.length
    if (entry.meanings[m].pos && pos.indexOf(entry.meanings[m].pos) < 0) pos.push(entry.meanings[m].pos)
  }
  return [pos.join(", "), entry.phonetic, count + (count === 1 ? " definition" : " definitions")].filter(function(s) { return !!s }).join(" · ")
}

// ctx: { word, state, key, canPlay, prefix } where state is what the cache
// holds for the word (undefined while it is being looked up). Every row of
// an entry carries the same preview, so the pane stays put while moving
// between them.
function rows(ctx) {
  var base = { icon: ICON, section: NAME }
  function row(fields) { var r = {}; for (var k in base) r[k] = base[k]; for (var f in fields) r[f] = fields[f]; return r }
  var word = ctx.word, state = ctx.state, out = [], prefix = ctx.prefix || DEFAULT_KEY
  if (!word) {
    out.push(row({ id: "define/hint", title: "Type a word to define", subtitle: prefix + " serendipity", tier: "answer", score: 100, order: 0,
                   disabled: true, verb: "", action: { type: "noop" } }))
    return out
  }
  if (!state) {
    out.push(row({ id: "define/main", title: "Looking up “" + word + "”…", tier: "answer", score: 100, order: 0, disabled: true, verb: "", action: { type: "noop" } }))
    return out
  }
  if (state.error || state.notFound) {
    var suggestions = state.suggestions || []
    out.push(row({ id: "define/main", title: state.error || "No definition for “" + word + "”",
                   subtitle: state.error ? "Try again in a moment" : suggestions.length ? "Did you mean one of these?" : "Check the spelling",
                   tier: "answer", score: 100, order: 0, disabled: true, verb: "", action: { type: "noop" } }))
    for (var i = 0; i < suggestions.length; i++)
      out.push(row({ id: "define/suggest/" + i, title: suggestions[i], subtitle: "Define “" + suggestions[i] + "”", tier: "item", score: 90 - i, order: 1 + i,
                     verb: "Define", action: { type: "query", text: prefix + " " + suggestions[i] } }))
    out.push(row({ id: "define/web", title: "Search Wiktionary", subtitle: "“" + word + "”", tier: "item", score: 50, order: 20, verb: "Open",
                   action: { type: "url", url: webUrl(word) } }))
    return out
  }
  var entry = state.entry, all = summary(entry), first = entry.meanings[0].definitions[0].text
  var pane = { preview: all, previewStyle: "prose", previewLabel: entry.word.toUpperCase(), previewDetail: "Wiktionary" }
  out.push(row(Object.assign({ id: "define/main", title: entry.word, subtitle: headline(entry), tier: "answer", score: 100, order: 0,
                               verb: "Copy definition", altVerb: "Copy entry",
                               action: { type: "copy", text: first }, altAction: { type: "copy", text: entry.word + "\n" + all } }, pane)))
  if (entry.audio && ctx.canPlay)
    out.push(row(Object.assign({ id: "define/say", title: "Play pronunciation", subtitle: entry.phonetic, tier: "item", score: 40, order: 30, verb: "Play",
                                 action: { type: "exec", argv: playArgv(entry) } }, pane)))
  out.push(row(Object.assign({ id: "define/web", title: "Open in Wiktionary", subtitle: entry.url || webUrl(entry.word), tier: "item", score: 30, order: 31, verb: "Open",
                               action: { type: "url", url: entry.url || webUrl(entry.word) } }, pane)))
  return out
}
