# Filter search results by file properties

## You want to filter by file properties

DeepFinder supports metadata modifiers -- `key:value` pairs you add to your search query to narrow results by size, date, type, and media-specific attributes.

---

### Filter by file size

Use the `size:` modifier with comparison operators. Units: `b`, `kb`, `mb`, `gb`, `tb`.

| Syntax | Meaning |
|--------|---------|
| `size:>10mb` | Larger than 10 megabytes |
| `size:<1gb` | Smaller than 1 gigabyte |
| `size:>=1kb` | At least 1 kilobyte |
| `size:<=500mb` | At most 500 megabytes |
| `size:100kb..1mb` | Between 100 KB and 1 MB |

```bash
deepfinder "size:>1gb *.mkv"              # MKV files over 1 GB
deepfinder "size:10mb..100mb *.pdf"       # PDFs between 10 MB and 100 MB
deepfinder "size:<1kb"                    # Files smaller than 1 KB
```

### Filter by modification date

Use the `dm:` modifier with date keywords or a range.

| Value | Meaning |
|-------|---------|
| `dm:today` | Modified today |
| `dm:yesterday` | Modified yesterday |
| `dm:thisweek` | Modified this week (Monday to now) |
| `dm:thismonth` | Modified this month |
| `dm:thisyear` | Modified this year |
| `dm:2026-01-01..2026-05-31` | Modified within a date range |

```bash
deepfinder "dm:today *.log"               # Log files modified today
deepfinder "dm:thisweek report"           # Reports modified this week
deepfinder "dm:2026-01-01..2026-03-31"    # All files from Q1 2026
```

### Filter by file extension

Use the `ext:` modifier. Separate multiple extensions with `;`.

```bash
deepfinder "ext:pdf"                      # PDF files
deepfinder "ext:jpg;png;heic"             # Common image formats
deepfinder "ext:mp4;mkv;mov"             # Video files
```

### Filter by file or folder

Use `file:` to match only files, or `folder:` to match only directories.

```bash
deepfinder "file: budget"                 # Files only (no directories)
deepfinder "folder: project"              # Directories only
```

### Filter by path depth

Use `depth:` to match items at a certain directory depth from root. Works with comparison operators.

```bash
deepfinder "depth:<=3 folder:"            # Folders at most 3 levels deep
deepfinder "depth:>=5"                    # Files at least 5 levels deep
```

### Filter by media dimensions and properties

For media files, these keys support the same comparison operators as `size:` (`>`, `<`, `>=`, `<=`, `range`).

| Key | Applies to | Example |
|-----|-----------|---------|
| `width:` | Image/video width in pixels | `width:>=3840` (4K+ width) |
| `height:` | Image/video height in pixels | `height:>1080` |
| `duration:` | Audio/video duration in seconds | `duration:>300` (longer than 5 min) |
| `pages:` or `pagecount:` | Document page count | `pages:>=50` |
| `fps:` | Video frames per second | `fps:>=60` |
| `bitrate:` | Audio/video bitrate in kbps | `bitrate:>320` |

```bash
deepfinder "width:>=3840 ext:jpg"          # High-res JPEG images
deepfinder "duration:60..300 ext:mp4"      # Videos between 1 and 5 minutes
deepfinder "pages:>100 ext:pdf"            # PDFs with more than 100 pages
```

### Filter by embedded media tags

For media files with embedded metadata (ID3, EXIF, etc.).

| Key | Applies to | Example |
|-----|-----------|---------|
| `artist:` | Music artist | `artist:"The Beatles"` |
| `album:` | Music album name | `album:"Abbey Road"` |
| `title:` | Track/file title | `title:"Bohemian Rhapsody"` |
| `genre:` | Music genre | `genre:rock` |
| `codec:` | Audio/video codec | `codec:h264` |

```bash
deepfinder "artist:mozart ext:flac"        # Mozart tracks in FLAC
deepfinder "genre:jazz ext:mp3"            # Jazz MP3s
deepfinder "codec:hevc ext:mp4"            # HEVC-encoded videos
```

---

### Filter by case sensitivity

Use `case:` to toggle case sensitivity for any query.

```bash
deepfinder "case:sensitive README"         # Match exactly "README" (not "readme")
deepfinder "case:insensitive README"       # Explicit case-insensitive (this is the default)
```

---

**Next**: [Search syntax reference](search-syntax.md) -- learn about boolean operators, wildcards, regex, and path qualifiers.
