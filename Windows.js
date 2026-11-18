.pragma library

// Pure helpers for Window Overview: labels, search, ordering and layout.
// Nothing here touches Qt, so it can be run and tested on its own.

var MAX_LABEL = 128

// Titles and app ids are chosen by the application (a web page sets its tab's
// title), so they are cut to a sane length before they reach the screen.
function label(text) {
  var value = String(text || "")
  return value.length > MAX_LABEL ? value.slice(0, MAX_LABEL) : value
}

// Hyprland's address for a window, without the 0x. It is pasted into a Lua
// dispatch, so anything that is not plain hex is refused, not escaped.
function validAddress(address) {
  return /^[0-9a-f]{1,16}$/.test(String(address || ""))
}

// An app id only ever counts as the name of a theme icon, never as a path.
function iconName(appId) {
  var id = String(appId || "")
  return /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(id) && id.indexOf("..") < 0 ? id : ""
}

// The site a Chromium web app window belongs to:
// "chrome-app.hey.com__-Default" -> "app.hey.com". Empty for anything else.
function webAppHost(appId) {
  var match = String(appId || "").match(/^(?:chrome|chromium|brave|msedge)-([^_]+)__/)
  return match ? match[1] : ""
}

// A readable name for a window no desktop entry claims:
// "org.gnome.Nautilus" -> "Nautilus", "foot" -> "Foot".
function appName(appId) {
  var id = String(appId || "")
  if (!id) return "Unknown"
  var host = webAppHost(id)
  if (host) return host
  var last = id.split(".").pop().replace(/[-_]+/g, " ")
  return last.charAt(0).toUpperCase() + last.slice(1)
}

// Width over height, kept within what still makes a usable thumbnail.
function aspect(width, height) {
  var w = Number(width), h = Number(height)
  if (!(w > 0) || !(h > 0)) return 1.6
  return Math.max(0.5, Math.min(3, w / h))
}

// Subsequence match, as fzf does it. -1 when the needle is not in the
// haystack; otherwise higher is better: runs of consecutive letters and hits
// at the start of a word count for more.
function fuzzyScore(haystack, needle) {
  var score = 0, from = 0, run = 0
  for (var i = 0; i < needle.length; i++) {
    var found = haystack.indexOf(needle.charAt(i), from)
    if (found < 0) return -1
    run = found === from && i > 0 ? run + 1 : 0
    var wordStart = found === 0 || /[\s\-_.:\/|·—]/.test(haystack.charAt(found - 1))
    score += 1 + run * 3 + (wordStart ? 4 : 0) - Math.min(found - from, 10) * 0.1
    from = found + 1
  }
  if (haystack.indexOf(needle) >= 0) score += needle.length * 2
  return score
}

// Windows matching every space-separated term of the query, best match first.
// Each window carries a lowercase `haystack`.
function search(windows, query) {
  var terms = String(query || "").toLowerCase().split(/\s+/).filter(function(term) { return term })
  if (terms.length === 0) return windows.slice()
  var matches = []
  for (var i = 0; i < windows.length; i++) {
    var total = 0
    for (var t = 0; t < terms.length && total >= 0; t++) {
      var score = fuzzyScore(windows[i].haystack, terms[t])
      total = score < 0 ? -1 : total + score
    }
    if (total >= 0) matches.push({ window: windows[i], score: total, order: i })
  }
  matches.sort(function(a, b) { return b.score - a.score || a.order - b.order })
  return matches.map(function(match) { return match.window })
}

// Where things are: by workspace, then left to right, then top to bottom.
function byWorkspace(a, b) {
  return a.workspaceId - b.workspaceId || a.x - b.x || a.y - b.y || (a.address < b.address ? -1 : 1)
}

// Most recently focused first. `recent` lists addresses in that order; a
// window not in it yet falls back to the focus history Hyprland last reported.
function byRecency(recent) {
  function rank(window) {
    var index = recent.indexOf(window.address)
    return index >= 0 ? index : recent.length + window.focusHistory
  }
  return function(a, b) { return rank(a) - rank(b) || byWorkspace(a, b) }
}

// Split the windows, in order, into `count` rows of about the same width: a
// window goes in the row its middle falls into.
function rowsFor(aspects, count) {
  var total = 0
  for (var i = 0; i < aspects.length; i++) total += aspects[i]
  var rows = [], row = [], placed = 0
  for (var j = 0; j < aspects.length; j++) {
    var rowEnd = total * (rows.length + 1) / count
    if (row.length > 0 && rows.length < count - 1 && placed + aspects[j] / 2 > rowEnd) {
      rows.push(row)
      row = []
    }
    row.push(j)
    placed += aspects[j]
  }
  rows.push(row)
  return rows
}

// Lay thumbnails out in centred rows of one shared height, each keeping its
// window's shape, as large as fits the area. Returns one
// { x, y, width, height, row } per aspect, in the same order; height includes
// the label under the thumbnail.
function layout(aspects, width, height, gap, labelHeight, maxRowHeight) {
  var count = aspects.length
  if (count === 0 || !(width > 0) || !(height > 0)) return []

  function aspectSum(row) {
    var sum = 0
    for (var i = 0; i < row.length; i++) sum += aspects[row[i]]
    return sum
  }

  function rowWidth(row, rowHeight) {
    return aspectSum(row) * rowHeight + gap * (row.length - 1)
  }

  // Try every number of rows and keep the one that leaves the tallest rows.
  var best = null
  for (var n = 1; n <= count; n++) {
    var rows = rowsFor(aspects, n)
    var rowHeight = (height - gap * (rows.length - 1)) / rows.length - labelHeight
    for (var r = 0; r < rows.length; r++)
      rowHeight = Math.min(rowHeight, (width - gap * (rows[r].length - 1)) / aspectSum(rows[r]))
    if (!best || rowHeight > best.rowHeight) best = { rows: rows, rowHeight: rowHeight }
  }

  var size = Math.max(1, Math.min(best.rowHeight, maxRowHeight))
  var tiles = new Array(count)
  var y = (height - best.rows.length * (size + labelHeight) - gap * (best.rows.length - 1)) / 2
  for (var b = 0; b < best.rows.length; b++) {
    var x = (width - rowWidth(best.rows[b], size)) / 2
    for (var k = 0; k < best.rows[b].length; k++) {
      var index = best.rows[b][k]
      tiles[index] = { x: x, y: y, width: aspects[index] * size, height: size + labelHeight, row: b }
      x += aspects[index] * size + gap
    }
    y += size + labelHeight + gap
  }
  return tiles
}

// The tile straight above (direction -1) or below (1) the one at `index`:
// the nearest by centre in the next row. `index` itself when there is no row.
function neighbour(tiles, index, direction) {
  var from = tiles[index]
  if (!from) return index
  var centre = from.x + from.width / 2
  var nearest = index, distance = Infinity
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i].row !== from.row + direction) continue
    var away = Math.abs(tiles[i].x + tiles[i].width / 2 - centre)
    if (away < distance) { distance = away; nearest = i }
  }
  return nearest
}
