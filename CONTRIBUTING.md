# Contributing

Bro Chat is a hobby project. Issues and small pull requests are welcome, but replies may be slow.

- Build and test with the commands in the [README](README.md). Run `cd BroKit && swift test` before opening a PR.
- The protocol carries no text, on purpose. A message is one byte. Changes that add free text or media won't be merged.
- Never renumber a `Mood`; older builds rely on the byte values. Add new ones at the end.
- Brody is an original character. Don't add other franchises' names, characters, logos or art, or prompts that imitate them.
- New stickers: see `Design/README.md`.
- Keep `Config/Local.xcconfig` (your team ID and bundle ID) out of commits. It is gitignored.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
