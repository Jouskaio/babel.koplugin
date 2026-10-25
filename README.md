# Babel for KOReader

A small KOReader plugin that sends your reading statistics (time and pages read each day, per
book) to your Babel server, where they join your own statistics: reading time and pages in "My
statistics" and the yearly wrap, reading days and streaks (and so the badges).

## Install

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

The data stays between your e-reader and your Babel server.
