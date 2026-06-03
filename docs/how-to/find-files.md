# How to Find Files

## You want to find files by name

This guide covers the most common file-finding techniques. You will learn how to search by keyword, match patterns with wildcards, and filter by file extension. For advanced search syntax (boolean operators, regular expressions, path qualifiers) see [Exact Search](exact-search.md). For filtering by size, date, or file type see [Filter Results](filter-results.md).

All examples assume the daemon is running. If it is not, the CLI starts it automatically on the first query.

### Search by keyword

The simplest search is a plain keyword. DeepFinder matches **case-insensitively** and **anywhere in the filename** -- a substring is enough.

```bash
deepfinder "report"
```

This finds `report.pdf`, `sales_report.xlsx`, `REPORT_FINAL.docx`, and anything else containing "report". Multiple words are ANDed together: every word must appear in the filename.

```bash
deepfinder "vacation photo"
```

Finds files whose names contain both "vacation" **and** "photo", such as `vacation_photo_beach.jpg` or `Photo_of_vacation_2026.png`.

> 💡 **Pinyin search**: DeepFinder understands Chinese pinyin. Searching `baogao` finds `报告.pdf`, `报告_2026.docx`, and any file whose Chinese name sounds like "baogao". This works for all indexed files with Chinese filenames -- no special syntax needed.

### Match with wildcards

Use `*` to match any sequence of characters, and `?` to match exactly one character.

```bash
deepfinder "*.pdf"               # Every PDF file
deepfinder "report_??.txt"       # report_01.txt, report_ab.txt, etc.
deepfinder "*vacation*"          # Any file with "vacation" in the name
deepfinder "IMG_*.jpg"           # All JPEGs starting with IMG_
```

Wildcards work anywhere in the query, not only at the beginning or end. `*` is the most common wildcard -- use it when you know part of the name but not the rest.

### Filter by extension

The `ext:` modifier restricts results to specific file types. It is faster and more precise than a leading wildcard like `*.pdf`.

```bash
deepfinder "ext:pdf report"              # PDF files containing "report"
deepfinder "ext:jpg;png;heic vacation"   # Vacation photos across common image formats
deepfinder "ext:mp4;mkv;mov"             # All video files
```

Separate multiple extensions with `;`. The `ext:` filter combines naturally with any other query terms -- the keyword match still applies to the filename, while `ext:` only checks the extension.

### Quick combinations

These patterns cover most day-to-day needs:

```bash
deepfinder "ext:pdf budget 2026"          # This year's budget PDFs
deepfinder "*.swift !test"                # Swift files excluding test files
deepfinder "ext:log dm:today"             # Today's log files
deepfinder "ext:jpg;png size:>5mb"        # Large images
```

Every technique on this page composes freely. Start with a keyword, add an extension filter, then refine with wildcards as needed.

### Search from the REPL

If you prefer interactive exploration, start the REPL by running `deepfinder` with no arguments:

```
deepfinder
> vacation photo
1. /Users/nadav/Pictures/2026/vacation_beach.jpg    2.4 MB   exa  2026-03-15
2. /Users/nadav/Pictures/2026/vacation_hotel.jpg    1.8 MB   exa  2026-03-16
3. /Users/nadav/Documents/vacation_plan.md           12 KB    sub  2026-02-28
3 results

> ext:pdf report
1. /Users/nadav/Documents/report_q1.pdf    156 KB   exa  2026-05-15
1 result
```

Press `:q` or Ctrl+D to exit. Results are numbered -- use `:open 1` to open a file or `:reveal 1` to show it in Finder.

### Scripting output

For use in shell scripts, `--json` gives structured output and `--0` is safe for paths containing spaces:

```bash
deepfinder --json "ext:pdf report" | jq '.[].path'
deepfinder --0 "*.mp4" | xargs -0 -I {} mv {} ~/Videos/
```

### CLI flag reference

| Flag | Description |
|------|-------------|
| `--help` | Show the full CLI reference with all flags and subcommands |
| `--version` | Show the DeepFinder version and exit |

### Getting help

Every search feature has built-in help. Use `deepfinder --help` for the full CLI reference, or `:help` inside the REPL to see all available commands.

## Next: [Exact Search ->](exact-search.md) | [Filter Results ->](filter-results.md)
