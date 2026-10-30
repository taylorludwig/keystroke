# Define

English definitions in the Keystroke palette, the way Raycast's Define Word works.

```
define serendipity
define ad hoc
```

## What you get

- **The word** (the answer row), with its parts of speech, pronunciation and how many definitions it has. The preview pane shows every definition with its examples. Enter copies the first definition, Ctrl+Enter copies the whole entry.
- **Play pronunciation** when the entry has a recording and `mpv` is installed. The US recording wins when there are several, played from Wikimedia Commons.
- **Open in Wiktionary** for the full page.
- **Did you mean**: when no source has the word, Wiktionary's fuzzy search suggests spellings; Enter on one looks it up.

Every row keeps the same preview, so the pane stays put while you move between them.

## Where the definitions come from

Both sources are Wiktionary data, need no account or key, and are only asked once you type `define` and a word (after a 350 ms pause).

1. [dictionaryapi.dev](https://dictionaryapi.dev): phonetics, examples and audio.
2. [Wiktionary's REST API](https://en.wiktionary.org/api/rest_v1/) when the first one fails (it answers HTTP 502 now and then) or has no entry.
3. Wiktionary's fuzzy title search, for spelling suggestions when neither has the word.

Answers are kept for the session. Nothing works offline.

## Settings

Only the reserved **Prefix** (default `define`), to rename the command.

## Tests

```
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input extensions/define/tests/tst_define.qml
python3 tests/palette_define_check.py
```
