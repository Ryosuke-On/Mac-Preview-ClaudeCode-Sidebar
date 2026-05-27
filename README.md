# PreviewChat

A macOS file viewer (PDF, images, Markdown) with a Claude-powered chat sidebar.
Open a file by double-click; the right sidebar lets you ask questions about it,
and Claude can read sibling files in the same folder and write summary `.md`
files on request — same agentic toolset as Claude Code.

## Features

- **PDF**: PDFKit viewer with native trackpad pinch-zoom, text selection,
  system Translate / Look Up / Find (⌘F).
- **Images**: pinch-zoom & pan.
- **Markdown / text**: rendered with native `AttributedString`,
  Find bar, Translate, Look Up — all free from `NSTextView`.
- **Chat sidebar**: spawns the `claude` CLI as a long-lived subprocess in
  stream-json mode. The working directory is set to the opened file's folder,
  and the file path is injected into the system prompt.
- **Double-click to open**: registered for PDF / image / Markdown / plain text
  via `CFBundleDocumentTypes`.

## Requirements

- macOS 14+
- Xcode 15+ (for building)
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed
  (`claude` on `PATH`)

## Authentication

The bundled `claude` CLI handles auth. **Run `claude /login` once in your terminal**
— credentials are stored in `~/.claude.json` and will be picked up by the app
on next launch.

If you prefer an API key (or use a custom endpoint), create
`~/.config/previewchat/config.json`:

```json
{
  "anthropicApiKey": "sk-ant-...",
  "anthropicBaseUrl": "https://api.anthropic.com"
}
```

Either method works; the config file takes precedence when present.

## Build

```sh
brew install xcodegen
cd PreviewChat
xcodegen generate
xcodebuild -scheme PreviewChat -derivedDataPath build CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/PreviewChat.app
```

## File association

In Finder, right-click a PDF → **Get Info** → **Open with** → choose
`PreviewChat.app` → **Change All…**. Now double-click opens it here.

## Layout

Viewer : chat ≈ 3 : 1. The divider is draggable.

## Notes

- `--permission-mode acceptEdits` is set, so the agent will write files in the
  opened file's folder without prompting. Edit `ClaudeAgent.swift` if you want
  stricter behavior.
- The agent inherits no Claude-Code-session env vars, so it always uses your
  own login (or your config file's API key).
