pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "core/Define.js" as Define

// Define: English definitions inside the Keystroke command palette.
//
// Keystroke creates this object when the extension is turned on, injects
// `shell`, `extension` and `omarchyPath`, reads `provider`, and destroys it
// when the extension is turned off. The request, parsing and rows are in
// core/Define.js; this file owns the curl processes, the debounce and the
// session cache.
//
// One lookup per word after a 350 ms typing pause: dictionaryapi.dev first,
// Wiktionary's REST API when that fails, Wiktionary's fuzzy search for
// spelling suggestions when neither has the word. Answers stay for the session,
// errors for 30 seconds, and a lookup for a word no longer typed is killed.
QtObject {
  id: root
  property var shell: null
  property var extension: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var host: null            // the palette, captured from ctx on each query
  readonly property string key: extension && extension.id ? String(extension.id) : Define.DEFAULT_KEY

  readonly property var provider: ({
    apiVersion: 1,
    name: Define.NAME,
    icon: Define.ICON,
    color: Define.COLOR,
    description: "English definitions from Wiktionary data: define serendipity",
    query: function(ctx) { return root.query(ctx) }
  })

  // ------------------------------------------------------------------ cache
  property var cache: ({})
  property var cacheOrder: []
  function lookup(word) {
    var v = cache[Define.cacheKey(word)]
    if (v && v.error && v.at + 30000 < Date.now()) return undefined
    return v
  }
  function store(word, value) {
    var k = Define.cacheKey(word)
    if (cache[k] === undefined) {
      cacheOrder.push(k)
      while (cacheOrder.length > Define.CACHE_LIMIT) delete cache[cacheOrder.shift()]
    }
    cache[k] = value
  }

  // ------------------------------------------------------------------ fetch
  property string wanted: ""         // the word the palette shows now
  property var inflight: null        // the one curl running, or null
  readonly property Timer debounce: Timer { interval: Define.DEBOUNCE_MS; onTriggered: root.start(root.wanted, "primary") }

  function want(word) {
    if (word === wanted) return
    wanted = word
    if (inflight && Define.cacheKey(inflight.word) !== Define.cacheKey(word)) { inflight.cancelled = true; inflight.signal(15); inflight = null }
    if (word && lookup(word) === undefined && !inflight) debounce.restart()
    else debounce.stop()
  }
  function start(word, source) {
    if (!word || lookup(word) !== undefined) return
    inflight = fetcher.createObject(root, { word: word, source: source, command: Define.requestArgv(word, source) })
  }

  readonly property Component fetcher: Component {
    Process {
      id: proc
      property string word: ""
      property string source: "primary"
      property bool cancelled: false
      property bool done: false
      running: true
      stdout: StdioCollector { onStreamFinished: root.finished(proc, text) }
      onExited: function(code) { root.exited(proc, code) }
    }
  }
  function finished(proc, output) {
    if (proc.cancelled || proc.done) return
    var parts = Define.splitStatus(output)
    if (parts.status === 0) return                       // curl failed before answering; exited() handles it
    proc.done = true
    settle(proc, Define.judge(proc.source, parts.status, parts.body, proc.word))
  }
  function exited(proc, code) {
    if (!proc.cancelled && !proc.done) {
      proc.done = true
      settle(proc, Define.judge(proc.source, 0, "", proc.word))
    }
    Qt.callLater(function() { proc.destroy() })
  }
  function settle(proc, verdict) {
    if (inflight === proc) inflight = null
    if (verdict.next) { start(proc.word, verdict.next); return }
    store(proc.word, verdict.error ? { error: verdict.error, at: Date.now() } : verdict)
    if (wanted && Define.cacheKey(wanted) !== Define.cacheKey(proc.word) && lookup(wanted) === undefined) start(wanted, "primary")
    if (host && host.opened) host.requery({ catalog: false, provider: key })
  }

  property bool canPlay: false
  readonly property Process playProbe: Process {
    command: ["sh", "-c", "command -v mpv"]
    running: true
    onExited: function(code) { root.canPlay = code === 0 }
  }

  // ----------------------------------------------------------------- palette
  // Only the declared command answers; the host hands over the text after
  // the prefix in ctx.command.rest.
  function query(ctx) {
    host = ctx.host
    if (ctx.scope || !ctx.command) { want(""); return [] }
    var word = Define.clean(ctx.command.rest)
    want(word)
    var state = word ? lookup(word) : undefined
    if (word && state === undefined) ctx.pending()
    return Define.rows({ word: word, state: state, key: key, canPlay: canPlay, prefix: ctx.command.prefix })
  }

  Component.onDestruction: {
    debounce.stop()
    if (inflight) { inflight.cancelled = true; inflight.signal(15); inflight = null }
  }
}
