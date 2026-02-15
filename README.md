# PhraseDeck – KOReader Plugin

Collect phrases from your books and study them with spaced repetition flashcards, right inside KOReader.

## Features

- **Highlight to Collect** – Select any text while reading, tap "Add to Deck" from the highlight menu, and save it as a flashcard.
- **Automatic Sentence Extraction** – The surrounding sentence is automatically captured as context (EPUB/HTML documents).
- **Editable Phrase** – Edit the selected phrase before saving. The sentence context remains read-only.
- **Personal Notes** – Add your own note or meaning to each card.
- **Spaced Repetition (SM-2)** – Study your cards with a built-in flashcard screen using the SM-2 scheduling algorithm (Again / Hard / Good / Easy).
- **Per-Book Decks** – Browse and study cards from a specific book or from all books at once.
- **Book Management** – Long-press a book in the study screen's book list to delete it and all its cards.
- **Daily New Card Limit** – Control how many new cards you see per day.
- **Randomize Cards** – Optionally randomize cards that share the same due date.
- **TSV Export** – Export cards to TSV files (phrase, sentence, note) for use on a PC or import into Anki.
- **Configurable Export Folder** – Choose where exported TSV files are saved.

## How to Use

### Adding Cards

1. Open a book in KOReader.
2. Long-press to select a word or phrase.
3. Tap **"Add to Deck"** in the highlight menu.
4. Edit the phrase if needed, add a note/meaning, and tap **Save**.

### Studying Cards

1. Open the main menu → **PhraseDeck** → **Study**.
2. The front of the card shows the phrase.
3. Tap **Show** to reveal the back (phrase, your note, and sentence context).
4. Rate your recall: **Again**, **Hard**, **Good**, or **Easy**.
5. Use the book icon to filter by a specific book.

### Exporting Cards

1. Open the main menu → **PhraseDeck** → **Export**.
2. Choose a specific book or export all books.
3. TSV files are saved to the configured export folder.

## File Structure

```
phrasedeck.koplugin/
├── _meta.lua            # Plugin metadata
├── main.lua             # Entry point, highlight menu, export, settings
├── phrasedeck_db.lua    # SQLite database, CRUD, SM-2 scheduling
├── phrasedeck_study.lua # Flashcard study screen UI
├── LICENSE              # GPLv3
└── README.md
```

## Data Storage

- **Database**: `phrasedeck/phrasedeck.sqlite3` in the KOReader data directory.
- **Settings**: `phrasedeck.lua` in the KOReader settings directory.
- **Exports**: Default export folder is `phrasedeck/exports/` in the KOReader data directory (configurable).

## License

This plugin is licensed under the [GNU General Public License v3.0](LICENSE).

---

*This plugin was developed with [Windsurf](https://windsurf.com) (AI-powered coding assistant).*
