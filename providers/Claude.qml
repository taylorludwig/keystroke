import QtQuick
import Quickshell
import "../claude"
import "../codex"
import "../core/Match.js" as Match

// "Ask Claude here": answers stream inside the palette through the Claude Code
// CLI (claude -p, your own login/subscription). Mirrors providers/Codex.qml and
// reuses its ConversationView. "?" before a question asks here; Ctrl+↵ or
// "Continue in Claude Code" opens the same session in a terminal.
Item {
  id: root
  property var host: null
  readonly property var preferences: host ? host.settingsFor({key: "claude", provider: provider}) : ({})
  readonly property bool active: host ? host.providerEnabled({key: "claude", source: "bundled"}) : false
  readonly property alias session: session
  readonly property Component view: Component { ConversationView { session: root.session } }
  readonly property var provider: ({
    apiVersion: 1, id: "claude", name: "Claude", icon: "✻", description: "Ask Claude here and follow up, through the Claude Code CLI",
    settings: [
      {key: "model", type: "string", label: "Model", "default": "haiku", description: "haiku, sonnet, opus, or a full model id"},
      {key: "webSearch", type: "boolean", label: "Web search", "default": true, description: "Let Claude search and read web pages for an answer"}
    ],
    view: root.view,
    query: ctx => root.query(ctx),
    activate: (row, ctx) => root.activate(row, ctx),
    opened: function() { },
    dismiss: function() { session.dismiss() }
  })
  ClaudeSession {
    id: session
    host: root.host
    settings: root.preferences
    onChanged: if (root.host) root.host.requery({ catalog: false, provider: root.provider.id })
    onHandoffReady: id => root.launch(id, "")
  }
  onActiveChanged: if (!active) { session.shutdown(); if (host && host.activeProviderKey === "claude") host.closeProviderView() }
  function preferredScore() {
    var entry = host ? host.registryEntry("ai") : null
    return entry && host.settingsFor(entry).provider === "claude" ? 5.5 : 2.4
  }
  function raw(ctx) { return String(ctx.rawQuery === undefined ? ctx.query || "" : ctx.rawQuery).replace(/^\?\s*/, "") }
  function query(ctx) {
    if (ctx.scope && ctx.scope !== "claude") return []
    var text = raw(ctx), rows = [], scoped = ctx.scope === "claude"
    if (text.trim()) {
      rows.push({id: "ask", title: "Ask Claude here", subtitle: text, icon: "✻", section: "Continue with", tier: /^\?/.test(ctx.query) ? "answer" : "fallback",
        score: root.preferredScore(), verb: "Ask", altVerb: "Open in Claude Code", action: {type: "provider-view", provider: "claude", text: text}, altAction: {type: "claude-external", text: text}})
    } else {
      if (!scoped) rows.push({id: "open", title: "Claude", subtitle: "Quick questions and recent conversations", icon: "✻", score: 24.5, verb: "Open", action: {type: "navigate", scope: "claude", title: "Claude"}})
      rows.push({id: "new", title: "Ask Claude here", subtitle: "Type or speak a quick question", icon: "✻", score: scoped ? 100 : 23.5, verb: "Ask", action: {type: "provider-view", provider: "claude", text: ""}})
    }
    var recent = session.recent
    for (var i = 0; i < Math.min(recent.length, scoped ? 40 : (text.trim() ? 0 : 1)); i++) {
      var row = recent[i], score = text.trim() ? Match.match(text, row.title) : 20 - i
      if (score) rows.push({id: "recent/" + row.id, title: scoped ? row.title : "Resume last Claude question", subtitle: scoped ? new Date(row.updated).toLocaleString() : row.title,
        icon: "↶", section: "Recent questions", score: score, verb: "Resume", action: {type: "provider-view", provider: "claude", recent: row}})
    }
    return rows
  }
  function activate(row, ctx) {
    var effect = ctx.alternate && row.altAction ? row.altAction : row.action
    if (effect.type === "claude-external") { launch("", effect.text); return {type: "noop"} }
    if (effect.type === "provider-view") {
      var ok = effect.recent ? session.openRecent(effect.recent) : session.newQuestion(effect.text)
      if (!ok) { host.errorMessage = session.error; return {type: "noop"} }
      session.visible = true
    }
    return effect
  }
  // Open the conversation (or a new one) in Claude Code in a terminal. Sessions
  // belong to the folder they ran in, so resume from the same folder.
  function launch(id, text) {
    var script = 'cd "$1" && shift && exec claude "$@"'
    var args = id ? ["--resume", id] : (text ? [text] : [])
    if (args.some(x => String(x).length > 100000)) { session.error = "This request is too long to hand off. Ask here instead."; host.errorMessage = session.error; return }
    host.cancel()
    Quickshell.execDetached(["omarchy-launch-terminal", "bash", "-lc", script, "keystroke-claude", session.cwd].concat(args))
  }
}
