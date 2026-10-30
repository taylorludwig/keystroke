#!/usr/bin/env python3
"""The Define extension looks words up through `define`, offscreen, with a fake curl.

A copy of the project and a fake HOME with the extension turned on. `curl` on
PATH is a script that logs every call and answers by URL: dictionaryapi.dev
knows "serendipity" and answers 502 for everything else, Wiktionary knows
"run" and answers 404 for everything else, and its fuzzy search suggests
"qwerty". So one word comes from the primary, one from the fallback after a
502, and one is not found by either and offers the suggestion, which types
itself into the palette. A word looked up once is not fetched again. The palette is driven through
Keystroke.qml itself.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="keystroke-palette-define-") as temp:
    work = Path(temp)
    project = work / "project"
    shutil.copytree(root, project, ignore=shutil.ignore_patterns(".git", ".claude", ".agents", ".codex", "tests", "__pycache__", "experiments"))
    (work / "qs").symlink_to("/usr/share/omarchy/shell")
    source = project / "Keystroke.qml"
    qml = source.read_text()
    qml = qml.replace("  PanelWindow {", "  Window {\n    transientParent: null\n    width: 1000; height: 800")
    qml = qml.replace("    anchors { top: true; bottom: true; left: true; right: true }\n", "")
    source.write_text("\n".join(line for line in qml.splitlines() if "exclusionMode:" not in line and "WlrLayershell." not in line))

    (work / ".config/omarchy").mkdir(parents=True)
    (work / ".config/omarchy/keystroke.json").write_text(json.dumps({"version": 1, "matching": {"mode": "off"}, "providers": {"define": {"enabled": True}}}))

    fake = work / "bin"
    fake.mkdir()
    log = work / "curl.log"
    primary = [{"word": "serendipity", "phonetic": "/ˌsɛ.ɹən.ˈdɪ.pɪ.ti/", "phonetics": [],
                "meanings": [{"partOfSpeech": "noun", "definitions": [{"definition": "A fortunate discovery made by chance."}]}],
                "sourceUrls": ["https://en.wiktionary.org/wiki/serendipity"]}]
    fallback = {"en": [{"partOfSpeech": "Verb", "language": "English", "definitions": [{"definition": "To <a href=\"/wiki/move\">move</a> swiftly."}]}]}
    (work / "primary.json").write_text(json.dumps(primary))
    (work / "fallback.json").write_text(json.dumps(fallback))
    (fake / "curl").write_text(f"""#!/bin/sh
for a; do url="$a"; done
echo "$url" >> "{log}"
case "$url" in
  *dictionaryapi.dev*/serendipity) cat "{work / 'primary.json'}"; printf '\\n__STATUS__200' ;;
  *dictionaryapi.dev*) printf '<html>bad gateway</html>\\n__STATUS__502' ;;
  *opensearch*) printf '["qwzxv",["qwerty","qwzxv"]]\\n__STATUS__200' ;;
  *wiktionary.org*/run) cat "{work / 'fallback.json'}"; printf '\\n__STATUS__200' ;;
  *) printf '{{}}\\n__STATUS__404' ;;
esac
""")
    (fake / "curl").chmod(0o755)

    (work / "shell.qml").write_text("""import QtQuick
import Quickshell
import Quickshell.Io
import "project"
ShellRoot {
 id: test
 property int stage: 0
 property int failures: 0
 function check(ok, msg) { if (!ok) { failures++; console.log("FAIL", msg) } else console.log("ok", msg) }
 function titles() { return palette.rows.map(function(r) { return r.title }) }
 function row(title) { return palette.rows.filter(function(r) { return r.title === title })[0] || null }
 function looking() { return palette.rows.some(function(r) { return r.title.indexOf("Looking up") === 0 }) }
 function service() { var s = palette.registry.services["define"]; return s ? s.instance : null }
 function curlCalls() { return String(curlLog.text()).split("\\n").filter(function(l) { return l.trim() }) }
 Keystroke { id: palette; omarchyPath: "/usr/share/omarchy" }
 FileView { id: curlLog; path: \"""" + str(log) + """\"; printErrors: false; blockLoading: true }
 Timer { interval: 100; repeat: true; running: true; onTriggered: {
   curlLog.reload()
   switch (test.stage) {
   case 0:
     if (!service()) return
     palette.open(JSON.stringify({ query: "define serendipity" }))
     test.stage = 1; return
   case 1:   // the primary answers
     if (palette.pending || service().inflight || !palette.rows.length || looking()) return
     var r = row("serendipity")
     test.check(r !== null && r.tier === "answer", "define serendipity answers from dictionaryapi.dev: " + titles().join(" | "))
     test.check(r && r.subtitle.indexOf("noun") === 0, "the subtitle names the part of speech: " + (r && r.subtitle))
     test.check(r && r.action.type === "copy" && r.action.text === "A fortunate discovery made by chance.", "Enter copies the definition")
     test.check(r && r.preview.indexOf("1. A fortunate discovery made by chance.") >= 0, "the preview holds the definition")
     test.check(row("Open in Wiktionary") && row("Open in Wiktionary").preview === r.preview, "the Open row keeps the preview")
     test.check(curlCalls().length === 1, "one curl: " + curlCalls().join(" ; "))
     palette.setQuery("define run")
     test.stage = 2; return
   case 2:   // a 502 from the primary goes to Wiktionary
     if (palette.pending || service().inflight || !palette.rows.length || looking()) return
     test.check(row("run") !== null && row("run").preview.indexOf("To move swiftly.") >= 0, "define run answers from Wiktionary after a 502: " + titles().join(" | "))
     palette.setQuery("define qwzxv")
     test.stage = 3; return
   case 3:
     if (palette.pending || service().inflight || !palette.rows.length || looking()) return
     test.check(row("No definition for “qwzxv”") !== null, "an unknown word says so: " + titles().join(" | "))
     test.check(row("qwerty") !== null && row("qwerty").action.type === "query" && row("qwerty").action.text === "define qwerty", "and suggests a spelling: " + titles().join(" | "))
     test.check(row("Search Wiktionary") !== null, "and offers the web search")
     test.check(curlCalls().length >= 3 && curlCalls()[2].indexOf("wiktionary.org") > 0, "run went to the primary, then Wiktionary: " + curlCalls().join(" ; "))
     palette.setQuery("define serendipity")
     test.stage = 4; return
   case 4:
     if (palette.pending || service().inflight || !palette.rows.length || looking()) return
     test.check(row("serendipity") !== null, "the cached answer comes back: " + titles().join(" | "))
     test.check(curlCalls().length === 6, "and curl does not run again: " + curlCalls().length)
     palette.setQuery("serendipity")
     test.stage = 5; return
   case 5:
     if (palette.pending) return
     test.check(!palette.rows.some(function(r) { return r.section === "Define" }), "without the prefix Define stays quiet")
     console.log(test.failures ? "FAIL palette define" : "PASS palette define")
     Qt.quit(); test.stage = 6; return
   }
 } }
 Timer { interval: 15000; running: true; onTriggered: { console.log("FAIL timeout at stage", test.stage, JSON.stringify(palette.registry.problems), palette.errorMessage, titles().join(" | ")); Qt.quit() } }
}
""")
    env = dict(os.environ, HOME=str(work), XDG_RUNTIME_DIR=str(work), PATH=f"{fake}:{os.environ['PATH']}",
               QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="generic", QT_QUICK_BACKEND="software", QML_IMPORT_PATH=str(work))
    for k in ("DISPLAY", "WAYLAND_DISPLAY", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        env.pop(k, None)
    result = subprocess.run(["quickshell", "-p", str(work / "shell.qml")], env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    assert "PASS palette define" in output and "FAIL" not in output, output
    assert "TypeError" not in output and "ReferenceError" not in output, output
    print("PASS palette define: dictionaryapi.dev answers, a 502 falls back to Wiktionary, an unknown word gets spelling suggestions, answers are cached, and only the prefix triggers it")
