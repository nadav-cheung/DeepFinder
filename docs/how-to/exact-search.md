# Exact Search

## You want precise control over what matches

DeepFinder's plain text search is fast and forgiving — it matches substrings case-insensitively. But sometimes you need precision: *this* word but not *that* one, only in a specific folder, or matching a precise pattern. Here is how to lock it down.

---

## Combine Terms with AND

AND is the default — just separate terms with spaces. Every term must match.

```bash
deepfinder "quarterly report"   # Both "quarterly" AND "report" must appear
```

There is no explicit `AND` keyword. A space between terms is always AND.

---

## Match Either Term with OR

Use `|` to match files containing *either* term.

```bash
deepfinder "report | memo"      # Files with "report" OR "memo"
```

OR works inside groups too — see [Grouping with Parentheses](#grouping-with-parentheses) below.

---

## Exclude Terms with NOT

Prefix a term with `!` to exclude files that contain it.

```bash
deepfinder "report !draft"      # "report" but NOT "draft"
deepfinder "budget !2025"       # Budget files, excluding 2025
```

NOT applies to the term immediately after it, or to an entire group if placed before `(`.

---

## Grouping with Parentheses

Use `()` to control operator precedence. Grouped expressions are evaluated as a unit.

```bash
deepfinder "(report | memo) 2026"   # (report OR memo) AND 2026
deepfinder "!(draft | archive)"      # Exclude anything with "draft" or "archive"
```

Without parentheses, operators follow standard precedence: NOT binds tightest, then AND, then OR. When in doubt, add parentheses to make your intent clear.

---

## Match Exact Patterns with Regex

Prefix your query with `regex:` to use full regular expression syntax. The regex is matched against the full filename (not the path).

```bash
deepfinder "regex:^report_\d{4}\.pdf$"   # report_2026.pdf, report_2025.pdf
deepfinder "regex:\.[a-z]{2,4}$"         # Files with 2–4 character extensions
```

DeepFinder uses Apple's NSRegularExpression engine (ICU syntax). Anchors (`^`, `$`), character classes, quantifiers, and capture groups all work as expected.

---

## Restrict to a Directory with Path Qualifiers

Use a backslash-space (`\ `) to restrict the search to a specific directory. The word before `\ ` matches against path components (folder names). The rest is your query.

```bash
deepfinder "Projects\ report"    # "report" only under directories named "Projects"
deepfinder "src\ *.swift"        # Swift files under directories named "src"
```

The path qualifier matches anywhere in the path — it does not need to be the root. A query like `src\ test` matches both `/home/src/test_runner.py` and `/work/legacy/src/old/test.py`.

---

## Match Case Exactly

DeepFinder is case-insensitive by default: `readme` matches `README.md`, `Readme.txt`, and `readme`. To require exact case, use the `case:sensitive` modifier.

```bash
deepfinder "case:sensitive README"     # Only "README", not "readme" or "Readme"
```

The modifier applies to the entire query. To go back to case-insensitive mode explicitly (rarely needed):

```bash
deepfinder "case:insensitive README"   # Explicit default — matches "readme" too
```

---

## Putting It All Together

These techniques compose. A single query can combine boolean operators, path qualifiers, and modifiers:

```bash
# Swift files in "Sources", case-sensitive "Main", modified today
deepfinder "src\ case:sensitive Main ext:swift dm:today"

# PDF or DOCX reports, not drafts, in the "Projects" folder
deepfinder "Projects\ (report | memo) !draft ext:pdf;docx"
```

---

## Where to Go Next

The examples above cover the most common precise-search patterns. For the complete reference — every operator, modifier syntax, escape rules, and edge cases — see the [Search Syntax Reference](../reference/search-syntax.md).

| You want to... | Read this |
|---------------|-----------|
| Filter by size, date, or media metadata | [Filter Results](filter-results.md) |
| Use the interactive REPL | [REPL Interact](repl-interact.md) |
| Script with JSON or the HTTP API | [Scripting](scripting.md) |
| Understand how queries run against the index | [Index Design](../explanation/index-design.md) |
