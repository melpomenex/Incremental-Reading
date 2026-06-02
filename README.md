# Incremental Reading

A spaced repetition plugin for KOReader. Export highlighted passages from e-books into a review queue and retain what you read by periodically reviewing key excerpts.

Uses the **SM-20 algorithm with Bayesian smoothing** for interval scheduling — the same family of algorithms used by modern Anki variants.

## Install

1. Download or clone this repository
2. Copy the `incrementalreading.koreader` folder into your KOReader plugins directory:
   - **Kindle**: `koreader/plugins/`
   - **Kobo**: `.adds/koreader/plugins/`
   - **Android**: `Android/data/org.koreader.koreader/files/plugins/`
   - **Desktop (Linux/Mac/Windows)**: `<koreader_install>/plugins/`
3. Restart KOReader — the plugin appears under **More tools → Review Queue**

Or from a terminal:

```sh
git clone https://github.com/melpomenex/Incremental-Reading.git
cp -r Incremental-Reading/incrementalreading.koreader <your_plugins_dir>/
```

## How it works

1. **Highlight** a passage in any document and tap **"Export to SRS"** in the highlight dialog
2. The passage becomes a flashcard in your review queue
3. When cards come due, grade them as **Again**, **Hard**, **Good**, or **Easy**
4. The SM-20 engine schedules the next review based on your grading history
5. Tap the back arrow on any card to jump to its location in the source document

<img src="review_queue.png" width="33%" alt="Review queue">

## Menu

Accessed under **More tools → Review Queue (N)** where N is the number of due cards.

| Item | Description |
|------|-------------|
| Start review | Open the review session for all due cards |
| Browse cards | View, read, and delete existing cards |
| Statistics | Total cards, due count, review count, average interval |
| Reset database | Delete all cards, reviews, and scheduling data |

## Review controls

| Input | Action |
|-------|--------|
| Again / Hard / Good / Easy buttons | Grade the current card |
| Swipe up or left | Grade "Good" and advance |
| Swipe down or right | Go back to previous card |
| Page forward key | Grade "Good" and advance |
| Page back key | Go back to previous card |
| Back arrow in title bar | Jump to source location in the original document |

## Gesture binding

The action **"Open review queue"** is registered with KOReader's dispatcher. You can bind it to any gesture or key via **Gear → Navigation → Gesture manager**.

## Data storage

- Database: `<koreader_settings>/incremental_reading.sqlite3`
- Journal mode: WAL (falls back to TRUNCATE on unsupported devices)
- Schema version: `20260530`
