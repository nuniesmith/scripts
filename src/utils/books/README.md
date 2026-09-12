# Moved to nuniesmith/shelfmark

The audiobook and ebook organiser that lived here is now its own repository:

**https://github.com/nuniesmith/shelfmark**

It grew past the size of a utility script — roughly 2,500 lines with its own
regression suite — and it has a second tool alongside it now for repairing
Audiobookshelf metadata, so it earns a repo of its own rather than a corner of
this one.

The commit history moved with it, so `git log` there still explains why each
piece of the parser behaves the way it does.

```bash
git clone https://github.com/nuniesmith/shelfmark.git
cd shelfmark
./run.sh "/path/to/messy/dump" --dry-run
```
