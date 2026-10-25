# goban's sounds: where they come from

`move-0.ogg` .. `move-4.ogg` and `capture0.ogg` .. `capture4.ogg`, unchanged, from Kaya
(<https://github.com/hadim/kaya>, `public/sounds/`), a Go board app. Simon chose them (Oct 2026) as open-source and
royalty-free sounds.

What the Kaya repository itself says, as copied on Oct 19 2026: the repository is licensed AGPL-3.0 as a whole
(`LICENSE`, "© 2025-2026 Hadim"), and nothing in it gives the sound files a license of their own or names where they
come from. Kaya credits Sabaki (MIT) for its Go code. If the sounds' own origin and license are found, they go here.

Mono, 44100 Hz Ogg Vorbis; zimr decodes them whole at load (`sounds.loadFromMemory`).
