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
  after the other.
- A book downloaded this way is the very file of your library, so its reading progress syncs with
  Babel without any link to make.

## Finished books, highlights, clean-up

- When you close a book you marked as finished, Babel marks it finished too (and it leaves the
  list of books to download).
- Your highlights and notes are sent to Babel as annotations (each is sent once).
- *Remove finished books from the Babel folder* (off by default) deletes, from the Babel folder,
  the books this plugin downloaded that are no longer on the e-reader list. It never deletes a
  file it did not download.
- *Test the connection to Babel* tells you whether the e-reader reaches Babel and is logged in.
- Each of these can be switched off in Tools › Babel.

The data stays between your e-reader and your Babel server.
