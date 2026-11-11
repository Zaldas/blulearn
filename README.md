# blulearn

**An FFXI addon for HorizonXI (Ashita v4) that plays an animated banner naming each blue
magic spell you learn.**

When a Blue Mage learns a spell, blulearn reads the spell id straight out of the server's
message packet and animates the mask and a spinning staff into place with the spell's
name beneath it, with sound.

---
<img width="881" height="289" alt="blulearnanim" src="https://github.com/user-attachments/assets/32b2274f-ee01-4dba-93c0-4eb16082e9ea" />

---

## Installation

1. Extract the `blulearn` folder into `Ashita4/addons/`
2. Install the **Jupiter Pro** font from the release page
3. `/addon load blulearn`

> [!IMPORTANT]
> **The banner above will not look like that without the font.** Jupiter Pro does not ship
> with Windows. If it is missing, GDI substitutes a default face and the spell name will
> not match the artwork — the addon warns you in chat when this happens.

## Features

- **Names the spell** — the banner shows the actual spell learned, not a generic message
- **Animated reveal** — mask, spinning staff, and fixed-length fade phases
- **Configurable** — from the config window: screen position; sound on/off and file;
  and for the heading and spell name separately, text, font, size, bold/italic, fill
  and gradient colours with fade direction, outline colour and width, and Y offset.
  Image size, opacity and offset, and the staff's spin count, are set in the
  settings file
- **Warns on missing fonts** — tells you in chat if the banner font is not installed
  rather than silently substituting

## Commands

| Command | Effect |
|---------|--------|
| `/blulearn` or `/bl` | Toggle the config window |

Updating from 1.1 or earlier, the config window opens at its default position once;
it remembers where you move it from then on.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- **[Thorny](https://github.com/ThornyFFXI)** — the prototype blulearn grew out of, the
  bundled `gdifonts` library (MIT, © 2023 ThornyFFXI), and everything they do for Ashita
  and the wider FFXI community
