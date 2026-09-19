use magnus::{
    function, gc, method,
    scan_args::{get_kwargs, scan_args},
    value::{Opaque, ReprValue},
    DataTypeFunctions, Error, Integer, Module, Object, RArray, RClass, RHash, RString, Ruby,
    Symbol, TryConvert, TypedData, Value,
};
use regex::bytes::{NoExpand, Regex, RegexBuilder, RegexSet, RegexSetBuilder};
use std::collections::HashMap;
use std::sync::Arc;

/// A haystack's bytes, read in place for the duration of one native call.
///
/// Sound because the call hands nothing back to Ruby while the borrow lives:
/// the GVL is held and no block is yielded, so no Ruby code can mutate the
/// string, and a GC triggered by the result objects the call builds neither
/// frees nor moves it — a method argument is rooted and pinned on the VM
/// stack for the whole call. Paths that *do* run Ruby code mid-call (the
/// block forms of `sub`/`gsub`) read a frozen snapshot instead; see
/// [`FastMatchData`].
fn bytes(haystack: &RString) -> &[u8] {
    unsafe { haystack.as_slice() }
}

fn utf8_string(ruby: &Ruby, bytes: &[u8]) -> RString {
    ruby.enc_str_new(bytes, ruby.utf8_encoding())
}

fn arg_error(message: impl Into<String>) -> Error {
    Error::new(
        Ruby::get().unwrap().exception_arg_error(),
        message.into(),
    )
}

fn type_error(message: impl Into<String>) -> Error {
    Error::new(
        Ruby::get().unwrap().exception_type_error(),
        message.into(),
    )
}

type CaptureOffset = Option<(usize, usize)>;

/// Inner state shared between a compiled regex and every [`FastMatchData`]
/// it produces, behind an `Arc`.
struct RegexInner {
    regex: Regex,
    /// `name -> capture index`. Empty when the pattern has no named captures.
    names: HashMap<String, usize>,
    /// Capture-group names in index order (`None` for unnamed groups), as
    /// interned frozen Ruby Strings, so `names` and `named_captures` hand
    /// the same String objects out on every call instead of building new
    /// ones. Marked by every wrapper that holds this `Arc`.
    name_index: Vec<Option<Opaque<RString>>>,
}

impl RegexInner {
    fn from_pattern(ruby: &Ruby, pattern: &str, unicode: bool) -> Result<Self, Error> {
        let regex = RegexBuilder::new(pattern)
            .unicode(unicode)
            .build()
            .map_err(|e| arg_error(e.to_string()))?;

        let mut names = HashMap::new();
        let mut name_index = Vec::with_capacity(regex.captures_len());
        for (idx, name) in regex.capture_names().enumerate() {
            name_index.push(name.map(|n| {
                names.insert(n.to_owned(), idx);
                Opaque::from(ruby.str_new(n).to_interned_str())
            }));
        }

        Ok(Self {
            regex,
            names,
            name_index,
        })
    }

    fn mark(&self, marker: &gc::Marker) {
        for name in self.name_index.iter().flatten() {
            marker.mark(*name);
        }
    }

    /// Capture-group names in declaration order, unnamed groups skipped.
    fn names(&self, ruby: &Ruby) -> RArray {
        ruby.ary_from_iter(self.name_index.iter().skip(1).flatten().map(|name| ruby.get_inner(*name)))
    }

    /// Every group's `(start, end)` for one match, index 0 the whole match.
    fn offsets(&self, caps: &regex::bytes::Captures) -> Vec<CaptureOffset> {
        (0..self.regex.captures_len())
            .map(|i| caps.get(i).map(|m| (m.start(), m.end())))
            .collect()
    }
}

#[derive(TypedData)]
#[magnus(class = "Fast::Regexp::Native", free_immediately, size, mark)]
pub struct FastRegexp(Arc<RegexInner>);

impl DataTypeFunctions for FastRegexp {
    fn mark(&self, marker: &gc::Marker) {
        self.0.mark(marker);
    }
}

impl FastRegexp {
    pub fn new(ruby: &Ruby, args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::<(String,), (), (), (), RHash, ()>(args)?;
        let kwargs = get_kwargs::<_, (), (Option<bool>,), ()>(args.keywords, &[], &["unicode"])?;

        let pattern = args.required.0;
        let (unicode,) = kwargs.optional;
        let unicode = unicode.unwrap_or(true);

        Ok(Self(Arc::new(RegexInner::from_pattern(ruby, &pattern, unicode)?)))
    }

    fn match_data(&self, haystack: RString, captures: Vec<CaptureOffset>) -> FastMatchData {
        FastMatchData {
            haystack: haystack.into(),
            captures,
            inner: self.0.clone(),
        }
    }

    /// First match as a MatchData, or nil. The search runs over the live
    /// haystack; only a hit pays for the frozen snapshot the MatchData keeps.
    pub fn rmatch(&self, haystack: RString) -> Option<FastMatchData> {
        let inner = &self.0;
        let captures = inner.regex.captures(bytes(&haystack)).map(|caps| inner.offsets(&caps))?;
        Some(self.match_data(RString::new_frozen(haystack), captures))
    }

    /// Byte offset of the first match, or nil — `=~` without a MatchData.
    pub fn find(&self, haystack: RString) -> Option<usize> {
        self.0.regex.find(bytes(&haystack)).map(|m| m.start())
    }

    pub fn scan(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let regex = &rb_self.0.regex;
        let bytes = bytes(&haystack);

        if regex.captures_len() == 1 {
            let result = ruby.ary_new();
            for m in regex.find_iter(bytes) {
                result.push(utf8_string(ruby, m.as_bytes()))?;
            }
            Ok(result)
        } else {
            let result = ruby.ary_new();
            for caps in regex.captures_iter(bytes) {
                let group = ruby.ary_new_capa(regex.captures_len() - 1);
                for m in caps.iter().skip(1) {
                    match m {
                        Some(m) => group.push(utf8_string(ruby, m.as_bytes()))?,
                        None => group.push(())?,
                    }
                }
                result.push(group)?;
            }
            Ok(result)
        }
    }

    /// Every match as a MatchData, all sharing one frozen snapshot of the
    /// haystack (taken only if there is at least one match).
    pub fn scan_matches(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let inner = &rb_self.0;
        let all: Vec<Vec<CaptureOffset>> = inner
            .regex
            .captures_iter(bytes(&haystack))
            .map(|caps| inner.offsets(&caps))
            .collect();

        let result = ruby.ary_new_capa(all.len());
        if all.is_empty() {
            return Ok(result);
        }
        let snapshot = RString::new_frozen(haystack);
        for captures in all {
            result.push(rb_self.match_data(snapshot, captures))?;
        }
        Ok(result)
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        self.0.regex.is_match(bytes(&haystack))
    }

    pub fn sub_str(
        ruby: &Ruby,
        rb_self: &Self,
        haystack: RString,
        replacement: RString,
        literal: bool,
    ) -> RString {
        let regex = &rb_self.0.regex;
        let (bytes, repl) = (bytes(&haystack), bytes(&replacement));
        let out = if literal {
            regex.replace(bytes, NoExpand(repl))
        } else {
            regex.replace(bytes, repl)
        };
        utf8_string(ruby, &out)
    }

    pub fn gsub_str(
        ruby: &Ruby,
        rb_self: &Self,
        haystack: RString,
        replacement: RString,
        literal: bool,
    ) -> RString {
        let regex = &rb_self.0.regex;
        let (bytes, repl) = (bytes(&haystack), bytes(&replacement));
        let out = if literal {
            regex.replace_all(bytes, NoExpand(repl))
        } else {
            regex.replace_all(bytes, repl)
        };
        utf8_string(ruby, &out)
    }

    /// The block forms of `sub` (`limit` 1) and `gsub` (no limit) in one
    /// pass: each match is yielded as a MatchData and the block's result
    /// (via `to_s`) is spliced in for it. The block runs arbitrary Ruby, so
    /// everything is read from a frozen snapshot of the haystack rather than
    /// the live string — the same snapshot every yielded MatchData keeps.
    fn replace_block(ruby: &Ruby, rb_self: &Self, haystack: RString, limit: Option<usize>) -> Result<RString, Error> {
        let inner = &rb_self.0;
        if !inner.regex.is_match(bytes(&haystack)) {
            // No match: a copy of the haystack, encoding and all, as
            // `String#sub`/`#gsub` return (copy-on-write, nothing copied yet).
            return Ok(RString::new_shared(haystack));
        }
        let snapshot = RString::new_frozen(haystack);
        let bytes = bytes(&snapshot);
        let mut out = Vec::with_capacity(bytes.len());
        let mut cursor = 0;
        for caps in inner.regex.captures_iter(bytes).take(limit.unwrap_or(usize::MAX)) {
            let whole = caps.get(0).expect("group 0 is the match");
            out.extend_from_slice(&bytes[cursor..whole.start()]);
            let replacement: Value = ruby.yield_value(rb_self.match_data(snapshot, inner.offsets(&caps)))?;
            let replacement = match RString::from_value(replacement) {
                Some(string) => string,
                None => replacement.funcall("to_s", ())?,
            };
            out.extend_from_slice(unsafe { replacement.as_slice() });
            cursor = whole.end();
        }
        out.extend_from_slice(&bytes[cursor..]);
        // Keep the snapshot reachable from this frame until the last read of
        // `bytes` above, whatever the yielded MatchData objects' fate.
        std::hint::black_box(snapshot);
        Ok(utf8_string(ruby, &out))
    }

    pub fn sub_block(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RString, Error> {
        Self::replace_block(ruby, rb_self, haystack, Some(1))
    }

    pub fn gsub_block(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RString, Error> {
        Self::replace_block(ruby, rb_self, haystack, None)
    }

    pub fn pattern(&self) -> &str {
        self.0.regex.as_str()
    }

    pub fn captures_count(&self) -> usize {
        // Excludes the implicit whole-match group, matching Regexp's behavior.
        self.0.regex.captures_len() - 1
    }

    pub fn names(ruby: &Ruby, rb_self: &Self) -> RArray {
        rb_self.0.names(ruby)
    }
}

/// One match: capture offsets into a frozen snapshot of the haystack. The
/// snapshot is `rb_str_new_frozen` of the caller's string — the string
/// itself when it was already frozen, otherwise a frozen copy-on-write
/// sibling sharing its buffer — so a later mutation of the caller's string
/// can't reach it, and nothing was copied to guarantee that.
#[derive(TypedData)]
#[magnus(class = "Fast::Regexp::Native::MatchData", free_immediately, size, mark)]
pub struct FastMatchData {
    haystack: Opaque<RString>,
    /// Index 0 is the whole match. Subsequent entries are capture groups in
    /// order; `None` indicates a group that did not participate.
    captures: Vec<CaptureOffset>,
    inner: Arc<RegexInner>,
}

impl DataTypeFunctions for FastMatchData {
    fn mark(&self, marker: &gc::Marker) {
        marker.mark(self.haystack);
        self.inner.mark(marker);
    }
}

impl FastMatchData {
    fn haystack(&self, ruby: &Ruby) -> RString {
        ruby.get_inner(self.haystack)
    }

    fn slice(&self, ruby: &Ruby, range: (usize, usize)) -> RString {
        let haystack = self.haystack(ruby);
        utf8_string(ruby, &bytes(&haystack)[range.0..range.1])
    }

    fn capture_index(&self, idx: i64) -> Option<usize> {
        let len = self.captures.len() as i64;
        let real = if idx < 0 { len + idx } else { idx };
        if real < 0 || real >= len {
            None
        } else {
            Some(real as usize)
        }
    }

    /// Returns `Some(Some(range))` for a participating group, `Some(None)` for
    /// a known-but-non-participating group, `None` for an out-of-range index
    /// or an unknown capture name. Dispatches on the key's type rather than
    /// attempting conversions: a failed conversion raises (and allocates an
    /// exception) on the way to being caught.
    fn resolve(&self, key: Value) -> Result<Option<CaptureOffset>, Error> {
        if let Some(index) = Integer::from_value(key) {
            return Ok(self.capture_index(index.to_i64()?).map(|i| self.captures[i]));
        }
        let by_name = |name: &str| self.inner.names.get(name).map(|&i| self.captures[i]);
        if let Some(symbol) = Symbol::from_value(key) {
            return Ok(by_name(&symbol.name()?));
        }
        if let Some(name) = RString::from_value(key) {
            return Ok(by_name(unsafe { name.as_str()? }));
        }
        // Anything else that converts to an Integer (a Float, a `to_int`
        // object) indexes like one, as `::MatchData#[]` allows.
        match i64::try_convert(key) {
            Ok(index) => Ok(self.capture_index(index).map(|i| self.captures[i])),
            Err(_) => Err(type_error(
                "no implicit conversion of capture key into Integer, String, or Symbol",
            )),
        }
    }

    fn whole(&self) -> (usize, usize) {
        self.captures[0].expect("whole match is always present")
    }

    pub fn aref(ruby: &Ruby, rb_self: &Self, key: Value) -> Result<Value, Error> {
        match rb_self.resolve(key)? {
            Some(Some(range)) => Ok(rb_self.slice(ruby, range).as_value()),
            _ => Ok(ruby.qnil().as_value()),
        }
    }

    fn slices(&self, ruby: &Ruby, captures: &[CaptureOffset]) -> Result<RArray, Error> {
        let arr = ruby.ary_new_capa(captures.len());
        for cap in captures {
            match cap {
                Some(r) => arr.push(self.slice(ruby, *r))?,
                None => arr.push(())?,
            }
        }
        Ok(arr)
    }

    pub fn to_a(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        rb_self.slices(ruby, &rb_self.captures)
    }

    pub fn captures(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        rb_self.slices(ruby, &rb_self.captures[1..])
    }

    pub fn named_captures(ruby: &Ruby, rb_self: &Self) -> Result<RHash, Error> {
        let hash = ruby.hash_new();
        // Iterate in declaration order so the hash preserves regex order.
        for (idx, name) in rb_self.inner.name_index.iter().enumerate() {
            if let Some(name) = name {
                let value: Value = match rb_self.captures[idx] {
                    Some(r) => rb_self.slice(ruby, r).as_value(),
                    None => ruby.qnil().as_value(),
                };
                hash.aset(ruby.get_inner(*name), value)?;
            }
        }
        Ok(hash)
    }

    pub fn names(ruby: &Ruby, rb_self: &Self) -> RArray {
        rb_self.inner.names(ruby)
    }

    pub fn size(&self) -> usize {
        self.captures.len()
    }

    pub fn pre_match(ruby: &Ruby, rb_self: &Self) -> RString {
        let (s, _) = rb_self.whole();
        rb_self.slice(ruby, (0, s))
    }

    pub fn post_match(ruby: &Ruby, rb_self: &Self) -> RString {
        let (_, e) = rb_self.whole();
        let haystack = rb_self.haystack(ruby);
        let len = bytes(&haystack).len();
        rb_self.slice(ruby, (e, len))
    }

    pub fn whole_match(ruby: &Ruby, rb_self: &Self) -> RString {
        rb_self.slice(ruby, rb_self.whole())
    }

    /// The frozen snapshot the match was taken over (see the struct doc).
    pub fn string(ruby: &Ruby, rb_self: &Self) -> RString {
        rb_self.haystack(ruby)
    }

    pub fn byteoffset(ruby: &Ruby, rb_self: &Self, key: Value) -> Result<Value, Error> {
        let resolved = rb_self.resolve(key)?;
        let arr = ruby.ary_new_capa(2);
        match resolved {
            Some(Some((s, e))) => {
                arr.push(s)?;
                arr.push(e)?;
            }
            Some(None) | None => {
                arr.push(())?;
                arr.push(())?;
            }
        }
        Ok(arr.as_value())
    }

    pub fn byte_begin(ruby: &Ruby, rb_self: &Self, key: Value) -> Result<Value, Error> {
        Ok(match rb_self.resolve(key)? {
            Some(Some((s, _))) => ruby.integer_from_u64(s as u64).as_value(),
            _ => ruby.qnil().as_value(),
        })
    }

    pub fn byte_end(ruby: &Ruby, rb_self: &Self, key: Value) -> Result<Value, Error> {
        Ok(match rb_self.resolve(key)? {
            Some(Some((_, e))) => ruby.integer_from_u64(e as u64).as_value(),
            _ => ruby.qnil().as_value(),
        })
    }

    pub fn inspect(ruby: &Ruby, rb_self: &Self) -> RString {
        let (s, e) = rb_self.whole();
        let haystack = rb_self.haystack(ruby);
        let matched = String::from_utf8_lossy(&bytes(&haystack)[s..e]);
        ruby.str_new(&format!("#<Fast::Regexp::MatchData {:?}>", matched))
    }
}

#[magnus::wrap(class = "Fast::Regexp::Set", free_immediately, size)]
pub struct FastRegexpSet(RegexSet);

impl FastRegexpSet {
    pub fn new(args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::<(Vec<String>,), (), (), (), RHash, ()>(args)?;
        let kwargs = get_kwargs::<_, (), (Option<bool>,), ()>(args.keywords, &[], &["unicode"])?;

        let patterns = args.required.0;
        let (unicode,) = kwargs.optional;
        let unicode = unicode.unwrap_or(true);

        let set = RegexSetBuilder::new(patterns)
            .unicode(unicode)
            .build()
            .map_err(|e| arg_error(e.to_string()))?;

        Ok(Self(set))
    }

    pub fn matches(&self, haystack: RString) -> Vec<usize> {
        self.0.matches(bytes(&haystack)).iter().collect()
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        self.0.is_match(bytes(&haystack))
    }

    pub fn patterns(&self) -> Vec<String> {
        self.0.patterns().into()
    }
}

#[magnus::init]
pub fn init(ruby: &Ruby) -> Result<(), Error> {
    let object_class = ruby.class_object();
    // Fast::Regexp and Fast::Regexp::MatchData must already be defined by
    // lib/fast_regexp.rb before this extension is required — the Ruby façade
    // owns those constants; the Native classes registered below sit under
    // them, and Native::MatchData subclasses the façade's MatchData so a
    // native match is a Fast::Regexp::MatchData with no wrapper around it.
    let fast_module: magnus::RModule = object_class.const_get("Fast")?;
    let regexp_facade: RClass = fast_module.const_get("Regexp")?;
    let match_data_facade: RClass = regexp_facade.const_get("MatchData")?;
    let regexp_class = regexp_facade.define_class("Native", object_class)?;

    regexp_class.define_singleton_method("_native_new", function!(FastRegexp::new, -1))?;
    regexp_class.define_method("_native_match", method!(FastRegexp::rmatch, 1))?;
    regexp_class.define_method("_native_find", method!(FastRegexp::find, 1))?;
    regexp_class.define_method("match?", method!(FastRegexp::is_match, 1))?;
    regexp_class.define_method("scan", method!(FastRegexp::scan, 1))?;
    regexp_class.define_method("scan_matches", method!(FastRegexp::scan_matches, 1))?;
    regexp_class.define_method("pattern", method!(FastRegexp::pattern, 0))?;
    regexp_class.define_method("captures_count", method!(FastRegexp::captures_count, 0))?;
    regexp_class.define_method("names", method!(FastRegexp::names, 0))?;
    regexp_class.define_method("_native_sub", method!(FastRegexp::sub_str, 3))?;
    regexp_class.define_method("_native_gsub", method!(FastRegexp::gsub_str, 3))?;
    regexp_class.define_method("_native_sub_block", method!(FastRegexp::sub_block, 1))?;
    regexp_class.define_method("_native_gsub_block", method!(FastRegexp::gsub_block, 1))?;

    let match_data_class = regexp_class.define_class("MatchData", match_data_facade)?;
    match_data_class.define_method("[]", method!(FastMatchData::aref, 1))?;
    match_data_class.define_method("to_a", method!(FastMatchData::to_a, 0))?;
    match_data_class.define_method("captures", method!(FastMatchData::captures, 0))?;
    match_data_class.define_method("named_captures", method!(FastMatchData::named_captures, 0))?;
    match_data_class.define_method("names", method!(FastMatchData::names, 0))?;
    match_data_class.define_method("size", method!(FastMatchData::size, 0))?;
    match_data_class.define_method("length", method!(FastMatchData::size, 0))?;
    match_data_class.define_method("pre_match", method!(FastMatchData::pre_match, 0))?;
    match_data_class.define_method("post_match", method!(FastMatchData::post_match, 0))?;
    match_data_class.define_method("match", method!(FastMatchData::whole_match, 0))?;
    match_data_class.define_method("to_s", method!(FastMatchData::whole_match, 0))?;
    match_data_class.define_method("string", method!(FastMatchData::string, 0))?;
    match_data_class.define_method("byteoffset", method!(FastMatchData::byteoffset, 1))?;
    match_data_class.define_method("byte_begin", method!(FastMatchData::byte_begin, 1))?;
    match_data_class.define_method("byte_end", method!(FastMatchData::byte_end, 1))?;
    match_data_class.define_method("inspect", method!(FastMatchData::inspect, 0))?;

    // Set stays at Fast::Regexp::Set (no fallback; rust/regex RegexSet is the only backend).
    let regexp_set_class = regexp_facade.define_class("Set", object_class)?;

    regexp_set_class.define_singleton_method("new", function!(FastRegexpSet::new, -1))?;
    regexp_set_class.define_method("match", method!(FastRegexpSet::matches, 1))?;
    regexp_set_class.define_method("match?", method!(FastRegexpSet::is_match, 1))?;
    regexp_set_class.define_method("patterns", method!(FastRegexpSet::patterns, 0))?;

    Ok(())
}
