# Changelog

## 0.2.0 (2026-11-18)

- **Renamed from Inkwell to Strokebook.** Existing libraries, settings and `.inkwell` files keep working: an existing `Inkwell` support folder (also in iCloud Drive and Google Drive) is reused, the bundle identifier and file format are unchanged.
- **Fixed two crashes in the GoodNotes importer**, found by fuzzing: record and field lengths of 2^63 or more were converted to `Int` before being range-checked, and non-finite or huge floats in a stroke blob overflowed an `Int` conversion. A damaged or hostile `.goodnotes` file now fails with an error instead of closing the app.
- Added a fuzz harness (`Tools/fuzz`) covering notebook files, encryption, images, PDFs, GoodNotes exports and the maths parser, and regression tests (250 checks).
- Added GitHub Actions CI, issue templates and contributing notes.

## 0.1.0 (2026-11-15)

First public release.

- Pressure-sensitive ink with a 2D 1€ filter, motion prediction and Pen Lab pressure curves
- Pen, highlighter, precise and stroke eraser, lasso, text boxes, images, links, laser pointer
- Shape and arrow recognition, scribble to erase, handwriting to text, auto-answered sums
- PDF import, annotation, text-snapping highlighter, search and vector export
- Search across handwriting, typed text and PDF text
- Flash cards (SM-2), audio recording with transcription, ruler, zoom window
- Folders, password lock, atomic saves with recovery, iCloud/Google Drive library locations
- GoodNotes notebook import (pages, templates, pen strokes)
