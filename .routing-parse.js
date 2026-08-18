// Parses routing.json into the two regex patterns lib.sh uses for the routing gate.
//
// This lives in its own file rather than inline in lib.sh because the regex-escaping
// it needs is dense in backslashes, and inline heredocs of this kind have been mangled
// by transport more than once. A separate .js file has one layer of quoting instead of
// three, so there is nothing to get wrong.
//
// Usage: node .routing-parse.js <routing.json> <small|stealth>
// Prints a bracketed alternation, or nothing if the file has no such rules.

const fs = require("fs");
const [file, which] = process.argv.slice(2);

const RE_SPECIAL = /[.*+?^${}()|[\]\\]/g;
const escapeLiteral = (s) => s.replace(RE_SPECIAL, "\\$&");

// A glob only understands *, so split on it, escape each literal run, and rejoin with .*
const globToRegex = (g) =>
  g.split("*").map((part) => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*");

try {
  const routing = JSON.parse(fs.readFileSync(file, "utf8"));
  const rules = routing.rules || {};
  let list = [];

  if (which === "small") {
    list = (rules.never_global_default || []).map(escapeLiteral);
  } else if (which === "stealth") {
    list = ((rules.never_use && rules.never_use.patterns) || []).map(globToRegex);
  }

  if (list.length) process.stdout.write("(" + list.join("|") + ")");
} catch (e) {
  // No output means lib.sh keeps its built-in fallback patterns.
}
