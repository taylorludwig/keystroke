import QtQuick
import Quickshell
import Quickshell.Io

// A conversation with the Claude Code CLI, shaped like CodexSession so the
// shared ConversationView can show it. One `claude -p` process per
// conversation, kept open between turns with stream-json in and out; it uses
// the CLI's own login (a Claude subscription works). Stopping kills the
// process; the next message resumes the same session with --resume.
Item {
  id: root
  property var host: null
  property var settings: ({})
  property string home: Quickshell.env("HOME")
  readonly property string agentName: "Claude"
  readonly property string headerText: "Quick question · " + model() + (settings.webSearch === false ? "" : " · web search")
  readonly property string handoffLabel: "Continue in Claude Code"
  property string threadId: ""      // the CLI's session id
  property string title: "Quick question"
  property string draft: ""
  property string error: ""
  property string activity: ""
  property string mode: "quick"
  property string cwd: home + "/.local/state/keystroke/claude"
  property string phase: "idle"     // idle | preparing | running | stopping
  readonly property bool busy: phase !== "idle"
  visible: false
  property var messages: []
  property var recent: []
  property var approvals: []
  property var pendingSends: []
  property string replyId: ""
  property string submitted: ""
  property real startedTime: 0
  property int lastMs: 0
  property int firstTextMs: 0
  property bool stopping: false
  property bool handoffPending: false
  property int replySerial: 0
  signal changed()
  signal handoffReady(string threadId)

  readonly property string systemPrompt: "You answer questions inside Keystroke, a command palette on the user's Omarchy Linux desktop. "
    + "Be direct and concise; lead with the answer. Use short Markdown when it helps (lists, code). "
    + "The user can follow up in the same conversation."

  function model() { return settings.model || "haiku" }
  function command() {
    var tools = settings.webSearch === false ? "" : "WebSearch,WebFetch"
    var args = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
      "--verbose", "--include-partial-messages", "--model", model(),
      "--tools", tools, "--allowedTools", tools,
      "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
      "--system-prompt", systemPrompt]
    if (threadId) args.push("--resume", threadId)
    // A login shell, so the CLI is found wherever it's installed (mise, npm, ~/.local/bin).
    return ["bash", "-lc", 'mkdir -p "$1" && cd "$1" && shift && exec "$@"', "keystroke-claude", cwd].concat(args)
  }

  FileView {
    id: historyFile
    path: root.home + "/.local/state/keystroke/claude.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d.version === 1 && Array.isArray(d.recent)) root.recent = d.recent.slice(0, 40)
      } catch (_) { root.error = "Could not read recent questions" }
    }
  }
  function saveRecent() {
    if (!threadId) return
    var keep = messages.filter(m => m.role !== "activity").slice(-30).map(m => ({id: m.id, role: m.role, text: String(m.text).slice(0, 20000)}))
    var row = {id: threadId, title: title, draft: draft, messages: keep, updated: Date.now()}
    recent = [row].concat(recent.filter(x => x.id !== threadId)).slice(0, 40)
    historyFile.setText(JSON.stringify({version: 1, recent: recent}, null, 2) + "\n")
    changed()
  }

  Process {
    id: proc
    stdinEnabled: true
    stdout: SplitParser { onRead: data => root.receive(data) }
    stderr: SplitParser { onRead: data => { if (String(data).trim()) root.diagnostic = (root.diagnostic + "\n" + data).slice(-3000) } }
    onStarted: {
      var queue = root.pendingSends; root.pendingSends = []
      for (var q of queue) proc.write(q)
    }
    onExited: function(code) {
      var wasStopping = root.stopping; root.stopping = false
      if (root.handoffPending) { root.handoffPending = false; root.phase = "idle"; root.handoffReady(root.threadId); return }
      if (wasStopping) { root.phase = "idle"; root.activity = "Stopped"; root.saveRecent(); return }
      if (root.busy) {
        root.phase = "idle"; root.activity = ""
        root.error = code === 127 ? "The claude CLI isn't installed or isn't on PATH."
          : "Claude stopped" + (root.diagnostic ? ": " + root.diagnostic.trim().split("\n").slice(-1)[0] : "") + ". Send again to continue."
        if (!root.draft && root.submitted) root.draft = root.submitted
        root.saveRecent()
      }
    }
  }
  property string diagnostic: ""

  function send(text) {
    var line = JSON.stringify({type: "user", message: {role: "user", content: [{type: "text", text: text}]}}) + "\n"
    if (proc.running) proc.write(line)
    else { pendingSends = pendingSends.concat([line]); diagnostic = ""; proc.command = command(); proc.running = true }
  }
  function warm() { }
  function newQuestion(text, agentCwd) {
    if (busy) { error = "Stop the current answer before starting another question"; return false }
    saveRecent(); paint.stop(); deltas = ({})
    if (proc.running) { stopping = true; proc.running = false }
    threadId = ""; messages = []; title = "Quick question"
    draft = String(text || ""); error = ""; activity = ""; submitted = ""
    if (draft.trim()) submit()
    return true
  }
  function openRecent(row) {
    if (busy) return false
    saveRecent(); paint.stop(); deltas = ({})
    if (proc.running) { stopping = true; proc.running = false }
    threadId = row.id; title = row.title || "Quick question"; draft = row.draft || ""
    messages = (row.messages || []).slice(); error = ""; activity = ""; submitted = ""
    changed()
    return true
  }
  function submit() {
    var text = draft
    if (!text.trim() || phase === "stopping") return false
    error = ""
    if (title === "Quick question") title = text.replace(/\s+/g, " ").trim().slice(0, 80)
    upsert("user-" + Date.now(), "user", text)
    draft = ""; submitted = text
    if (!busy) {
      startedTime = Date.now(); firstTextMs = 0; lastMs = 0
      phase = "preparing"; activity = proc.running ? "Answering…" : "Starting Claude…"
    }
    send(text)
    return true
  }
  function stop() {
    if (!busy) return
    phase = "stopping"; activity = "Stopping…"; stopping = true
    flush(); proc.running = false
  }
  function dismiss() { visible = false; stop(); saveRecent() }
  function shutdown() { dismiss(); if (proc.running) { stopping = true; proc.running = false } }
  function requestHandoff() {
    if (!threadId) { error = "Send a question before continuing in Claude Code"; return }
    saveRecent()
    if (proc.running) { handoffPending = true; stopping = true; flush(); proc.running = false }
    else handoffReady(threadId)
  }
  function answer() { var r = messages.filter(x => x.role === "assistant"); return r.length ? r[r.length - 1].text : "" }
  function approvalDetail(a) { return "" }
  function decide(accept, answer) { }

  property var deltas: ({})
  function upsert(id, role, text) {
    var copy = messages.slice(), index = copy.findIndex(x => x.id === id)
    var item = {id: id, role: role, text: String(text || "").slice(-250000)}
    if (index < 0) copy.push(item); else copy[index] = item
    messages = copy.slice(-160)
  }
  function flush() {
    var copy = deltas; deltas = ({})
    for (var id in copy) {
      var existing = messages.find(x => x.id === id)
      upsert(id, "assistant", (existing ? existing.text : "") + copy[id])
    }
  }
  Timer { id: paint; interval: 32; onTriggered: root.flush() }

  function receive(line) {
    var msg
    try { msg = JSON.parse(line) } catch (_) { return }
    if (msg.session_id && msg.session_id !== threadId) threadId = msg.session_id
    if (msg.type === "system" && msg.subtype === "init") {
      if (phase === "preparing") activity = "Answering…"
    } else if (msg.type === "stream_event") {
      var ev = msg.event || {}
      if (ev.type === "message_start") {
        replyId = (ev.message && ev.message.id) || ("reply-" + (++replySerial))
        if (phase === "preparing") phase = "running"
      } else if (ev.type === "content_block_start" && ev.content_block) {
        var block = ev.content_block
        if (block.type === "tool_use" || block.type === "server_tool_use") {
          activity = /search/i.test(block.name) ? "Searching the web…" : /fetch/i.test(block.name) ? "Reading a page…" : "Using " + block.name + "…"
        } else if (block.type === "thinking") activity = "Thinking…"
      } else if (ev.type === "content_block_delta" && ev.delta && ev.delta.type === "text_delta") {
        if (!firstTextMs) firstTextMs = Date.now() - startedTime
        activity = "Answering…"
        var copy = Object.assign({}, deltas); copy[replyId] = (copy[replyId] || "") + (ev.delta.text || ""); deltas = copy
        if (!paint.running) paint.start()
      }
    } else if (msg.type === "result") {
      flush()
      if (msg.is_error) error = String(msg.result || msg.subtype || "Claude reported an error")
      else if (!messages.length || messages[messages.length - 1].role !== "assistant") upsert("result-" + (++replySerial), "assistant", msg.result || "")
      lastMs = Date.now() - startedTime
      phase = "idle"; activity = msg.is_error ? "Failed" : "Done"; submitted = ""
      saveRecent()
    }
  }
}
