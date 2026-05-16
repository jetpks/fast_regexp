use magnus::{
    function, method,
    scan_args::{get_kwargs, scan_args},
    Error, Module, Object, RArray, RHash, RString, Ruby, Value,
};
use regex::bytes::{Regex, RegexBuilder, RegexSet, RegexSetBuilder};
use std::ffi::c_void;
use std::ptr;

/// Skip GVL release for haystacks smaller than this — the release/reacquire
/// overhead (~µs) dwarfs the cost of a regex match on a tiny string.
const GVL_RELEASE_THRESHOLD: usize = 1024;

/// Run `func` with the GVL released so other Ruby threads (and the fiber
/// scheduler on its host thread) can make progress during a long regex match.
///
/// The callback runs on the same OS thread — `Send` is not required, and the
/// borrow checker enforces that any references stay valid for the call.
fn without_gvl<F, R>(func: F) -> R
where
    F: FnOnce() -> R,
{
    struct Pack<F, R> {
        func: Option<F>,
        result: Option<R>,
    }

    unsafe extern "C" fn trampoline<F, R>(data: *mut c_void) -> *mut c_void
    where
        F: FnOnce() -> R,
    {
        let pack = &mut *(data as *mut Pack<F, R>);
        let func = pack.func.take().expect("trampoline called twice");
        pack.result = Some(func());
        ptr::null_mut()
    }

    let mut pack: Pack<F, R> = Pack {
        func: Some(func),
        result: None,
    };
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(trampoline::<F, R>),
            &mut pack as *mut _ as *mut c_void,
            None,
            ptr::null_mut(),
        );
    }
    pack.result.take().expect("callback did not run")
}

/// Run a regex closure, releasing the GVL only when the haystack is large
/// enough to make the release worthwhile.
fn run_regex<F, R>(haystack_len: usize, func: F) -> R
where
    F: FnOnce() -> R,
{
    if haystack_len >= GVL_RELEASE_THRESHOLD {
        without_gvl(func)
    } else {
        func()
    }
}

fn haystack_bytes(haystack: &RString) -> Vec<u8> {
    // Copy out of the Ruby heap so the bytes are safe to read after the GVL is
    // released (Ruby 4's compacting GC can otherwise move the string).
    unsafe { haystack.as_slice() }.to_vec()
}

fn new_rb_string(ruby: &Ruby, bytes: &[u8]) -> RString {
    ruby.enc_str_new(bytes, ruby.utf8_encoding())
}

#[magnus::wrap(class = "RustRegexp", free_immediately, size)]
pub struct RustRegexp(Regex);

impl RustRegexp {
    pub fn new(args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::<(String,), (), (), (), RHash, ()>(args)?;
        let kwargs = get_kwargs::<_, (), (Option<bool>,), ()>(args.keywords, &[], &["unicode"])?;

        let pattern = args.required.0;
        let (unicode,) = kwargs.optional;
        let unicode = unicode.unwrap_or(true);

        let regex = RegexBuilder::new(&pattern)
            .unicode(unicode)
            .build()
            .map_err(|e| Error::new(Ruby::get().unwrap().exception_arg_error(), e.to_string()))?;

        Ok(Self(regex))
    }

    pub fn find(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let regex = &rb_self.0;
        let bytes = haystack_bytes(&haystack);

        // no capture groups defined except the default one
        if regex.captures_len() == 1 {
            // speed optimization, `.find` is faster than `.captures`
            let range = run_regex(bytes.len(), || {
                regex.find(&bytes).map(|m| (m.start(), m.end()))
            });
            let result = ruby.ary_new();
            if let Some((s, e)) = range {
                result.push(new_rb_string(ruby, &bytes[s..e]))?;
            }
            Ok(result)
        } else {
            let ranges: Option<Vec<Option<(usize, usize)>>> = run_regex(bytes.len(), || {
                regex.captures(&bytes).map(|caps| {
                    caps.iter()
                        .skip(1)
                        .map(|c| c.map(|m| (m.start(), m.end())))
                        .collect()
                })
            });
            let result = ruby.ary_new();
            if let Some(ranges) = ranges {
                for range in ranges {
                    match range {
                        Some((s, e)) => result.push(new_rb_string(ruby, &bytes[s..e]))?,
                        None => result.push(())?,
                    }
                }
            }
            Ok(result)
        }
    }

    pub fn scan(ruby: &Ruby, rb_self: &Self, haystack: RString) -> Result<RArray, Error> {
        let regex = &rb_self.0;
        let bytes = haystack_bytes(&haystack);

        if regex.captures_len() == 1 {
            // speed optimization, `.find_iter` is faster than `.captures_iter`
            let ranges: Vec<(usize, usize)> = run_regex(bytes.len(), || {
                regex.find_iter(&bytes).map(|m| (m.start(), m.end())).collect()
            });
            let result = ruby.ary_new_capa(ranges.len());
            for (s, e) in ranges {
                result.push(new_rb_string(ruby, &bytes[s..e]))?;
            }
            Ok(result)
        } else {
            let groups: Vec<Vec<Option<(usize, usize)>>> = run_regex(bytes.len(), || {
                regex
                    .captures_iter(&bytes)
                    .map(|caps| {
                        caps.iter()
                            .skip(1)
                            .map(|c| c.map(|m| (m.start(), m.end())))
                            .collect()
                    })
                    .collect()
            });
            let result = ruby.ary_new_capa(groups.len());
            for group_ranges in groups {
                let group = ruby.ary_new_capa(group_ranges.len());
                for range in group_ranges {
                    match range {
                        Some((s, e)) => group.push(new_rb_string(ruby, &bytes[s..e]))?,
                        None => group.push(())?,
                    }
                }
                result.push(group)?;
            }
            Ok(result)
        }
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        let regex = &self.0;
        let bytes = haystack_bytes(&haystack);
        run_regex(bytes.len(), || regex.is_match(&bytes))
    }

    pub fn pattern(&self) -> &str {
        self.0.as_str()
    }
}

#[magnus::wrap(class = "RustRegexp::Set", free_immediately, size)]
pub struct RustRegexpSet(RegexSet);

impl RustRegexpSet {
    pub fn new(args: &[Value]) -> Result<Self, Error> {
        let args = scan_args::<(Vec<String>,), (), (), (), RHash, ()>(args)?;
        let kwargs = get_kwargs::<_, (), (Option<bool>,), ()>(args.keywords, &[], &["unicode"])?;

        let patterns = args.required.0;
        let (unicode,) = kwargs.optional;
        let unicode = unicode.unwrap_or(true);

        let set = RegexSetBuilder::new(patterns)
            .unicode(unicode)
            .build()
            .map_err(|e| Error::new(Ruby::get().unwrap().exception_arg_error(), e.to_string()))?;

        Ok(Self(set))
    }

    pub fn matches(&self, haystack: RString) -> Vec<usize> {
        let set = &self.0;
        let bytes = haystack_bytes(&haystack);
        run_regex(bytes.len(), || set.matches(&bytes).iter().collect())
    }

    pub fn is_match(&self, haystack: RString) -> bool {
        let set = &self.0;
        let bytes = haystack_bytes(&haystack);
        run_regex(bytes.len(), || set.is_match(&bytes))
    }

    pub fn patterns(&self) -> Vec<String> {
        self.0.patterns().into()
    }
}

#[magnus::init]
pub fn init(ruby: &Ruby) -> Result<(), Error> {
    let object_class = ruby.class_object();
    let regexp_class = ruby.define_class("RustRegexp", object_class)?;

    regexp_class.define_singleton_method("new", function!(RustRegexp::new, -1))?;
    regexp_class.define_method("match", method!(RustRegexp::find, 1))?;
    regexp_class.define_method("match?", method!(RustRegexp::is_match, 1))?;
    regexp_class.define_method("scan", method!(RustRegexp::scan, 1))?;
    regexp_class.define_method("pattern", method!(RustRegexp::pattern, 0))?;

    let regexp_set_class = regexp_class.define_class("Set", object_class)?;

    regexp_set_class.define_singleton_method("new", function!(RustRegexpSet::new, -1))?;
    regexp_set_class.define_method("match", method!(RustRegexpSet::matches, 1))?;
    regexp_set_class.define_method("match?", method!(RustRegexpSet::is_match, 1))?;
    regexp_set_class.define_method("patterns", method!(RustRegexpSet::patterns, 0))?;

    Ok(())
}
