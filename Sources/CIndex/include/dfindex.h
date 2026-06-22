// dfindex.h — Umbrella header for libdfindex (DeepFinder C index core).
//
// Include this single header to pull in the entire public API:
//   - CIndex            (Everything-style sorted-array prefix + trigram substring)
//   - CTrigramIndex     (standalone byte-level trigram inverted index)
//   - CParallelScanner  (GCD parallel scanner)
//
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn
#ifndef DFINDEX_H
#define DFINDEX_H

#include "CIndex.h"
#include "CTrigramIndex.h"
#include "CParallelScanner.h"

#endif // DFINDEX_H
