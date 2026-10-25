# kuvascript

[Example resulting photobook](https://github.com/user-attachments/assets/a4004e69-7bc7-48d0-93f7-5a7f31c511f1)

**kuvascript** turns a folder of pictures and a small text file into a photobook you can open in any web
browser: a book on screen, with pages you can drag, flip with the arrow keys, or jump around in by page number.

You describe the book in a file called `photobook.conf`: its title, how many pictures go on a page, how big they
are, which picture goes where, optional covers, captions and chapter pages. kuvascript reads that file, prepares
every picture at exactly the size it will be shown, and writes a self-contained folder (`pb.html` plus the
pictures) that you can open locally, copy to a USB stick, or put on any web server. No server code, no
JavaScript libraries, no internet needed to view it.

```
photobook/                          output/
  photobook.conf        ───►          pb.html        open this in a browser
  cover.jpg                           images/
  IMG_0001.jpg                          IMG_0001-3fa91c0d….jpg
  IMG_0002.jpg                          …
  …
```

It is written in Free Pascal and has no dependencies beyond the Free Pascal compiler itself.

## The name

*Kuva* is the Finnish word for picture, and *script* is, well, a script. Put together, kuvascript is a
script for pictures: instead of dragging photos around in a layout editor, you write down how your photobook
should look, in `photobook.conf`, and let the tool build it. A few plain lines (`pic`, `text`, `chapter`, a
`layout`) are all the "programming" there is, and the same file always gives the same book.

## Quick start

You need the [Free Pascal](https://www.freepascal.org/) compiler (`fpc`) and `make`.

```sh
make                       # builds bin/kuvascript
make example               # builds examples/hello into examples/hello/output
xdg-open examples/hello/output/pb.html      # or just open that file in your browser
```

Then make your own: put your pictures and a `photobook.conf` in a folder and run

```sh
bin/kuvascript path/to/your/folder
```

The result is in `path/to/your/folder/output/`. Run it again after changing the file: only pictures that are
new or changed are processed again, so a second run takes a moment.

## The photobook.conf language

A file is a list of lines. It starts with the settings of the book, then lists what goes on its pages.
A comment is a whole line that starts with `--`; blank lines are ignored.

```
-- My trip to Semarang
title My trip to Semarang
-- optional covers, each with an optional caption and subcaption
front crop TL cover.jpg
caption bottom My trip to Semarang
subcaption July 2024
back last.jpg

-- each page has 2 x 2 cells (1 to 3 each way)
layout rows 2 columns 2
-- the size of a picture in pixels, by orientation
portrait width 400 height 600
landscape width 400 height 300

-- a page of its own with just a title
chapter The old town

pic IMG_0001.jpg
-- keep the top left part if the picture has to be cropped
pic crop TL IMG_0002.jpg
-- a caption: \n is a line break, \\ a backslash
text Lunch at the harbour\nwith friends
-- an empty cell, say a place to sign when printed
text
pic IMG_0003.jpg
```

The things to know:

* **Order matters** at the top: `title`, then optionally `front` and `back` (each with its own optional
  `caption` and `subcaption` right after it), then `layout`, `portrait`, `landscape`.
* **Cells fill pages in order.** With a 2 x 2 layout every four `pic`/`text` lines make a page. The last page
  may be left short. A `chapter` takes a whole page, so it can only appear when the page before it is complete
  (kuvascript tells you how many cells are missing; use bare `text` lines to fill them).
* **Free text and paths go last on their line and need no quotes**, so spaces are fine
  (`pic my holiday/photo 1.jpg`).
* **`crop`** is one of `TL` `TR` `BL` `BR` `C` (default `C`, the center). It decides which part of a picture is
  kept when the picture does not have the shape of its cell.
* **Pictures** can be `.jpg`, `.jpeg` or `.png`, found relative to the folder holding `photobook.conf`.
  Rotated photos (EXIF orientation) are handled.

The full grammar and every rule is in [docs/grammar.txt](docs/grammar.txt).

Mistakes are reported with their line number, as many at a time as can be found. Problems in the file itself come
first; once it reads cleanly, missing pictures are reported next:

```
photobook.conf:14: error: chapter found on a partly filled page (3 of 4 cells); 1 more pic/text needed before it. Use bare "text" lines to fill the rest with blanks.
photobook.conf:21: error: unknown escape "\q" (only \n and \\ exist)
```

```
photobook.conf:23: error: file not found: "IMG_0099.jpg"
```

## How it works

1. **Parse** `photobook.conf` and check it: the order of the settings, the numbers, the escapes, the pages
   against the layout.
2. **Check the files**: every picture and cover must exist and be a JPEG or PNG.
3. **Render the pictures.** Every picture is looked at to see whether it is portrait or landscape (taller than
   wide, or not), then scaled to cover the configured size for that orientation and cropped at its `crop`
   anchor. The result is saved as a JPEG named after the original plus a fingerprint of the settings
   (`IMG_0001-3fa91c0d65b1e2aa.jpg`), which is what makes later runs fast: a picture that is already there and
   newer than its source is left alone. Big photos are decoded at a fraction of their size when that is all
   that is needed. Several pictures are rendered at the same time (see `-j`).
4. **Write `pb.html`**: the viewer template, with the title and the whole book (a JSON description of pages,
   cells and picture files) filled in.

### Sizes and the shape of the page

`portrait` and `landscape` are the sizes a picture gets in a cell. A grid **cell** is the box that holds either:
as wide as the wider of the two and as tall as the taller of the two. A picture smaller than the box is centered
in it. A **page** is `rows x columns` such boxes with some spacing, so the shape of the page follows from your
layout and your two sizes. There is no separate page size to configure.

```
portrait 800x1200, landscape 800x533             portrait 800x1200, landscape 1200x800

cell box = 800x1200                              cell box = 1200x1200  (warning, see below)
┌────────┐   ┌────────┐                          ┌──────────────┐   ┌──────────────┐
│        │   │        │                          │ ┌────────┐   │   │              │
│        │   │        │                          │ │        │   │   │              │
│        │   ├────────┤ landscape, centered      │ │        │   │   ├──────────────┤
│        │   │        │                          │ │        │   │   │              │
│        │   ├────────┤                          │ └────────┘   │   │              │
└────────┘   └────────┘                          └──────────────┘   └──────────────┘
 portrait     landscape                           portrait is only 2/3 of the box wide
```

When one size fits inside the other (left) the box is snug. When neither does (right) kuvascript still works,
but warns that part of every cell stays empty and suggests a landscape size that nests:

```
photobook.conf:5: warning: portrait 800x1200 and landscape 1200x800 do not fit inside each other, so the cell box is 1200x1200: portrait pictures fill 67% of it and landscape ones 67%. For a snug fit, make one size fit inside the other, e.g. landscape width 800 height 533.
```

`portrait` must be taller than wide and `landscape` wider than tall, otherwise it is an error.

The space between cells and around the edge of the page is decided by the **template**, not by
`photobook.conf` (see below).

### Covers

`front` and `back` are plain pictures. A cover is cut to the size of **one cell** (the bigger of the portrait and
landscape sizes in each direction), what a page with `layout rows 1 columns 1` would hold, whatever the layout is;
the viewer then fits it to the page. Like `pic`, it takes `crop TL|TR|BL|BR|C` to say which part of the picture
survives the cut:

```
front crop TL cover.jpg
caption bottom Memory of Semarang
subcaption July 2024
back crop BR last.jpg
caption middle Until next time
```

`caption` and `subcaption` write on the cover. A `caption` takes a position (`top`, `middle` or `bottom`) and then
the text, with the same `\n` and `\\` escapes as everywhere else. A `subcaption` is just its text: the template
draws it right below the caption in a smaller font, so it has no position of its own. A caption or subcaption
without any text only earns a warning. A `caption` has to come directly after the `front` or `back` it belongs to, and a
`subcaption` directly after a `caption`; anywhere else it is an error. The `title` is not drawn on the cover: it
is the name of the book (browser tab and page header), the captions are what the cover says.

With a front cover the book starts closed, showing the cover; opening it shows a blank inside page next to the
first page, the way a printed book does. The back cover works the same way at the other end. Without them the
book simply starts with its first page.

## The viewer

`pb.html` is a book you can handle:

* Drag a page by its corner and let go (a quick flick completes the turn), click either side of the book, use
  `←` `→` (also `Page Up`/`Page Down`, `Space`, `Home`, `End`), the arrow buttons, the page numbers below the
  book, or type a page number.
* Turns never wait for each other: press or hold a key and pages fly over each other as fast as you go.
* The footer shows the chapter you are in. The address bar keeps the page (`pb.html#12`), so a reload or a shared
  link opens the same page.
* On narrow screens it shows one page at a time instead of a spread.

## Making it look different: the template

The viewer is a single file, [template/viewer.html](template/viewer.html), which kuvascript fills in. Everything
about how the book looks and behaves is in there, so you can change it, or write your own and pass it with
`--template`.

The template has two placeholders:

| Placeholder     | Replaced with                                        |
| --------------- | ---------------------------------------------------- |
| `__TITLE__`     | the book title, HTML-escaped                         |
| `__BOOK_JSON__` | a JSON object describing the book (pages, cells…)    |

The shape of that JSON object is described in the comment at the top of the template. Some things you might
want to change in it:

* **Spacing**: `GAP` (between cells) and `MARGIN` (around the page) at the top of the script, as fractions of
  the shorter side of a cell.
* **Page bend**: while a page turns it is cut into strips that fold against each other. All of that is in two
  blocks marked `BEND`, one in the CSS and one in the script. Delete both and the pages turn rigid.
* **Colors, fonts, shadows, speed**: the CSS and the few numbers at the top of the animation code.

## Command line

```
kuvascript [options] <directory>

  -o, --output <dir>      where to write pb.html and images/  (default <directory>/output)
  -t, --template <file>   viewer template (default template/viewer.html, found next to or above the
                          executable, or in ../share/kuvascript after `make install`)
  -q, --quality <1-100>   JPEG quality of the rendered pictures (default 90)
  -j, --jobs <n>          pictures to render at the same time; 0 (the default) means one per available
                          thread, like make -j; 1 renders one at a time. -jN and --jobs=N work too
  -f, --force             render every picture again
  -c, --check             only check photobook.conf and the files, write nothing
      --quiet             no progress output
  -V, --version
  -h, --help
```

Exit status: `0` on success, `1` if `photobook.conf` or the files it names have errors, `2` for anything else
(bad command line, missing template, unwritable output...). Warnings do not change the exit status.

## Building and testing

```sh
make            # bin/kuvascript
make test       # unit tests (parser, image code, build); run from the repository root
make install    # PREFIX=/usr/local by default; installs the program and the template
make clean
```

It is developed with Free Pascal 3.3.1 (trunk). It should build with 3.2.x too: kuvascript then applies EXIF
rotation itself, because only the newer `fcl-image` does that while decoding. That path is checked against
reference transformations but has not been run under 3.2.

### Project layout

```
src/kuvascript.lpr     the command line program
src/kvtypes.pas        the model (pages, cells...) and the error/warning collector
src/kvparser.pas       photobook.conf parser and checks
src/kvimage.pas        reading sizes and EXIF, decoding, cover-crop, resizing, JPEG output
src/kvbuild.pas        renders pictures, builds the JSON, fills in the template
template/viewer.html   the viewer
docs/grammar.txt       the photobook.conf grammar and its rules
examples/hello/        a small example book with generated pictures
tests/                 fpcunit tests
```

## Good to know

* Output pictures are always JPEG. PNG input works, but transparency is dropped. Colour profiles are not
  converted: wide-gamut photos may look a little different from how your editor shows them.
* A 20 megapixel photo takes about a second to prepare, and pictures are prepared in parallel (`-j`, by
  default one per available thread): 130 such photos took 70 seconds on one thread and 6 seconds on 16. Later
  runs only redo what changed, so they take seconds. Each thread holds one photo in memory at a time, so
  use `-j 2` or so on a small machine. The result is the same whatever `-j` is.
* Files in `images/` that are no longer used (after you change the book) are not deleted; remove the folder
  to start clean.

## License

MIT, see [LICENSE](LICENSE).
