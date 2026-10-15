# Upstream

- Repository: https://github.com/MaryCache/imozuru
- Revision: `bfd99e5e72d8e8ec3297a71fafa1eafbb49787b2`
- Directory: `skills/imozuru/`
- License: MIT (included as `LICENSE` from the repository root)

Local adaptations:

- The description's topic placeholder uses `話題` instead of `<話題>` so the
  Codex skill validator accepts the frontmatter. The instructions and scripts
  are otherwise unchanged.
- Installation and upgrades go through the canonical `prompt/skills/imozuru/`
  source and the existing Nix/Home Manager projections for Claude, Codex, and Pi.

Runtime: Python 3.10 or newer, using only the standard library. PDF extraction
uses `pdftotext` / `pdftoppm` (Poppler), scanned-PDF OCR uses `tesseract`, and
YouTube subtitles use `yt-dlp`. HTML extraction can use `ax` when available and
otherwise uses the standard-library fallback. Manage any added tools through
Nix/Home Manager.
