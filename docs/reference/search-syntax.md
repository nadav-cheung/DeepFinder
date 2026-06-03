# Search Syntax Reference

This is the complete reference for DeepFinder's query parser syntax. Every operator, modifier, wildcard, and escape rule is documented here.

## Plain Text Search

Space-separated terms are ANDed. Matching is **case-insensitive** and **substring** -- `report` matches `Report.txt`, `sales_report.pdf`, `REPORT_FINAL.xlsx`.

```bash
deepfinder "quarterly report"   # Files with BOTH "quarterly" AND "report"
```

> **Unicode handling**: All filenames and queries are NFC-normalized (`precomposedStringWithCanonicalMapping`). This means accented characters like `é` are stored and matched in their composed form. You do not need to worry about whether your input uses composed or decomposed Unicode -- DeepFinder normalizes both sides automatically.

## Wildcards

Use `*` (any sequence) and `?` (single character):

```bash
deepfinder "*.pdf"              # All PDF files
deepfinder "report_??.txt"      # report_01.txt, report_ab.txt
deepfinder "*vacation*"         # Any file with "vacation" in the name
```

## Boolean Operators

| Operator | Symbol | Example |
|----------|--------|---------|
| AND | (space) | `report 2026` -- both terms must match |
| OR | `\|` | `report \| memo` -- either term matches |
| NOT | `!` | `report !draft` -- "report" but NOT "draft" |
| Grouping | `()` | `(report \| memo) 2026` -- AND with grouped OR |

```bash
deepfinder "(report | memo) !draft"  # Report or memo, but not drafts
deepfinder "budget !2025"            # Budget documents, excluding 2025
```

## Regular Expressions

Prefix with `regex:`:

```bash
deepfinder "regex:^report_\d{4}\.pdf"   # report_2026.pdf, report_2025.pdf
deepfinder "regex:\.[a-z]{2,4}$"        # Files with 2-4 char extensions
```

## Path Qualifiers

Restrict to a specific directory using **backslash-space** (`\ `):

```bash
deepfinder "Projects\ report"    # "report" anywhere, but only in paths containing "Projects"
deepfinder "src\ *.swift"        # Swift files under directories named "src"
```

The word before `\ ` is matched against path components (directory names). The rest is the regular query.

## Modifiers

Modifiers are `key:value` pairs that apply metadata filters:

```bash
deepfinder "ext:pdf report"           # PDF files containing "report"
deepfinder "size:>10mb *.mp4"         # MP4 files larger than 10 MB
deepfinder "dm:today report"          # Reports modified today
deepfinder "file: budget"             # Only files (not folders) matching "budget"
deepfinder "folder: project"          # Only folders matching "project"
deepfinder "case:sensitive README"    # Case-sensitive match for "README"
```

## Escaping Special Characters

Escape operators with a backslash:

```bash
deepfinder "special\!file"     # Literal "special!file"
deepfinder "a\|b"              # Literal "a|b"
deepfinder "\(note\)"          # Literal "(note)"
```

## Metadata Filters

### Size (`size:`)

Filter by file size in bytes. Supports human-readable units: `b`, `kb`, `mb`, `gb`, `tb`.

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

### Date Modified (`dm:`)

Filter by modification date:

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

### Extension (`ext:`)

Filter by file extension. Multiple extensions separated by `;`:

```bash
deepfinder "ext:pdf"                      # PDF files
deepfinder "ext:jpg;png;heic"             # Common image formats
deepfinder "ext:mp4;mkv;mov"             # Video files
```

### File Type (`file:`, `folder:`)

```bash
deepfinder "file: budget"                 # Files only (no directories)
deepfinder "folder: project"              # Directories only
```

### Case Sensitivity (`case:`)

```bash
deepfinder "case:sensitive README"        # Exactly "README" (not "readme")
deepfinder "case:insensitive README"      # Explicit case-insensitive (default)
```

### Path Depth (`depth:`)

Filter directories by how many levels deep they are from root:

```bash
deepfinder "depth:<=3 folder:"            # Folders at most 3 levels deep
deepfinder "depth:>=5"                    # Files at least 5 levels deep
```

### Numeric Metadata Filters

For media files, these metadata filters support the same comparison operators as `size:` (`>`, `<`, `>=`, `<=`, `range`):

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

### Text Metadata Filters

For media files with embedded tags:

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

For step-by-step guides, see [Find Files](../how-to/find-files.md) and [Exact Search](../how-to/exact-search.md).
