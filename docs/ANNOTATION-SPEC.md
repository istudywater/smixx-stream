# Live annotation and student handout specification

Version 0.2 · November 6, 2026 · Product: Smixx Stream

Status: implemented first pass in engineering alpha **0.3.0**. The owner revised the footer on November 6: logo bottom left, filename and page/time bottom right. Live annotation, PNG export and recording integration are implemented; shapes, text and annotated-PDF export remain follow-up work. Hardware/long-session acceptance is separate from the short functional checks below.

## 1. Teaching outcome

An educator can navigate a PDF directly in Program preview, mark up the visible page while students watch, and export a clearly attributed PNG. For a local video, the educator can pause at a frame, annotate it, and export that frame with its source time. The same visible lesson composition must appear in the clean Program output and in a Program recording.

Primary interaction surface: Program preview inside the studio. The student-facing Program window remains free of toolbars, menus, selection handles and other editing controls. An optional presentation-window editing mode can come later; it must use the same document/annotation state, not a second independent editor.

## 2. Required first-release tools

| Tool | Interaction | Visible in student output? |
| --- | --- | --- |
| Hand | Drag to pan; pinch to zoom; modifier + wheel for mouse zoom | Resulting content transform only |
| Pen | Freehand stroke with selected color/width | Yes |
| Highlighter | Translucent freehand stroke | Yes |
| Eraser | Remove a whole stroke/object initially | Result only |
| Undo / Redo | Reverse/reapply completed actions within the current page/frame | Result only |
| Clear page/frame | Remove annotations from current context; undoable | Result only |
| Fit / Reset view | Return to fit and centered pan | Yes |
| Freeze & annotate | Preserve the exact displayed video frame and its source time | Frozen composition |
| Export PNG | Save the composed viewport with attribution footer | Creates a local artifact |

Arrow, rectangle, ellipse, editable text, object selection/movement and pressure-sensitive pen support are follow-up tools. Keep the data model extensible for them without requiring their UI in the first pass. Pen versus Hand must be a visible mode so navigation cannot accidentally draw. Space-drag temporarily pans; Escape cancels an unfinished stroke. Keyboard focus in text fields must take precedence over global shortcuts.

## 3. PDF navigation and annotation

- Drag and zoom work directly on the Program preview. Zoom stays anchored at the pointer/pinch center. The existing zoom slider may remain as an accessible alternative.
- Store pan/zoom per source; define reset behavior on page change (proposed default: fit the new page). Do not unexpectedly reuse a zoomed crop from a differently sized page.
- Re-render the PDF at suitable resolution as zoom changes. Stretching the original 1080p raster is insufficient for close examination of notation.
- Use source-page coordinates for annotations, independent of UI pixels and output resolution. The first implementation stores normalized coordinates on the oriented PDF crop box. Page rotation and crop/media-box origins are part of the coordinate conversion.
- Marks move and scale with the page. Moving the camera/view must never alter annotation coordinates. Strokes outside the page are clipped/rejected, not attached to neighboring pages or letterbox bars.
- Each page has independent annotation history. Leaving and returning to a page restores its marks. Clearing one page must not affect others.
- The footer uses the physical 1-based page index and document page count: `page 3 of 12`. PDF printed labels such as roman numerals may be added later, but cannot replace the required index/count.
- Preserve the source PDF. First-pass annotation persistence uses a versioned sidecar/session document; writing an annotated PDF copy is a separate export feature, never an automatic overwrite.

## 4. Video freeze-frame behavior

For local media, Freeze & annotate pauses the player and retains an immutable copy of the exact frame currently displayed, its media presentation time and its source identity. It must use the frame's timestamp, not the player time sampled later or the recording elapsed time. Existing video-delay compensation makes this distinction important.

Drawing occurs on that retained image. Seeking or switching sources cannot silently change the pixels underneath an annotation. Resume playback hides the frame's marks but retains the annotated snapshot for later export. Switching to another source preserves the snapshot. Returning to a particular timestamp does not automatically reuse a different frame's annotations unless the user selects that snapshot.

For browser/camera/window capture, Freeze picture can retain a snapshot but does not imply the external app paused playback or audio. Do not invent a media timestamp from wall-clock capture time. If no trustworthy source filename/time exists, the source is outside the initial attributed-video PNG workflow; offer an explicit user-entered source label/location later. Never label wall-clock time as video time.

For local audio-only files, there is no video frame to annotate in the first release. Display a clear explanation rather than exporting a misleading black video handout.

## 5. Mandatory PNG footer

The footer has the **Smixx Stream logo at bottom left** and **two right-aligned attribution lines at bottom right**. Use the five-bar violet waveform and white/violet wordmark from the brand kit; omit the small marketing tagline.

Bottom-right attribution:

PDF example:

```text
Autumn Leaves.pdf
page 3 of 12
```

Video example:

```text
Right-hand technique.mp4
00:02:14.320
```

These are separate lines, not one combined caption. The filename and location share a right edge; neither belongs below the logo. Do not substitute the exported PNG filename for the original source filename.

### Content rules

1. First line: the source file's complete basename **including extension**, preserving Unicode and capitalization. Exclude absolute paths and parent folders. The current source display name drops the extension, so export must read an explicit original filename field rather than reuse the UI label.
2. PDF second line: literal format `page {1-based index} of {total pages}`, for example `page 1 of 1`.
3. Video second line: elapsed source-media time `HH:MM:SS.mmm`, for example `00:00:00.000` or `01:04:09.125`. Hours may exceed two digits. Round to milliseconds from the captured frame's rational presentation time; do not use the lesson recording clock.
4. The Smixx Stream logo is required at bottom left. No date, source filesystem path or extra metadata row is required. Additional PNG metadata cannot replace the visible footer.
5. Source identity, page/count or frame/time are captured atomically with the exported composition. A source/page change during a save dialog must not mix old pixels with new attribution.
6. If required attribution is unavailable or inconsistent, block attributed export with an explanation. Do not silently substitute a different page/time or export a blank location line.

### Layout rules

- Default export is the visible 1920 × 1080 Program viewport **plus a footer band below it**. Proposed footer height: 100 pixels, making a default 1920 × 1180 PNG. This preserves the whole Program image without obscuring, cropping or shrinking its content.
- Opaque near-black footer, white text, at least 24 pixels of left/right padding and comfortable top/bottom padding. Both attribution lines share the same right alignment. Reserve a separate left region for the logo with at least 48 pixels of clear space between logo and attribution. Proposed font size: 24 pixels with a system sans-serif and 32-pixel line spacing.
- Text must remain readable at standard student viewing size. The first implementation keeps the footer at 100 pixels and text at 24 pixels when widening for long names. Other user-selectable export resolutions are deferred.
- Never silently truncate an identifying filename. Keep filenames at a readable 24 pixels. Automatically widen the export and scale the Program picture proportionally when needed, up to 8192 pixels wide; beyond this, explain that a shorter source filename is needed. Do not wrap the location onto a third line or omit the extension.
- Export uses an explicit sRGB color space and opaque background. It is generated from Program composition at export resolution, not an operating-system screenshot of the window.
- Toolbars, mouse cursor, selection handles, focus rings, recording indicators and dialog controls are excluded. Completed annotations are included. A partially drawn stroke must be committed or cancelled before snapshotting.

### File handling

Use a native save dialog. Suggested names: `Autumn Leaves-page-03-of-12.png` and `Right-hand technique-00-02-14-320.png`. Sanitize filename characters without altering the visible citation. Preserve source files and prevent silent replacement of existing exports. Write atomically and report success only when the file is complete. Offer Show in Finder.

Visible-viewport export is the initial behavior: students receive what the teacher selected, including the current crop/zoom and marks. A future whole-PDF-page export must be a separately labeled option, not an implicit change of scope.

## 6. Architecture and persistence

Use a shared immutable Program composition for the preview, external display, PNG exporter and recorder. Source pixels/page rendering, content transform and completed vector marks are composited before any output-specific footer. The PNG attribution band is applied **only by the PNG exporter**; it is not automatically burned into live Program or recordings.

Proposed model:

- Source identity: stable document/media ID, bookmark, original basename, optional content fingerprint/version.
- PDF context: source ID, page index/count at export, rotation and page geometry.
- Video snapshot: source ID, immutable frame reference, media presentation timestamp and snapshot ID.
- View transform: fit/fill base geometry, zoom and bounded pan offset.
- Annotation: UUID, tool, color, opacity, width in source coordinates, vector points and creation order.
- Per-context undo/redo history and versioned persisted annotation document.
- Export snapshot: immutable pixels/source context/transform/marks/citation fields.

Do not attach annotations to slot numbers alone: replacing a file in slot 1 must not place the previous document's marks onto the replacement. A changed source fingerprint requires explicit relinking or a fresh context. Store files separately from the original PDF/video; back up unreadable or older state on migration.

The shared renderer accepts image/scaling/zoom/slate, bounded pan and source-coordinate strokes. Preview, clean Program, PNG export and recording all use this renderer. Export and recording must use the same coordinate conversion and clipping rules.

## 7. Relationship to recording

A teacher starts local recording, teaches with source changes, pan/zoom, playback and annotations, then stops/saves an MP4 for later upload. Recording captures the final Program composition and enabled Program audio, excluding Monitor-only listening and app controls. The recorder must work without a TV, virtual driver or conference client.

Alpha 0.3.0 renders annotations into the common composition. Automated decoding verifies ink in an encoded MP4, and a native 51-second recording was inspected to confirm a new stroke drawn during recording appears in the saved video. Physical microphone/camera synchronization and hour-long teaching sessions remain to be tested.

PNG citations do not become automatic recording overlays. A persistent filename/page/time recording overlay could be added later as a separate option. Uploading, account authentication and hosting are out of scope: provide a completed local video that the teacher can upload normally.

Distinguish:

- **Pause presentation:** neutral slate and silent Program audio, still included in the recording timeline.
- **Stop & Save recording:** finalize the MP4. Live presentation may continue.
- **Stop presenting:** disconnect the display window; recording may continue.
- **Pause recording / trim timeline:** deferred; do not label presentation pause as this feature.

## 8. Acceptance tests

1. Pan/zoom a portrait and landscape PDF, including rotated/cropped pages. Marks remain on the same notation through resize, output-resolution changes and page return.
2. Save a PNG of page 3 of 12. Verify the Smixx Stream logo is bottom left, the original filename with extension is bottom right, and `page 3 of 12` is directly below it, right-aligned.
3. Freeze local video at a known time, annotate, wait, then export. Verify footer time matches the retained frame, not the current player or recording clock.
4. Change page/source while a save dialog is open. The exported pixels, annotations and footer still describe the original snapshot.
5. Verify a Unicode filename and a very long filename remain identifiable and readable without leaking directory paths.
6. Compare student output, exported image content and a decoded recording frame for identical transforms and marks. PNG alone has its added footer band.
7. Undo/redo/clear affect only the current page/snapshot and survive expected navigation. Replacement files do not inherit unrelated marks.
8. Test full disk, cancelled export, unavailable file and permission loss; originals and previous exports remain intact.
9. Record source changes and annotations with microphone/media audio, Monitor off and no external output selected. Decode the saved MP4 and verify picture, sound and timing.
10. Confirm drawing/editing UI never appears in student output/export; keyboard and accessible controls work without a pointing device.

## 9. Suggested implementation order

1. Coordinate/annotation model, direct Hand/zoom interaction and high-resolution PDF rendering.
2. Pen/highlighter/eraser with per-page undo and persistence.
3. Attributed PNG exporter with exact footer and snapshot-consistency tests.
4. Local-video Freeze & annotate, source-time handling and snapshot persistence.
5. Recording integration acceptance with actual annotations, then shapes/text/annotated-PDF export.

References: [Apple PDFAnnotation](https://developer.apple.com/documentation/pdfkit/pdfannotation), [PDFView](https://developer.apple.com/documentation/pdfkit/pdfview). These supply framework capabilities; the interactions and export rules above are Smixx requirements.

## 10. First-pass implementation details

- Annotation archives live in `~/Library/Application Support/SmixxStream/Annotations/`: versioned JSON histories and lossless original frozen-frame PNGs. Original PDFs/videos are untouched. Corrupt/unsupported archives are preserved and automatic writes are disabled until recovered; no destructive migration is attempted.
- Source version identity hashes the standardized path, file size and modification time. Moving/replacing/modifying a file starts a new context; automatic relinking and content-hash comparison are not implemented.
- PDF marks are normalized to the oriented crop box. PDFKit rerasterizes for zoom up to 4× and applies rotation/crop offsets. Undo/redo keeps up to 50 prior edits per context and is persisted. Pan is session-local; source zoom is in the preset.
- Frozen frames are retained with their exact displayed media time. Play/seek hides marks; the Snapshots menu restores retained frames for annotation/export. Archives currently retain all snapshots; deletion/retention controls are follow-up work.
- Studio preview is the editing surface. Pointer input accounts for letterboxing inside the preview. Space-drag pans; pinch or Command/Option-scroll zooms at the pointer. With canvas focus, +/− zoom, arrows pan, 0 fits, Escape cancels a stroke and Command-Z/Shift-Command-Z undo/redo.
- PNG export is an immutable snapshot taken before the native save panel. A separate band holds the vector waveform/wordmark at left and right-aligned citation. Branding follows the existing concept kit; final production identity review remains open.
- Shapes, editable text, pressure input, exported annotated PDFs, arbitrary camera/browser attribution and drawing directly in the student-facing window are outside this first pass.
