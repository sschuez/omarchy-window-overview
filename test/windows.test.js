// Tests for Windows.js, the plugin's search, ordering and layout logic.
// Run with: node test/windows.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert")

// Windows.js is a QML JavaScript library; minus its pragma it is plain JS.
const source = fs.readFileSync(path.join(__dirname, "..", "Windows.js"), "utf8").replace(".pragma library", "")
const W = vm.runInNewContext(source + `
  ;({ label, validAddress, iconName, webAppHost, appName, aspect, search, byWorkspace, byRecency, layout, neighbour })`)
const same = (actual, expected) => assert.deepStrictEqual(JSON.parse(JSON.stringify(actual)), expected)

// Labels and names
assert.equal(W.label("x".repeat(500)).length, 128)
assert.equal(W.webAppHost("chrome-app.hey.com__-Default"), "app.hey.com")
assert.equal(W.webAppHost("chromium"), "")
assert.equal(W.appName("org.gnome.Nautilus"), "Nautilus")
assert.equal(W.appName("foot"), "Foot")
assert.equal(W.appName(""), "Unknown")

// Nothing a client can choose reaches a dispatch or the file system
assert(W.validAddress("55c058e3d1d0"))
assert(!W.validAddress('1" }) os.exit() --'))
assert(!W.validAddress(""))
assert.equal(W.iconName("/etc/passwd"), "")
assert.equal(W.iconName("a..b"), "")
assert.equal(W.iconName("org.foo.Bar"), "org.foo.Bar")

// Search
const windows = [["Chromium", "GitHub - pull requests"], ["Foot", "nvim overrides.lua"], ["HEY", "Imbox"], ["Chess", "New game"]]
  .map(([app, title], i) => ({ address: "a" + i, haystack: (app + " " + title).toLowerCase(), workspaceId: i + 1, x: 0, y: 0, focusHistory: i }))
const found = query => W.search(windows, query).map(window => window.address)
same(found("hey"), ["a2"])
same(found("chr git"), ["a0"])
same(found("zzz"), [])
same(found("  "), ["a0", "a1", "a2", "a3"])
assert.equal(found("ch")[0], "a0")

// Ordering
same(windows.slice().sort(W.byRecency(["a3", "a1"])).map(window => window.address), ["a3", "a1", "a0", "a2"])
same([{ workspaceId: 2, x: 0, y: 0, address: "b" }, { workspaceId: 1, x: 9, y: 0, address: "c" }, { workspaceId: 1, x: 0, y: 0, address: "d" }]
  .sort(W.byWorkspace).map(window => window.address), ["d", "c", "b"])

// Layout: every tile inside the area, in its window's shape, rows evenly spaced
const width = 1800, height = 900, gap = 28, label = 50
for (const count of [1, 2, 3, 4, 5, 7, 9, 12, 20, 40]) {
  const aspects = Array.from({ length: count }, (_, i) => [1.78, 1.6, 0.9, 1.33][i % 4])
  const tiles = W.layout(aspects, width, height, gap, label, 500)
  assert.equal(tiles.length, count)
  tiles.forEach((tile, i) => {
    assert(tile.x >= -0.01 && tile.x + tile.width <= width + 0.01, `${count} windows: tile ${i} leaves the area sideways`)
    assert(tile.y >= -0.01 && tile.y + tile.height <= height + 0.01, `${count} windows: tile ${i} leaves the area vertically`)
    assert(Math.abs(tile.width / (tile.height - label) - aspects[i]) < 1e-6, `${count} windows: tile ${i} lost its shape`)
    if (i > 0 && tile.row === tiles[i - 1].row)
      assert(Math.abs(tile.x - (tiles[i - 1].x + tiles[i - 1].width + gap)) < 1e-6, `${count} windows: uneven gap before tile ${i}`)
  })
}
same(W.layout([], width, height, gap, label, 500), [])
same(W.layout([1.6], 0, 0, gap, label, 500), [])

// Up and down move between rows, and stay put where there is no row
const seven = W.layout([1.6, 1.6, 1.6, 1.6, 1.6, 1.6, 1.6], width, height, gap, label, 500)
assert.equal(seven[W.neighbour(seven, 0, 1)].row, 1)
assert.equal(W.neighbour(seven, 0, -1), 0)
assert.equal(W.neighbour(seven, 99, 1), 99)

console.log("ok")
