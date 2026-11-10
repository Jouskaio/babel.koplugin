# Babel for KOReader

A small KOReader plugin that sends your reading statistics (time and pages read each day, per
book) to your Babel server, where they join your own statistics: reading time and pages in "My
statistics" and the yearly wrap, reading days and streaks (and so the badges).

## Install

**Easiest: KOReader's App Store.** Install the
[App Store plugin](https://github.com/omer-faruq/appstore.koplugin), open Tools › App Store and
look for "babel.koplugin" (`Jouskaio/babel.koplugin`): it installs the plugin and keeps it
up to date.

**By hand:**

1. Download `babel.koplugin.zip` from the "Download" page of your Babel site (or zip the
   `babel.koplugin` folder of this repository).
2. Unzip it and copy the `babel.koplugin` folder into KOReader's `plugins` folder on the
   e-reader (over USB, or with the e-reader's file manager: `koreader/plugins/`).
3. Restart KOReader. The plugin appears in Tools › Babel.

## Use

- Set up **Progress sync** first (Tools › Progress sync › Custom sync server): this plugin uses
  its address and login. The Babel app gives you all three in Account.
- Tools › Babel › *Send reading statistics now*, or leave *Send automatically when closing a book*
  on (it sends only when the e-reader is already online).
- Babel's Account page shows when statistics last came and for how many books.

## Books on the e-reader

The plugin also brings your Babel books to the e-reader, into a `Babel` folder (in KOReader's home
folder), named `Author - Title.epub`:

- Mark a book "On my e-reader" in Babel (its sheet in the library), or choose *Download the whole
  library* in Tools › Babel.
- Tools › Babel › *Download my Babel books now*, or leave *Download new books when online* on: when
  the e-reader goes online it checks, at most once an hour, and downloads what is missing, one book
  after the other, in a background process: the e-reader stays usable meanwhile. Tools › Babel › *Downloads and
  version* shows the plugin's version and, in detail, where the downloads and sends stand. A big
  download that stopped is continued where it left off.
- A book downloaded this way is the very file of your library, so its reading progress syncs with
  Babel without any link to make.

## One button

Tools › Babel › **Sync with Babel** does it all, in this order: sends the reading statistics and the reading
progress of the books read lately (Babel shows it, and its reader opens the book there), sends
the e-reader's books Babel lacks, downloads the books marked "On my e-reader" (a book already on
the e-reader, in any folder, is not downloaded again), then tidies the Babel folder: a copy of a
book that is also elsewhere on the e-reader is removed (the original stays), and finished books
too when *Remove finished books* is on. One message tells what happened. It also runs by itself
when the e-reader goes online (at most once an hour); the other entries are under *Options*.

## Books to Babel, and shortcuts

- *Send the e-reader's books to Babel* scans KOReader's home folder (except the Babel folder) for
  EPUB, PDF and comics Babel does not have, and sends them. They are ticked "On my e-reader" in
  Babel, like any book the e-reader reports for the first time (progress, statistics, WebDAV).
- Three actions can be put anywhere KOReader takes actions (a gesture, a profile, the Bookshelf
  start menu through *System action…*): *Babel: send reading statistics*, *Babel: download my
  books*, *Babel: send the e-reader's books*.
- Everything the plugin does shows the e-reader as connected in Babel's Account page.

## Finished books, highlights, clean-up

- When you close a book you marked as finished, Babel marks it finished too (and it leaves the
  list of books to download).
- Your highlights and notes are sent to Babel as annotations (each is sent once).
- *Remove finished books from the Babel folder* (off by default) deletes, from the Babel folder,
  the books this plugin downloaded that are no longer on the e-reader list. It never deletes a
  file it did not download.
- *Test the connection to Babel* tells you whether the e-reader reaches Babel and is logged in.
- Each of these can be switched off in Tools › Babel.

## BOOX sleep screens

On a BOOX, the system draws the sleep and power-off screens, not KOReader: KOReader's screensaver
settings, and Storefront's *Random from folder*, have no effect there. Tools › Babel › *BOOX sleep
screens* (only on a BOOX) brings the random rotation back:

- *Random sleep screen* and *Random power-off screen*: each time the e-reader wakes up with
  KOReader open (and when KOReader starts), Babel draws an image at random from the folder and
  hands it to BOOX for the next sleep, and another one for the next power-off. It never draws the
  same image twice in a row.
- *Folder*: by default KOReader's screensaver folder (`koreader/screensavers`, where Storefront
  puts the wallpapers you install), with its subfolders. PNG, JPEG and BMP under 10 MB. Long-press
  it to go back to the default folder.
- *Change now* draws new images at once and says which.
- It goes through BOOX's own `onyx.action.SCREENSAVER` broadcast (what *Set as screensaver* does).
  The random sleep screen replaces BOOX's own list of sleep images.

## Bookshelf themes

For the [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) plugin's home screen, Tools ›
Babel › *Bookshelf themes* lists Babel's own themes: **Cabinet de lecture** (dark academia:
walnut panelling and a banker's lamp), **Nébuleuse** (a nebula sky and crystals), **Crypte** (stone
and candlelight), **Arabesque** (art nouveau, a Gallé vase and a Tiffany lamp) and **Émeraude** (art
deco, green and gold). Each brings a plank, two ornaments, and a light wallpaper and colours for
day with dark ones for night: Bookshelf switches to them when you turn on KOReader's night mode.

- Tick as many as you like: each is installed for Bookshelf at once (into
  `koreader/settings/bookshelf/ornaments`), and kept up to date when the plugin is. Untick one to
  remove it. Then choose a theme in Bookshelf's Theme library (a shelf can have its own).
- *Add my own theme (folder or .zip)…* takes a theme pack you have on the e-reader, unpacks it
  when it is a zip, and checks it first: a `theme` folder (`theme.json`, `colours.json`,
  wallpaper, `plank.left/middle/right.png` of the same height) and SVG or PNG ornaments
  beside it. What Bookshelf could not use is refused, and what it would ignore is pointed out.
  *My added themes* removes one again.
- The plugin only ever removes the themes it installed, never a pack you copied there yourself.

The themes are drawn by `scripts/koreader-themes/` in Babel's repository
(`node scripts/koreader-themes/build.mjs`, with Playwright).

The data stays between your e-reader and your Babel server.
