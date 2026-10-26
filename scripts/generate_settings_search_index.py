#!/usr/bin/env python3
"""Generate the settings window search index from the SwiftUI settings views.

Every settings row is discovered in the Swift sources, so the search never needs
a hand-maintained item list:

* Row components (a struct named ...Row / ...Cell with a `title` property, for
  example SettingsRow, ToggleCell, SettingsChoiceRow) become one entry per
  literal `title:`.
* Section components (a struct named ...Section / ...Group with a `title`
  property, for example FormSection) give the section of the rows inside them.
* Panes come from `SettingsDetail` in SettingsView.swift. Every view struct a
  pane root instantiates is followed transitively. `InputView(scope:)` style
  conditions (`if scope == .all || scope == .controller`) are evaluated.
* Option names (literals inside localize(...) / Text(...) / array literals /
  `SettingsModel.<static array>` referenced by a row) become keywords.

Markers in the Swift sources (line comments):

  // settings-search: entry "Title" detail="Key" keywords="a|b"
      A control that is not built from a row component. Placed inside the view
      that draws it; the pane and section come from where that view is used.
  // settings-search: ignore
      Placed inside a struct whose rows are intentionally not part of any pane,
      also when a pane shows it somewhere search cannot open (a page one level
      down). Views it instantiates are not followed from it.
  // settings-search: pane=keyboard
      Placed inside a struct to attribute it to a pane in addition to the
      panes that reach it by instantiation.

A row that cannot be attributed to a pane makes the script fail, naming
file:line, so nothing is dropped silently.

Scrolling to a search result (SettingsSearchScrollID in
SettingsSharedControls.swift) identifies a row by its section and title and a
section by its title, the same keys written into the entries. The script keeps
the two sides in sync:

* Every `entry` marker needs a matching `.settingsSearchEntry("Title")`
  modifier on the view it describes (inside the same struct).
* When two rows of one pane share a section and a title, the first one in
  layout order is the entry (and the scroll target). Each later one must be
  followed by `.settingsSearchTargetSuppressed()`, otherwise two views would
  carry the same id.

Usage:
  generate_settings_search_index.py            write the generated Swift file
  generate_settings_search_index.py --check    exit 1 when the file is stale
"""

import argparse
import bisect
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)
SOURCE_DIR = os.path.join(ROOT, "Limelight")
OUTPUT_REL = "Limelight/macOS/ViewControllers/SettingsSearchIndex.generated.swift"
OUTPUT_PATH = os.path.join(ROOT, OUTPUT_REL)
SETTINGS_VIEW_NAME = "SettingsDetail"
PANE_ENUM_NAME = "SettingsPaneType"

DETAIL_LABELS = ("detail", "hintKey", "detailKey")
HARVEST_ARG_LABELS = ("options",)
TEXT_FUNCTIONS = (
    "localize", "Text", "NSLocalizedString", "Button", "Link", "Label",
    "LocalizedStringKey", "help",
)
NOT_TYPE_NAMES = frozenset([
    "func", "var", "let", "init", "subscript", "class", "static", "final",
    "private", "public", "internal", "fileprivate", "open", "case", "where",
    "protocol", "extension", "enum", "struct", "actor", "typealias", "import",
])

MARKER_RE = re.compile(r"//\s*settings-search:\s*([^\n]*)")


class GenError(Exception):
    pass


# ---------------------------------------------------------------------------
# Lexing: a masked copy of each file with comments blanked and string contents
# replaced by "x", so brackets and keywords can be matched structurally while
# literals are still read from the original text at the same offsets.
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(r'//|/\*|#*"')
_STRING_START_RE = re.compile(r'#*"')


def _scan_string(src, quote, hashes, multiline):
    """Return (end, content_start, content_end) for a string starting at quote."""
    n = len(src)
    content_start = quote + (3 if multiline else 1)
    close = ('"""' if multiline else '"') + "#" * hashes
    esc = "\\" + "#" * hashes
    i = content_start
    while i < n:
        if src.startswith(esc, i):
            j = i + len(esc)
            if j < n and src[j] == "(":
                i = _skip_interpolation(src, j)
                continue
            i = j + 1
            continue
        if src.startswith(close, i):
            return i + len(close), content_start, i
        if not multiline and src[i] == "\n":
            raise GenError("unterminated string literal")
        i += 1
    raise GenError("unterminated string literal")


def _skip_interpolation(src, open_paren):
    n = len(src)
    depth = 0
    i = open_paren
    while i < n:
        c = src[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        elif c == '"' or c == "#":
            m = _STRING_START_RE.match(src, i)
            if m:
                hashes = len(m.group(0)) - 1
                quote = i + hashes
                multiline = src.startswith('"""', quote)
                end, _, _ = _scan_string(src, quote, hashes, multiline)
                i = end
                continue
        i += 1
    raise GenError("unterminated string interpolation")


def mask_source(src):
    out = list(src)
    n = len(src)
    i = 0
    while True:
        m = _TOKEN_RE.search(src, i)
        if not m:
            break
        token = m.group(0)
        start = m.start()
        if token == "//":
            end = src.find("\n", start)
            end = n if end < 0 else end
            for k in range(start, end):
                out[k] = " "
            i = end
        elif token == "/*":
            depth = 1
            j = start + 2
            while j < n and depth > 0:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(start, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        else:
            hashes = len(token) - 1
            quote = start + hashes
            multiline = src.startswith('"""', quote)
            end, content_start, content_end = _scan_string(src, quote, hashes, multiline)
            for k in range(content_start, content_end):
                if out[k] != "\n":
                    out[k] = "x"
            i = end
    return "".join(out)


_BRACKET_RE = re.compile(r"[(){}\[\]]")
_CLOSE_TO_OPEN = {")": "(", "}": "{", "]": "["}


class SourceFile(object):
    def __init__(self, rel, src):
        self.rel = rel
        self.src = src
        try:
            self.masked = mask_source(src)
        except GenError as error:
            raise GenError("%s: %s" % (rel, error))
        self.match = self._build_match()
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", src)]

    def _build_match(self):
        stack = []
        match = {}
        for m in _BRACKET_RE.finditer(self.masked):
            c = m.group(0)
            pos = m.start()
            if c in "({[":
                stack.append((c, pos))
            else:
                if not stack or stack[-1][0] != _CLOSE_TO_OPEN[c]:
                    raise GenError("%s:%d: unbalanced '%s'" % (self.rel, self.line(pos), c))
                _, open_pos = stack.pop()
                match[open_pos] = pos
        if stack:
            raise GenError("%s:%d: unbalanced '%s'" % (self.rel, self.line(stack[-1][1]), stack[-1][0]))
        return match

    def line(self, pos):
        return bisect.bisect_right(self.line_starts, pos)

    def where(self, pos):
        return "%s:%d" % (self.rel, self.line(pos))


# ---------------------------------------------------------------------------
# Expression helpers
# ---------------------------------------------------------------------------

_SIMPLE_STRING_RE = re.compile(r'"x*"')
_IDENT_RE = re.compile(r"[A-Za-z_]\w*")
_LABEL_RE = re.compile(r"\s*([A-Za-z_]\w*)\s*:(?!:)")
_LABELED_CLOSURE_RE = re.compile(r"[A-Za-z_]\w*\s*:\s*\{")


def skip_ws(text, i):
    n = len(text)
    while i < n and text[i].isspace():
        i += 1
    return i


def strip_range(f, a, b):
    while a < b and f.masked[a].isspace():
        a += 1
    while b > a and f.masked[b - 1].isspace():
        b -= 1
    return a, b


def split_ranges(f, a, b):
    """Split [a, b) at top-level commas."""
    ranges = []
    start = a
    i = a
    while i < b:
        c = f.masked[i]
        if c in "({[":
            i = f.match[i] + 1
            continue
        if c == ",":
            ranges.append((start, i))
            start = i + 1
        i += 1
    if f.masked[start:b].strip():
        ranges.append((start, b))
    return ranges


def unescape(raw):
    out = []
    i = 0
    n = len(raw)
    simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
    while i < n:
        c = raw[i]
        if c == "\\" and i + 1 < n:
            nxt = raw[i + 1]
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            if nxt == "u" and i + 2 < n and raw[i + 2] == "{":
                end = raw.find("}", i + 3)
                if end > 0:
                    try:
                        out.append(chr(int(raw[i + 3:end], 16)))
                        i = end + 1
                        continue
                    except ValueError:
                        pass
        out.append(c)
        i += 1
    return "".join(out)


def expr_literals(f, a, b, env):
    """String literals an expression can evaluate to.

    Handles a plain literal, a parameter bound to a literal, parentheses and
    ternaries (the literal branches). Anything else yields no literals.
    """
    a, b = strip_range(f, a, b)
    if a >= b:
        return []
    text = f.masked[a:b]
    if text[0] == "(" and f.match.get(a) == b - 1:
        return expr_literals(f, a + 1, b - 1, env)
    if _SIMPLE_STRING_RE.fullmatch(text):
        raw = f.src[a + 1:b - 1]
        if "\\(" in raw:
            return []
        return [unescape(raw)]
    if _IDENT_RE.fullmatch(text):
        return list(env.get(text, []))
    # Ternary: cond ? a : b (nested ternaries in the false branch are fine).
    i = a
    question = -1
    while i < b:
        c = f.masked[i]
        if c in "({[":
            i = f.match[i] + 1
            continue
        if c == "?" and f.masked[i - 1].isspace() and i + 1 < b and f.masked[i + 1].isspace():
            question = i
            break
        i += 1
    if question < 0:
        return []
    depth = 0
    i = question + 1
    while i < b:
        c = f.masked[i]
        if c in "({[":
            i = f.match[i] + 1
            continue
        if c == "?" and f.masked[i - 1].isspace() and i + 1 < b and f.masked[i + 1].isspace():
            depth += 1
        elif c == ":" and f.masked[i - 1].isspace() and i + 1 < b and f.masked[i + 1].isspace():
            if depth == 0:
                return expr_literals(f, question + 1, i, env) + expr_literals(f, i + 1, b, env)
            depth -= 1
        i += 1
    return []


# ---------------------------------------------------------------------------
# Declarations and calls
# ---------------------------------------------------------------------------

_DECL_RE = re.compile(r"\b(struct|class|enum|actor|extension|protocol)\s+([A-Za-z_]\w*)")


class Decl(object):
    def __init__(self, f, kind, name, start, open_pos, close_pos, header):
        self.f = f
        self.kind = kind
        self.name = name
        self.start = start
        self.open = open_pos
        self.close = close_pos
        self.header = header
        self.nested = []
        self.items = None
        self.uid = "%s#%d" % (f.rel, start)
        self.is_component = False
        self.component_kind = None  # "row" or "section"

    def owns(self, pos):
        if not (self.open < pos < self.close):
            return False
        for a, b in self.nested:
            if a <= pos <= b:
                return False
        return True


def find_decls(f):
    decls = []
    for m in _DECL_RE.finditer(f.masked):
        kind, name = m.group(1), m.group(2)
        if name in NOT_TYPE_NAMES:
            continue
        brace = f.masked.find("{", m.end())
        if brace < 0:
            continue
        between = f.masked[m.end():brace]
        if "(" in between and kind != "extension":
            continue
        if ";" in between or "=" in between and kind in ("struct", "class", "enum"):
            continue
        close = f.match.get(brace)
        if close is None:
            continue
        decls.append(Decl(f, kind, name, m.start(), brace, close, between))
    for d in decls:
        for other in decls:
            if other is not d and d.open < other.start and other.close < d.close:
                d.nested.append((other.open, other.close))
    return decls


class Call(object):
    def __init__(self, f, name, start, open_paren):
        self.f = f
        self.name = name
        self.start = start
        self.open = open_paren
        self.close = f.match[open_paren]
        self.args = []        # list of (label or None, expr_a, expr_b)
        self.closures = []    # list of (open, close) braces
        self.end = self.close + 1
        for a, b in split_ranges(f, open_paren + 1, self.close):
            sa, sb = strip_range(f, a, b)
            m = _LABEL_RE.match(f.masked, sa, sb)
            if m:
                ea, eb = strip_range(f, m.end(), sb)
                self.args.append((m.group(1), ea, eb))
            else:
                self.args.append((None, sa, sb))
        k = self.end
        while True:
            j = skip_ws(f.masked, k)
            if j < len(f.masked) and f.masked[j] == "{" and j in f.match:
                c = f.match[j]
                self.closures.append((j, c))
                self.end = c + 1
                k = c + 1
                continue
            if self.closures:
                m = _LABELED_CLOSURE_RE.match(f.masked, j)
                if m:
                    brace = m.end() - 1
                    c = f.match[brace]
                    self.closures.append((brace, c))
                    self.end = c + 1
                    k = c + 1
                    continue
            break

    def arg(self, label):
        for name, a, b in self.args:
            if name == label:
                return a, b
        return None

    def line_pos(self):
        return self.start


def parse_scope_if(f, pos):
    """Parse an `if` at pos. Returns (cond_a, cond_b, then_range, else_range, end) or None."""
    masked = f.masked
    i = pos + 2
    n = len(masked)
    while i < n:
        c = masked[i]
        if c in "([":
            i = f.match[i] + 1
            continue
        if c == "{":
            break
        if c == "}" or c == ";":
            return None
        i += 1
    else:
        return None
    then_open = i
    then_close = f.match.get(then_open)
    if then_close is None:
        return None
    cond = (pos + 2, then_open)
    end = then_close + 1
    else_range = None
    j = skip_ws(masked, end)
    if masked.startswith("else", j) and not (j + 4 < n and (masked[j + 4].isalnum() or masked[j + 4] == "_")):
        k = skip_ws(masked, j + 4)
        if k < n and masked[k] == "{":
            c = f.match[k]
            else_range = (j, c)
            end = c + 1
        elif masked.startswith("if", k):
            nested = parse_scope_if(f, k)
            if nested is not None:
                else_range = (j, nested[4])
                end = nested[4]
    return cond[0], cond[1], (then_open, then_close), else_range, end


_IF_RE = re.compile(r"\bif\b")


def collect_scope_ifs(d):
    """`if` statements in the declaration whose condition mentions `scope`."""
    f = d.f
    found = []
    for m in _IF_RE.finditer(f.masked, d.open, d.close):
        if not d.owns(m.start()):
            continue
        parsed = parse_scope_if(f, m.start())
        if parsed is None:
            continue
        cond_a, cond_b, then_range, else_range, _ = parsed
        if re.search(r"\bscope\b", f.masked[cond_a:cond_b]):
            found.append((f.src[cond_a:cond_b], cond_a, then_range, else_range))
    return found


_SCOPE_TERM_RE = re.compile(r"\bscope\s*(==|!=)\s*\.(\w+)")


def eval_scope_condition(cond, scope_value, where):
    def repl(m):
        equal = (m.group(2) == scope_value)
        return " True " if (equal if m.group(1) == "==" else not equal) else " False "

    text = _SCOPE_TERM_RE.sub(repl, cond)
    text = text.replace("&&", " and ").replace("||", " or ")
    text = re.sub(r"!(?!=)", " not ", text)
    words = re.findall(r"[A-Za-z_]\w*", text)
    if any(w not in ("True", "False", "and", "or", "not") for w in words) or re.search(r"[^\sA-Za-z()]", text):
        raise GenError("%s: cannot evaluate the scope condition '%s'" % (where, cond.strip()))
    return bool(eval(text, {"__builtins__": {}}, {}))


# ---------------------------------------------------------------------------
# Static data referenced by rows
# ---------------------------------------------------------------------------

_STATIC_RE = re.compile(r"\bstatic\s+(?:var|let)\s+([A-Za-z_]\w*)\s*(?::[^=\n{]*)?([={])")
_MAP_TITLE_RE = re.compile(r"^([A-Za-z_]\w*)\s*\.\s*map\s*\(\s*\\\s*\.\s*(title)\s*\)$")


def _has_top_level_colon(f, a, b):
    i = a
    while i < b:
        c = f.masked[i]
        if c in "({[":
            i = f.match[i] + 1
            continue
        if c == ":":
            return True
        i += 1
    return False


def _array_elements(f, open_bracket):
    """Literal elements of an array literal; tuples contribute their first
    literal component. Returns None if it is not a simple array."""
    close = f.match.get(open_bracket)
    if close is None:
        return None
    values = []
    for a, b in split_ranges(f, open_bracket + 1, close):
        a, b = strip_range(f, a, b)
        if f.masked[a] == "(":
            inner = split_ranges(f, a + 1, f.match[a])
            if not inner:
                continue
            ia, ib = strip_range(f, inner[0][0], inner[0][1])
            m = _LABEL_RE.match(f.masked, ia, ib)
            if m:
                ia, ib = strip_range(f, m.end(), ib)
            values.extend(expr_literals(f, ia, ib, {}))
        else:
            if _has_top_level_colon(f, a, b):
                return None
            values.extend(expr_literals(f, a, b, {}))
    return values


def build_static_index(files):
    raw = {}
    for f in files:
        for m in _STATIC_RE.finditer(f.masked):
            name = m.group(1)
            pos = m.end(2) - 1
            entry = None
            if m.group(2) == "=":
                k = skip_ws(f.masked, m.end(2))
                if k < len(f.masked) and f.masked[k] == "[":
                    entry = ("array", f, k)
                else:
                    end = f.masked.find("\n", k)
                    end = len(f.masked) if end < 0 else end
                    expr = f.masked[k:end].strip()
                    mm = _MAP_TITLE_RE.match(expr)
                    if mm:
                        entry = ("map", mm.group(1))
            else:
                close = f.match.get(pos)
                if close is not None:
                    body = f.masked[pos + 1:close].strip()
                    mm = _MAP_TITLE_RE.match(body)
                    if mm:
                        entry = ("map", mm.group(1))
            if entry is not None:
                raw.setdefault(name, []).append(entry)

    resolved = {}

    def resolve(name, seen):
        if name in resolved:
            return resolved[name]
        if name in seen or name not in raw:
            return None
        results = []
        for entry in raw[name]:
            if entry[0] == "array":
                values = _array_elements(entry[1], entry[2])
            else:
                values = resolve(entry[1], seen | set([name]))
            if values is None:
                results = None
                break
            results.append(tuple(values))
        if results is None or len(set(results)) != 1:
            value = None
        else:
            value = list(results[0])
        resolved[name] = value
        return value

    for name in list(raw):
        resolve(name, frozenset())
    return resolved


def build_capability_index(files):
    items = []
    pattern = re.compile(r"\bVideoCapabilityItem\s*\(")
    for f in files:
        for m in pattern.finditer(f.masked):
            call = Call(f, "VideoCapabilityItem", m.start(), m.end() - 1)
            ident = call.arg("id")
            title = call.arg("titleKey")
            if not ident or not title:
                continue
            ids = expr_literals(f, ident[0], ident[1], {})
            titles = expr_literals(f, title[0], title[1], {})
            if not ids or not titles:
                continue
            detail = call.arg("detailKey")
            details = expr_literals(f, detail[0], detail[1], {}) if detail else []
            items.append((ids[0], titles[0], details[0] if details else None))
    return items


# ---------------------------------------------------------------------------
# The index builder
# ---------------------------------------------------------------------------

_SUPPRESS_RE = re.compile(r"\s*\.settingsSearchTargetSuppressed\(\)")


class Entry(object):
    def __init__(self, kind, section, title, detail, keywords):
        self.kind = kind
        self.section = section
        self.title = title
        self.detail = detail
        self.keywords = list(keywords)


class Generator(object):
    def __init__(self, verbose):
        self.verbose = verbose
        self.files = []
        self.decls = []
        self.by_name = {}
        self.static_index = {}
        self.capabilities = []
        self.pane_cases = []
        self.pane_title = {}
        self.pane_subtitle = {}
        self.pane_category = {}
        self.entries = {}       # pane -> [Entry]
        self.seen = set()
        self.visited = set()
        self.emitted = set()    # (decl uid, position) of rows/markers attributed
        self.row_sites = {}     # (pane, section, title) -> where the first row was seen
        self.notes = []

    # -- loading ----------------------------------------------------------

    def load(self):
        paths = []
        for base, dirs, names in os.walk(SOURCE_DIR):
            dirs.sort()
            for name in sorted(names):
                if name.endswith(".swift") and name != os.path.basename(OUTPUT_PATH):
                    paths.append(os.path.join(base, name))
        for path in paths:
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            with open(path, "r", encoding="utf-8") as handle:
                self.files.append(SourceFile(rel, handle.read()))
        for f in self.files:
            self.decls.extend(find_decls(f))
        for d in self.decls:
            if d.kind == "struct":
                self.by_name.setdefault(d.name, []).append(d)
        self.static_index = build_static_index(self.files)
        self.capabilities = build_capability_index(self.files)
        self._classify_components()

    def _classify_components(self):
        title_prop = re.compile(r"\b(?:let|var)\s+title\s*:\s*String\??")
        for d in self.decls:
            if d.kind != "struct" or not re.search(r"\bView\b", d.header):
                continue
            has_title = False
            for m in title_prop.finditer(d.f.masked, d.open, d.close):
                if d.owns(m.start()):
                    has_title = True
                    break
            if not has_title:
                continue
            if re.search(r"(Row|Cell)$", d.name):
                d.is_component = True
                d.component_kind = "row"
            elif re.search(r"(Section|Group)$", d.name):
                d.is_component = True
                d.component_kind = "section"
        names = sorted(set(d.name for d in self.decls if d.is_component), key=lambda s: (-len(s), s))
        if self.verbose:
            sys.stderr.write("row/section components: %s\n" % ", ".join(
                "%s(%s)" % (n, self.by_name[n][0].component_kind) for n in sorted(names)))
        self.component_re = re.compile(r"(?<![\w.])(%s)\s*\(" % "|".join(names)) if names else None
        ref_names = sorted(set(d.name for d in self.decls
                               if d.kind == "struct" and not d.is_component), key=lambda s: (-len(s), s))
        self.ref_re = re.compile(r"(?<![\w.])(%s)\s*\(" % "|".join(ref_names)) if ref_names else None

    # -- pane metadata ----------------------------------------------------

    def _find_decl(self, kind, name):
        for d in self.decls:
            if d.kind == kind and d.name == name:
                return d
        raise GenError("%s declaration '%s' not found" % (kind, name))

    def _property_block(self, d, prop):
        m = re.search(r"\bvar\s+%s\s*:[^{=]*\{" % prop, d.f.masked[d.open:d.close])
        if not m:
            raise GenError("%s: property '%s' not found in %s" % (d.f.rel, prop, d.name))
        brace = d.open + m.end() - 1
        return brace, d.f.match[brace]

    def load_panes(self):
        d = self._find_decl("enum", PANE_ENUM_NAME)
        f = d.f
        m = re.search(r"static\s+var\s+allCases[^{]*\{", f.masked[d.open:d.close])
        if not m:
            raise GenError("%s: allCases not found in %s" % (f.rel, PANE_ENUM_NAME))
        brace = d.open + m.end() - 1
        body = f.masked[brace:f.match[brace]]
        self.pane_cases = re.findall(r"\.(\w+)", body)
        if not self.pane_cases:
            raise GenError("%s: allCases of %s is empty" % (f.rel, PANE_ENUM_NAME))
        for prop, target in (("titleKey", self.pane_title), ("subtitleKey", self.pane_subtitle)):
            a, b = self._property_block(d, prop)
            for cm in re.finditer(r'case\s+\.(\w+)\s*:\s*return\s+"([^"\\]*)"', f.src[a:b]):
                target[cm.group(1)] = cm.group(2)
        a, b = self._property_block(d, "categoryKey")
        for cm in re.finditer(r'case\s+((?:\.\w+\s*,?\s*)+):\s*return\s+"([^"\\]*)"', f.src[a:b]):
            for case in re.findall(r"\.(\w+)", cm.group(1)):
                self.pane_category[case] = cm.group(2)
        for pane in self.pane_cases:
            if pane not in self.pane_title:
                raise GenError("%s: no titleKey for pane .%s" % (f.rel, pane))

    def load_roots(self):
        d = self._find_decl("struct", SETTINGS_VIEW_NAME)
        f = d.f
        roots = {}
        pattern = re.compile(r"\bcase\s+\.(\w+)\s*:\s*([A-Z]\w*)\s*\(")
        for m in pattern.finditer(f.masked, d.open, d.close):
            pane, view = m.group(1), m.group(2)
            if pane not in self.pane_cases or view not in self.by_name:
                continue
            call = Call(f, view, m.start(2), m.end() - 1)
            roots[pane] = (view, self._bind_env(call, {}))
        for pane in self.pane_cases:
            if pane not in roots:
                raise GenError("%s: no root view for pane .%s in %s" % (f.rel, pane, SETTINGS_VIEW_NAME))
        return roots

    # -- per declaration items --------------------------------------------

    def _items(self, d):
        if d.items is not None:
            return d.items
        f = d.f
        items = []
        if self.component_re is not None:
            for m in self.component_re.finditer(f.masked, d.open, d.close):
                if not d.owns(m.start()):
                    continue
                target = self.by_name[m.group(1)][0]
                call = Call(f, m.group(1), m.start(1), m.end() - 1)
                items.append((call.start, target.component_kind, call, None))
        if self.ref_re is not None:
            for m in self.ref_re.finditer(f.masked, d.open, d.close):
                if not d.owns(m.start()):
                    continue
                call = Call(f, m.group(1), m.start(1), m.end() - 1)
                items.append((call.start, "ref", call, m.group(1)))
        for m in MARKER_RE.finditer(f.src, d.open, d.close):
            if not d.owns(m.start()):
                continue
            text = m.group(1).strip()
            if text.startswith("entry"):
                items.append((m.start(), "marker", None, self._parse_entry_marker(f, m.start(), text)))
        items.sort(key=lambda item: item[0])
        d.items = items
        return items

    def _parse_entry_marker(self, f, pos, text):
        m = re.match(r'entry\s+"((?:[^"\\]|\\.)*)"(.*)$', text)
        if not m:
            raise GenError('%s: malformed marker, expected: entry "Title" [detail="Key"] [keywords="a|b"]' % f.where(pos))
        title = unescape(m.group(1))
        rest = m.group(2)
        detail = None
        keywords = []
        dm = re.search(r'detail="((?:[^"\\]|\\.)*)"', rest)
        if dm:
            detail = unescape(dm.group(1))
        km = re.search(r'keywords="((?:[^"\\]|\\.)*)"', rest)
        if km:
            keywords = [unescape(k) for k in km.group(1).split("|") if k]
        return (title, detail, keywords)

    def _bind_env(self, call, caller_env):
        env = {}
        for label, a, b in call.args:
            if label is None:
                continue
            values = expr_literals(call.f, a, b, caller_env)
            if not values:
                m = re.fullmatch(r"\.([A-Za-z_]\w*)", call.f.masked[a:b].strip())
                if m:
                    values = [m.group(1)]
            if values:
                env[label] = values
        return env

    # -- traversal ----------------------------------------------------------

    def visit(self, d, pane, inherited_section, env):
        key = (d.uid, pane, inherited_section, tuple(sorted((k, tuple(v)) for k, v in env.items())))
        if key in self.seen:
            return
        self.seen.add(key)
        self.visited.add(d.uid)
        if self._ignored(d):
            # Shown by a pane, but somewhere search cannot open (a page one level down).
            return
        f = d.f
        items = self._items(d)
        scope_ifs = collect_scope_ifs(d)
        sections = [(call, call.closures) for (_, kind, call, _) in items if kind == "section" and call.closures]

        def in_scope(pos):
            for cond, cond_pos, then_range, else_range in scope_ifs:
                inside_then = then_range[0] < pos < then_range[1]
                inside_else = else_range is not None and else_range[0] < pos < else_range[1]
                if not (inside_then or inside_else):
                    continue
                if "scope" not in env:
                    raise GenError("%s: '%s' depends on 'scope' but %s is instantiated without one"
                                   % (f.where(cond_pos), cond.strip(), d.name))
                value = eval_scope_condition(cond, env["scope"][0], f.where(cond_pos))
                if inside_then and not value:
                    return False
                if inside_else and value:
                    return False
            return True

        def enclosing_section(pos, own_call):
            best = None
            for call, closures in sections:
                if call is own_call:
                    continue
                titles = expr_literals(f, *self._arg_or_empty(call, "title"), env=env)
                if not titles:
                    continue
                for a, b in closures:
                    if a < pos < b and (best is None or b - a < best[0]):
                        best = (b - a, titles[0])
            return best[1] if best else inherited_section

        for pos, kind, call, extra in items:
            if not in_scope(pos):
                continue
            if kind == "section":
                self._emit_section(d, pane, call, env, items, enclosing_section(pos, call))
            elif kind == "row":
                self._emit_row(d, pane, call, env, items, enclosing_section(pos, call))
            elif kind == "marker":
                title, detail, keywords = extra
                self.emitted.add((d.uid, pos))
                self._check_marker_modifier(d, pos, title)
                section = enclosing_section(pos, None) or self.pane_title[pane]
                self._note_row_site(pane, section, title, f.where(pos), True)
                self._add(pane, Entry("row", section, title, detail, keywords))
            elif kind == "ref":
                child_env = self._bind_env(call, env)
                for child in self.by_name.get(extra, []):
                    self.visit(child, pane, enclosing_section(pos, None), child_env)

    @staticmethod
    def _arg_or_empty(call, label):
        found = call.arg(label)
        return found if found else (0, 0)

    def _nested_ranges(self, call, items):
        """Ranges of component calls nested inside this call's arguments/closures."""
        ranges = []
        for pos, kind, other, _ in items:
            if other is None or other is call or kind not in ("row", "section"):
                continue
            if call.open < other.start < call.end:
                ranges.append((other.start, other.end))
        return ranges

    def _emit_section(self, d, pane, call, env, items, outer_section):
        f = d.f
        found = call.arg("title")
        titles = expr_literals(f, found[0], found[1], env) if found else []
        if not titles:
            self.notes.append("%s: section title is not a literal; skipped" % f.where(call.start))
            return
        section = titles[0]
        self._add(pane, Entry("section", section, section, None, []))
        # Capability items that the section lists at runtime.
        nested = self._nested_ranges(call, items)
        text = self._own_text(f, call.start, call.end, nested)
        for prefix in re.findall(r'hasPrefix\(\s*"([^"\\]+)"\s*\)', text):
            for ident, title, detail in self.capabilities:
                if ident.startswith(prefix):
                    self._add(pane, Entry("row", section, title, detail, []))

    @staticmethod
    def _own_text(f, a, b, nested):
        chars = list(f.src[a:b])
        for na, nb in nested:
            for k in range(max(na, a), min(nb, b)):
                chars[k - a] = " "
        return "".join(chars)

    def _emit_row(self, d, pane, call, env, items, section):
        f = d.f
        self.emitted.add((d.uid, call.start))
        found = call.arg("title")
        titles = expr_literals(f, found[0], found[1], env) if found else []
        if not titles:
            self.notes.append("%s: %s title is not a literal; skipped" % (f.where(call.start), call.name))
            return
        detail = None
        for label in DETAIL_LABELS:
            arg = call.arg(label)
            if arg:
                values = expr_literals(f, arg[0], arg[1], env)
                if values:
                    detail = values[0]
                    break
        keywords = self._keywords(f, call, items, env)
        suppressed = _SUPPRESS_RE.match(f.masked, call.end) is not None
        for title in titles:
            self._note_row_site(pane, section or self.pane_title[pane], title, f.where(call.start), suppressed)
            self._add(pane, Entry("row", section or self.pane_title[pane], title, detail, keywords))

    def _check_marker_modifier(self, d, pos, title):
        pattern = r'\.settingsSearchEntry\(\s*%s\s*\)' % re.escape(swift_string(title))
        if not re.search(pattern, d.f.src[d.open:d.close]):
            raise GenError('%s: the entry marker "%s" needs a matching .settingsSearchEntry(%s) on the view '
                           "it describes inside %s, so the search result can scroll to it"
                           % (d.f.where(pos), title, swift_string(title), d.name))

    def _note_row_site(self, pane, section, title, where, suppressed):
        """Two rows with one section and title would share a scroll id."""
        key = (pane, section, title)
        if key not in self.row_sites:
            self.row_sites[key] = where
            return
        if not suppressed:
            raise GenError('%s: row "%s" in section "%s" repeats the row at %s; add '
                           ".settingsSearchTargetSuppressed() after it so only the first row is the scroll target"
                           % (where, title, section, self.row_sites[key]))

    def _keywords(self, f, call, items, env):
        nested = self._nested_ranges(call, items)

        def excluded(pos):
            return any(a <= pos < b for a, b in nested)

        regions = list(call.closures)
        for label in HARVEST_ARG_LABELS:
            arg = call.arg(label)
            if arg:
                regions.append(arg)
        found = []
        text_fn = re.compile(r"(?<!\w)(%s)\s*\(" % "|".join(TEXT_FUNCTIONS))
        hint = re.compile(r"(?<!\w)InfoHintButton\s*\(")
        model_ref = re.compile(r"\bSettingsModel\s*\.\s*([A-Za-z_]\w*)")
        for a, b in regions:
            for m in text_fn.finditer(f.masked, a, b):
                if excluded(m.start()):
                    continue
                inner = Call(f, m.group(1), m.start(), m.end() - 1)
                if inner.args and inner.args[0][0] is None:
                    found.extend(expr_literals(f, inner.args[0][1], inner.args[0][2], env))
            for m in hint.finditer(f.masked, a, b):
                if excluded(m.start()):
                    continue
                inner = Call(f, "InfoHintButton", m.start(), m.end() - 1)
                arg = inner.arg("hintKey")
                if arg:
                    found.extend(expr_literals(f, arg[0], arg[1], env))
            for m in model_ref.finditer(f.masked, a, b):
                if excluded(m.start()):
                    continue
                values = self.static_index.get(m.group(1))
                if values:
                    found.extend(values)
            i = a
            while i < b:
                j = f.masked.find("[", i, b)
                if j < 0:
                    break
                close = f.match.get(j)
                if close is None:
                    break
                if not excluded(j):
                    ranges = split_ranges(f, j + 1, close)
                    literals = []
                    ok = bool(ranges)
                    for ra, rb in ranges:
                        values = expr_literals(f, ra, rb, {}) if _SIMPLE_STRING_RE.fullmatch(f.masked[ra:rb].strip()) else []
                        if not values:
                            ok = False
                            break
                        literals.extend(values)
                    if ok:
                        found.extend(literals)
                i = j + 1
        result = []
        for value in found:
            if value and any(ch.isalnum() for ch in value) and value not in result:
                result.append(value)
        return result

    # -- results -------------------------------------------------------------

    def _add(self, pane, entry):
        self.entries.setdefault(pane, []).append(entry)

    def run(self):
        self.load()
        self.load_panes()
        roots = self.load_roots()
        for pane in self.pane_cases:
            view, env = roots[pane]
            for d in self.by_name[view]:
                self.visit(d, pane, None, env)
        for d in self.decls:
            if d.kind != "struct" or d.is_component:
                continue
            for m in MARKER_RE.finditer(d.f.src, d.open, d.close):
                if not d.owns(m.start()):
                    continue
                pm = re.match(r"pane=(\w+)", m.group(1).strip())
                if pm:
                    if pm.group(1) not in self.pane_cases:
                        raise GenError("%s: unknown pane '%s'" % (d.f.where(m.start()), pm.group(1)))
                    self.visit(d, pm.group(1), None, {})
        self._check_attribution()
        return self._finalize()

    def _ignored(self, d):
        return any(re.match(r"ignore\b", m.group(1).strip()) and d.owns(m.start())
                   for m in MARKER_RE.finditer(d.f.src, d.open, d.close))

    def _check_attribution(self):
        problems = []
        for d in self.decls:
            if d.kind != "struct" or d.is_component:
                continue
            if self._ignored(d):
                continue
            for pos, kind, call, extra in self._items(d):
                if kind not in ("row", "marker") or (d.uid, pos) in self.emitted:
                    continue
                label = call.name if call is not None else "entry marker"
                problems.append("%s: %s in %s is not reachable from any settings pane"
                                % (d.f.where(pos), label, d.name))
        if problems:
            raise GenError(
                "\n".join(problems)
                + "\nInstantiate the view from a pane in %s, or add '// settings-search: pane=<pane>' "
                  "or '// settings-search: ignore' inside the struct." % SETTINGS_VIEW_NAME)

    def _finalize(self):
        result = []
        for pane in self.pane_cases:
            category = self.pane_category.get(pane, self.pane_title[pane])
            merged = []
            index = {}
            row_sections = set(e.section for e in self.entries.get(pane, []) if e.kind == "row")
            pane_entry = Entry("pane", category, self.pane_title[pane], self.pane_subtitle.get(pane), [])
            for entry in [pane_entry] + self.entries.get(pane, []):
                if entry.kind == "section" and entry.section in row_sections:
                    continue
                key = (entry.section, entry.title)
                if key in index:
                    existing = index[key]
                    if existing.detail is None:
                        existing.detail = entry.detail
                    for word in entry.keywords:
                        if word not in existing.keywords:
                            existing.keywords.append(word)
                    continue
                clone = Entry(entry.kind, entry.section, entry.title, entry.detail, entry.keywords)
                index[key] = clone
                merged.append(clone)
            for entry in merged:
                entry.keywords = [w for w in entry.keywords
                                  if w not in (entry.title, entry.section) and w != entry.detail]
            result.append((pane, merged))
        return result


# ---------------------------------------------------------------------------
# Swift output
# ---------------------------------------------------------------------------

def swift_string(value):
    out = ['"']
    for ch in value:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code == 0x7F:
            out.append("\\u{%X}" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def group_name(pane):
    return "generated%sEntries" % (pane[0].upper() + pane[1:])


def render(result):
    lines = [
        "// Generated by scripts/generate_settings_search_index.py from the settings views.",
        "// Do not edit by hand: the Xcode build regenerates this file, and",
        "// `scripts/generate_settings_search_index.py --check` verifies it is current.",
        "",
        "extension SettingsSearchIndex {",
    ]
    seen_ids = set()
    for pane, entries in result:
        lines.append("  static let %s: [SettingsSearchEntry] = [" % group_name(pane))
        for entry in entries:
            if entry.kind == "pane":
                entry_id = "%s/pane" % pane
            else:
                entry_id = "%s/%s/%s" % (pane, entry.section, entry.title)
            if entry_id in seen_ids:
                raise GenError("duplicate search entry id %s" % entry_id)
            seen_ids.add(entry_id)
            detail = "nil" if entry.detail is None else swift_string(entry.detail)
            keywords = "[%s]" % ", ".join(swift_string(w) for w in entry.keywords)
            lines.append(
                "    SettingsSearchEntry(id: %s, pane: .%s, kind: .%s, sectionKey: %s, titleKey: %s, detailKey: %s, keywords: %s),"
                % (swift_string(entry_id), pane, entry.kind, swift_string(entry.section),
                   swift_string(entry.title), detail, keywords))
        lines.append("  ]")
        lines.append("")
    lines.append("  static let generatedEntries: [SettingsSearchEntry] = {")
    lines.append("    var all: [SettingsSearchEntry] = []")
    for pane, _ in result:
        lines.append("    all.append(contentsOf: %s)" % group_name(pane))
    lines.append("    return all")
    lines.append("  }()")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="do not write; exit 1 when the generated file is out of date")
    parser.add_argument("--verbose", action="store_true",
                        help="print discovered components and skipped rows")
    parser.add_argument("--list", action="store_true", help="print pane / section / title for every entry")
    args = parser.parse_args()

    generator = Generator(args.verbose)
    try:
        result = generator.run()
        content = render(result)
    except GenError as error:
        sys.stderr.write("error: %s\n" % error)
        return 2

    if args.verbose:
        for note in generator.notes:
            sys.stderr.write("note: %s\n" % note)
    if args.list:
        for pane, entries in result:
            for entry in entries:
                sys.stdout.write("%s\t%s\t%s\t%s\n" % (pane, entry.section, entry.title, entry.kind))

    current = None
    if os.path.exists(OUTPUT_PATH):
        with open(OUTPUT_PATH, "r", encoding="utf-8") as handle:
            current = handle.read()
    total = sum(len(entries) for _, entries in result)
    if args.check:
        if current != content:
            sys.stderr.write("error: %s is out of date; run scripts/generate_settings_search_index.py\n" % OUTPUT_REL)
            return 1
        sys.stdout.write("%s is up to date (%d entries)\n" % (OUTPUT_REL, total))
        return 0
    if current != content:
        with open(OUTPUT_PATH, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        sys.stdout.write("Updated %s (%d entries)\n" % (OUTPUT_REL, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
