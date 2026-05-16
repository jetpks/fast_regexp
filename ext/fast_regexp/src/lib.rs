use magnus::{
    function, method,
    scan_args::{get_kwargs, scan_args},
    value::ReprValue,
    Error, Module, Object, RArray, RClass, RHash, RString, Ruby, Symbol, TryConvert, Value,
};
use regex::bytes::{NoExpand, Regex, RegexBuilder, RegexSet, RegexSetBuilder};
use std::collections::HashMap;
use std::sync::Arc;

fn haystack_bytes(haystack: &RString) -> Vec<u8> {
    unsafe { haystack.as_slice() }.to_vec()
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

/// Inner state shared between a compiled regex and any [`FastMatchData`] it
/// produces — wrapped in `Arc` so positions, names, and haystack bytes can be
/// shared cheaply across many matches (e.g. from `#scan_matches`).
struct RegexInner {
    regex: Regex,
    /// `name -> capture index`. Empty when the pattern has no named captures.
    names: HashMap<String, usize>,
    /// Ordered list of capture-group names (None for unnamed groups), matching
    /// the indices produced by `regex.captures_iter()`.
    name_index: Vec<Option<String>>,
}

impl RegexInner {
    fn from_pattern(pattern: &str, unicode: bool) -> Result<Self, Error> {
        let regex = RegexBuilder::new(pattern)
            .unicode(unicode)
            .build()
            .map_err(|e| arg_error(e.to_string()))?;

        let name_index: Vec<Option<String>> =
            regex.capture_names().map(|n| n.map(String::from)).collect();
        let mut names = HashMap::new();
        for (idx, name) in name_index.iter().enumerate() {
            if let Some(n) = name {
                names.insert(n.clone(), idx);
            }
        }

        Ok(Self {
            regex,
            names,
            name_index,
        })
    }
}

#[magnus::wrap(class = "Fast::Regexp::Native", free_immediately, size)]
pub struct FastRegexp(Arc<RegexInner>);

impl FastRegexp {
    pub fn new(args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::<(String,), (), (), (), RHash, ()>(args)?;
        let kwargs = get_kwargs::<_, (), (Option<bool>,), ()>(args.keywords, &[], &["unicode"])?;

        let pattern = args.required.0;
        let (unicode,) = kwargs.optional;
        let unicode = unicode.unwrap_or(true);

        Ok(Self(Arc::new(RegexInner::from_pattern(&pattern, unicode)?)))
    }

    fn build_match_data(
        &self,
        haystack: Arc<Vec<u8>>,
        offsets: Vec<CaptureOffset>,
    ) -> FastMatchData {
        FastMatchData {
            haystack,
            captures: offsets,
            inner: self.0.clone(),
        }
    }

    pub fn rmatch(&self, haystack: RString) -> Option<FastMatchData> {
        let regex = &self.0.regex;
        let bytes = haystack_bytes(&haystack);

        let offsets = regex.captures(&bytes).map(|caps| {
            (0..regex.captures_len())
                .map(|i| caps.get(i).map(|m| (m.start(), m.end())))
                .collect::<Vec<_>>()
        })?;

        Some(self.build_match_data(Arc::new(bytes), offsets))
    }

    pub fn scan(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let regex = &rb_self.0.regex;
        let bytes = haystack_bytes(&haystack);

        if regex.captures_len() == 1 {
            let ranges: Vec<(usize, usize)> = regex
                .find_iter(&bytes)
                .map(|m| (m.start(), m.end()))
                .collect();
            let result = ruby.ary_new_capa(ranges.len());
            for (s, e) in ranges {
                result.push(utf8_string(ruby, &bytes[s..e]))?;
            }
            Ok(result)
        } else {
            let groups: Vec<Vec<CaptureOffset>> = regex
                .captures_iter(&bytes)
                .map(|caps| {
                    caps.iter()
                        .skip(1)
                        .map(|c| c.map(|m| (m.start(), m.end())))
                        .collect()
                })
                .collect();
            let result = ruby.ary_new_capa(groups.len());
            for group_ranges in groups {
                let group = ruby.ary_new_capa(group_ranges.len());
                for range in group_ranges {
                    match range {
                        Some((s, e)) => group.push(utf8_string(ruby, &bytes[s..e]))?,
                        None => group.push(())?,
                    }
                }
                result.push(group)?;
            }
            Ok(result)
        }
    }

    pub fn scan_matches(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let regex = &rb_self.0.regex;
        let bytes = haystack_bytes(&haystack);
        let n_groups = regex.captures_len();

        let all: Vec<Vec<CaptureOffset>> = regex
            .captures_iter(&bytes)
            .map(|caps| {
                (0..n_groups)
                    .map(|i| caps.get(i).map(|m| (m.start(), m.end())))
                    .collect()
            })
            .collect();

        let shared = Arc::new(bytes);
        let result = ruby.ary_new_capa(all.len());
        for offsets in all {
            result.push(rb_self.build_match_data(shared.clone(), offsets))?;
        }
        Ok(result)
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        let regex = &self.0.regex;
        let bytes = haystack_bytes(&haystack);
        regex.is_match(&bytes)
    }

    pub fn sub_str(
        ruby: &Ruby,
        rb_self: &Self,
        haystack: RString,
        replacement: RString,
        literal: bool,
    ) -> RString {
        let regex = &rb_self.0.regex;
        let bytes = haystack_bytes(&haystack);
        let repl = haystack_bytes(&replacement);
        let out: Vec<u8> = if literal {
            regex.replace(&bytes, NoExpand(&repl)).into_owned()
        } else {
            regex.replace(&bytes, &repl[..]).into_owned()
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
        let bytes = haystack_bytes(&haystack);
        let repl = haystack_bytes(&replacement);
        let out: Vec<u8> = if literal {
            regex.replace_all(&bytes, NoExpand(&repl)).into_owned()
        } else {
            regex.replace_all(&bytes, &repl[..]).into_owned()
        };
        utf8_string(ruby, &out)
    }

    pub fn pattern(&self) -> &str {
        self.0.regex.as_str()
    }

    pub fn captures_count(&self) -> usize {
        // Excludes the implicit whole-match group, matching Regexp's behavior.
        self.0.regex.captures_len() - 1
    }

    pub fn names(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let arr = ruby.ary_new();
        for name in rb_self.0.name_index.iter().skip(1).flatten() {
            arr.push(name.as_str())?;
        }
        Ok(arr)
    }
}

#[magnus::wrap(class = "Fast::Regexp::Native::MatchData", free_immediately, size)]
pub struct FastMatchData {
    haystack: Arc<Vec<u8>>,
    /// Index 0 is the whole match. Subsequent entries are capture groups in
    /// order; `None` indicates a group that did not participate.
    captures: Vec<CaptureOffset>,
    inner: Arc<RegexInner>,
}

impl FastMatchData {
    fn slice(&self, ruby: &Ruby, range: (usize, usize)) -> RString {
        utf8_string(ruby, &self.haystack[range.0..range.1])
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
    /// or an unknown capture name.
    fn resolve(&self, key: Value) -> Result<Option<CaptureOffset>, Error> {
        if let Ok(i) = <i64 as TryConvert>::try_convert(key) {
            return Ok(self.capture_index(i).map(|i| self.captures[i]));
        }
        if let Ok(sym) = <Symbol as TryConvert>::try_convert(key) {
            let name = sym.name()?.into_owned();
            return Ok(self.inner.names.get(&name).map(|&i| self.captures[i]));
        }
        if let Ok(name) = <String as TryConvert>::try_convert(key) {
            return Ok(self.inner.names.get(&name).map(|&i| self.captures[i]));
        }
        Err(type_error(
            "no implicit conversion of capture key into Integer, String, or Symbol",
        ))
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

    pub fn to_a(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let arr = ruby.ary_new_capa(rb_self.captures.len());
        for cap in &rb_self.captures {
            match cap {
                Some(r) => arr.push(rb_self.slice(ruby, *r))?,
                None => arr.push(())?,
            }
        }
        Ok(arr)
    }

    pub fn captures(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let arr = ruby.ary_new_capa(rb_self.captures.len() - 1);
        for cap in rb_self.captures.iter().skip(1) {
            match cap {
                Some(r) => arr.push(rb_self.slice(ruby, *r))?,
                None => arr.push(())?,
            }
        }
        Ok(arr)
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
                hash.aset(name.as_str(), value)?;
            }
        }
        Ok(hash)
    }

    pub fn names(ruby: &Ruby, rb_self: &Self) -> Result<RArray, Error> {
        let arr = ruby.ary_new();
        for name in rb_self.inner.name_index.iter().skip(1).flatten() {
            arr.push(name.as_str())?;
        }
        Ok(arr)
    }

    pub fn size(&self) -> usize {
        self.captures.len()
    }

    pub fn pre_match(ruby: &Ruby, rb_self: &Self) -> RString {
        let (s, _) = rb_self.whole();
        utf8_string(ruby, &rb_self.haystack[..s])
    }

    pub fn post_match(ruby: &Ruby, rb_self: &Self) -> RString {
        let (_, e) = rb_self.whole();
        utf8_string(ruby, &rb_self.haystack[e..])
    }

    pub fn whole_match(ruby: &Ruby, rb_self: &Self) -> RString {
        rb_self.slice(ruby, rb_self.whole())
    }

    pub fn string(ruby: &Ruby, rb_self: &Self) -> RString {
        let s = utf8_string(ruby, &rb_self.haystack);
        s.freeze();
        s
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
        let matched = String::from_utf8_lossy(&rb_self.haystack[s..e]);
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
        let set = &self.0;
        let bytes = haystack_bytes(&haystack);
        set.matches(&bytes).iter().collect()
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        let set = &self.0;
        let bytes = haystack_bytes(&haystack);
        set.is_match(&bytes)
    }

    pub fn patterns(&self) -> Vec<String> {
        self.0.patterns().into()
    }
}

#[magnus::init]
pub fn init(ruby: &Ruby) -> Result<(), Error> {
    let object_class = ruby.class_object();
    // Fast::Regexp must already be defined as a class by lib/fast_regexp.rb
    // before this extension is required — the Ruby façade owns that constant
    // and delegates to the Native class registered below.
    let fast_module: magnus::RModule = object_class.const_get("Fast")?;
    let regexp_facade: RClass = fast_module.const_get("Regexp")?;
    let regexp_class = regexp_facade.define_class("Native", object_class)?;

    regexp_class.define_singleton_method("_native_new", function!(FastRegexp::new, -1))?;
    regexp_class.define_method("_native_match", method!(FastRegexp::rmatch, 1))?;
    regexp_class.define_method("match?", method!(FastRegexp::is_match, 1))?;
    regexp_class.define_method("scan", method!(FastRegexp::scan, 1))?;
    regexp_class.define_method("scan_matches", method!(FastRegexp::scan_matches, 1))?;
    regexp_class.define_method("pattern", method!(FastRegexp::pattern, 0))?;
    regexp_class.define_method("captures_count", method!(FastRegexp::captures_count, 0))?;
    regexp_class.define_method("names", method!(FastRegexp::names, 0))?;
    regexp_class.define_method("_native_sub", method!(FastRegexp::sub_str, 3))?;
    regexp_class.define_method("_native_gsub", method!(FastRegexp::gsub_str, 3))?;

    let match_data_class = regexp_class.define_class("MatchData", object_class)?;
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
