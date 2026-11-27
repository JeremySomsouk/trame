//! JNI transport only. Kotlin supplies bounded temporary files and consumes rows
//! directly into its SQLite transaction, without building a second catalogue on the JVM.
use crate::Error;
use jni::{
    JNIEnv,
    objects::{JObject, JString, JValue},
    sys::{jint, jstring},
};

enum Failure {
    Core(Error),
    Jni(jni::errors::Error),
}
impl From<Error> for Failure {
    fn from(e: Error) -> Self {
        Self::Core(e)
    }
}
impl From<jni::errors::Error> for Failure {
    fn from(e: jni::errors::Error) -> Self {
        Self::Jni(e)
    }
}
type Result<T> = std::result::Result<T, Failure>;

fn call<T: Default>(env: &mut JNIEnv, f: impl FnOnce(&mut JNIEnv) -> Result<T>) -> T {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(env)));
    let message = match result {
        Ok(Ok(value)) => return value,
        Ok(Err(Failure::Jni(jni::errors::Error::JavaException))) => return T::default(),
        Ok(Err(Failure::Core(Error::InvalidAddress))) => "Vérifiez le serveur et les identifiants.",
        Ok(Err(Failure::Core(Error::InvalidPlaylist))) => "Le fichier doit être une playlist M3U.",
        Ok(Err(Failure::Core(Error::EmptyPlaylist))) => "Aucun titre lisible dans cette source.",
        Ok(Err(Failure::Core(Error::LocalHls))) => {
            "Pour un flux HLS, utilisez l’adresse web du manifeste."
        }
        _ => "Réponse de catalogue inattendue.",
    };
    if env.exception_check().unwrap_or(true) {
        return T::default();
    }
    let _ = env.throw_new("app/trame/player/SourceError", message);
    T::default()
}

fn text(env: &mut JNIEnv, value: &JString) -> Result<String> {
    Ok(env.get_string(value)?.into())
}

fn reader(fd: jint) -> Result<std::io::BufReader<std::fs::File>> {
    use std::os::fd::BorrowedFd;
    if fd < 0 {
        return Err(Error::InvalidResponse.into());
    }
    // Kotlin keeps the descriptor open until the JNI call returns.
    let owned = unsafe { BorrowedFd::borrow_raw(fd) }
        .try_clone_to_owned()
        .map_err(|_| Error::InvalidResponse)?;
    Ok(std::io::BufReader::with_capacity(
        64 * 1024,
        std::fs::File::from(owned),
    ))
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_login(
    mut env: JNIEnv,
    _: JObject,
    server: JString,
    user: JString,
    password: JString,
    kind: JString,
) -> jstring {
    call(&mut env, |env| {
        let url = crate::xtream_login(
            &text(env, &server)?,
            &text(env, &user)?,
            &text(env, &password)?,
            &text(env, &kind)?,
        )?;
        Ok(env.new_string(url.as_str())?.into_raw())
    })
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_endpoints(
    mut env: JNIEnv,
    _: JObject,
    login: JString,
) -> jstring {
    call(&mut env, |env| {
        let urls = crate::xtream_endpoints(&text(env, &login)?)?;
        let json = serde_json::to_string(&urls).map_err(|_| Error::InvalidResponse)?;
        Ok(env.new_string(json)?.into_raw())
    })
}

// Stable values shared with the Android library database.
fn category(kind: crate::MediaKind) -> jint {
    match kind {
        crate::MediaKind::Live => 1,
        crate::MediaKind::Movies => 2,
        crate::MediaKind::Series => 3,
    }
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_legacyCategory(
    mut env: JNIEnv,
    _: JObject,
    address: JString,
) -> jint {
    call(&mut env, |env| {
        Ok(url::Url::parse(&text(env, &address)?)
            .map(|url| category(crate::playlist::kind_for_url(&url)))
            .unwrap_or_default())
    })
}

fn deliver(
    env: &mut JNIEnv,
    sink: &JObject,
    item: crate::MediaItem,
) -> std::result::Result<(), Error> {
    env.with_local_frame(8, |env| -> jni::errors::Result<()> {
        let url = env.new_string(item.url.as_str())?;
        let name = env.new_string(item.name)?;
        let group = env.new_string(item.group)?;
        let poster = match item.poster_url {
            Some(url) => JObject::from(env.new_string(url.as_str())?),
            None => JObject::null(),
        };
        env.call_method(
            sink,
            "item",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IZLjava/lang/String;)V",
            &[
                (&url).into(),
                (&name).into(),
                (&group).into(),
                JValue::Int(category(item.kind)),
                JValue::Bool(item.opens_episodes.into()),
                (&poster).into(),
            ],
        )?;
        Ok(())
    })
    .map_err(|_| Error::InvalidResponse)
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_playlist(
    mut env: JNIEnv,
    _: JObject,
    origin: JString,
    name: JString,
    input: jint,
    sink: JObject,
) {
    call(&mut env, |env| {
        let origin = text(env, &origin)?;
        let name = text(env, &name)?;
        crate::playlist::visit(reader(input)?, &origin, &name, |item, manifest| {
            if manifest {
                env.call_method(&sink, "reset", "()V", &[])
                    .map_err(|_| Error::InvalidResponse)?;
            }
            deliver(env, &sink, item)
        })?;
        Ok(())
    })
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_catalog(
    mut env: JNIEnv,
    _: JObject,
    login: JString,
    streams: jint,
    groups: jint,
    sink: JObject,
) {
    call(&mut env, |env| {
        let server = crate::xtream::Server::from_login(&text(env, &login)?)?;
        server.visit_catalog(
            server.kind,
            serde_json::Deserializer::from_reader(reader(streams)?),
            serde_json::Deserializer::from_reader(reader(groups)?),
            |item| deliver(env, &sink, item),
        )?;
        Ok(())
    })
}

#[unsafe(no_mangle)]
extern "system" fn Java_app_trame_player_NativeCore_episodes(
    mut env: JNIEnv,
    _: JObject,
    endpoint: JString,
    input: jint,
) -> jstring {
    call(&mut env, |env| {
        let episodes = crate::xtream::episodes_from_reader(&text(env, &endpoint)?, reader(input)?)?;
        let json = serde_json::to_string(&episodes).map_err(|_| Error::InvalidResponse)?;
        Ok(env.new_string(json)?.into_raw())
    })
}
