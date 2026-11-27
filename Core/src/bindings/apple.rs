use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use serde::Serialize;

use crate::Error;

unsafe fn bytes<'a>(data: *const u8, len: usize) -> Result<&'a [u8], Error> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() || len > isize::MAX as usize {
        return Err(Error::InvalidResponse);
    }
    // The caller owns the slice for the duration of the call.
    Ok(unsafe { std::slice::from_raw_parts(data, len) })
}

unsafe fn string<'a>(data: *const c_char) -> Result<&'a str, Error> {
    if data.is_null() {
        return Err(Error::InvalidAddress);
    }
    // The caller provides a NUL-terminated UTF-8 string.
    unsafe { CStr::from_ptr(data) }
        .to_str()
        .map_err(|_| Error::InvalidAddress)
}

fn response<T: Serialize>(operation: impl FnOnce() -> Result<T, Error>) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(|| serde_json::to_vec(&operation()))) {
        Ok(Ok(data)) => CString::new(data).map_or(ptr::null_mut(), CString::into_raw),
        _ => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_media_kind(address: *const c_char) -> u8 {
    let Some(url) = (unsafe { string(address) })
        .ok()
        .and_then(|s| url::Url::parse(s).ok())
    else {
        return 0;
    };
    match crate::playlist::kind_for_url(&url) {
        crate::MediaKind::Live => 1,
        crate::MediaKind::Movies => 2,
        crate::MediaKind::Series => 3,
    }
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_parse_playlist(
    source: *const u8,
    len: usize,
    origin: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    response(|| unsafe {
        crate::parse_playlist(bytes(source, len)?, string(origin)?, string(name)?)
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_xtream_login(
    server: *const c_char,
    username: *const c_char,
    password: *const c_char,
    kind: *const c_char,
) -> *mut c_char {
    response(|| unsafe {
        crate::xtream_login(
            string(server)?,
            string(username)?,
            string(password)?,
            string(kind)?,
        )
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_xtream_endpoints(login: *const c_char) -> *mut c_char {
    response(|| unsafe { crate::xtream_endpoints(string(login)?) })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_xtream_catalog(
    login: *const c_char,
    streams: *const u8,
    stream_len: usize,
    categories: *const u8,
    category_len: usize,
) -> *mut c_char {
    response(|| unsafe {
        crate::xtream_catalog(
            string(login)?,
            bytes(streams, stream_len)?,
            bytes(categories, category_len)?,
        )
    })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_xtream_episodes(
    endpoint: *const c_char,
    data: *const u8,
    len: usize,
) -> *mut c_char {
    response(|| unsafe { crate::xtream_episodes(string(endpoint)?, bytes(data, len)?) })
}

#[unsafe(no_mangle)]
unsafe extern "C" fn trame_free(result: *mut c_char) {
    if !result.is_null() {
        drop(unsafe { CString::from_raw(result) });
    }
}
