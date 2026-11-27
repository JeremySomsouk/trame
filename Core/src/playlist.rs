use std::collections::HashSet;
use std::io::BufRead;

use url::Url;

use crate::{Catalog, Error, MediaItem, MediaKind, is_web_address};

pub fn parse(source: &[u8], origin: &str, name: &str) -> Result<Catalog, Error> {
    let mut items = Vec::new();
    let mut urls = HashSet::new();
    visit(source, origin, name, |item, manifest| {
        if manifest {
            items.clear();
        }
        if manifest || urls.insert(item.url.clone()) {
            items.push(item);
        }
        Ok(())
    })?;
    Ok(Catalog {
        name: name.to_owned(),
        items,
    })
}

// A late HLS tag supersedes any entries already delivered for this source.
pub(crate) fn visit(
    mut input: impl BufRead,
    origin: &str,
    name: &str,
    mut emit: impl FnMut(MediaItem, bool) -> Result<(), Error>,
) -> Result<(), Error> {
    let origin = Url::parse(origin).map_err(|_| Error::InvalidAddress)?;
    let mut header = false;
    let mut found = false;
    let mut title = String::new();
    let mut group = String::new();
    let mut poster = None;
    let mut declared_kind = None;
    let mut bytes = Vec::new();
    loop {
        bytes.clear();
        if input
            .read_until(b'\n', &mut bytes)
            .map_err(|_| Error::InvalidResponse)?
            == 0
        {
            break;
        }
        let line = String::from_utf8_lossy(&bytes);
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if !header {
            if line
                .trim_start_matches('\u{feff}')
                .split_ascii_whitespace()
                .next()
                != Some("#EXTM3U")
            {
                return Err(Error::InvalidPlaylist);
            }
            header = true;
            continue;
        }
        if line.starts_with("#EXT-X-STREAM-INF:") || line.starts_with("#EXT-X-TARGETDURATION:") {
            if origin.scheme() == "content" {
                return Err(Error::LocalHls);
            }
            return emit(
                MediaItem {
                    kind: MediaKind::Live,
                    opens_episodes: false,
                    name: name.to_owned(),
                    group: String::new(),
                    url: origin,
                    poster_url: None,
                },
                true,
            );
        }
        if let Some(value) = line.strip_prefix("#EXTINF:") {
            let (label, category, kind, logo) = metadata(value);
            poster = crate::poster_url(&origin, logo);
            title.clear();
            title.push_str(label);
            group.clear();
            group.push_str(category);
            declared_kind = kind;
        } else if let Some(value) = line.strip_prefix("#EXTGRP:") {
            group.clear();
            group.push_str(value.trim());
        } else if !line.starts_with('#') {
            if let Ok(url) = origin.join(line)
                && (is_web_address(&url) || (origin.scheme() == "file" && url.scheme() == "file"))
            {
                if title.is_empty() {
                    title.push_str(
                        url.path_segments()
                            .and_then(Iterator::last)
                            .filter(|segment| !segment.is_empty())
                            .or(url.host_str())
                            .unwrap_or("Chaîne"),
                    );
                }
                emit(
                    MediaItem {
                        kind: declared_kind.unwrap_or_else(|| kind_for_url(&url)),
                        opens_episodes: false,
                        name: std::mem::take(&mut title),
                        group: crate::group_path(&group),
                        url,
                        poster_url: poster.take(),
                    },
                    false,
                )?;
                found = true;
            }
            title.clear();
            group.clear();
            declared_kind = None;
            poster = None;
        }
    }
    if !header {
        return Err(Error::InvalidPlaylist);
    }
    if !found {
        return Err(Error::EmptyPlaylist);
    }
    Ok(())
}

fn metadata(value: &str) -> (&str, &str, Option<MediaKind>, Option<&str>) {
    let mut quoted = false;
    let delimiter = value.char_indices().find_map(|(index, c)| match c {
        '"' => {
            quoted = !quoted;
            None
        }
        ',' if !quoted => Some(index),
        _ => None,
    });
    let (attributes, title) =
        delimiter.map_or((value, ""), |at| (&value[..at], value[at + 1..].trim()));
    let mut group = "";
    let mut logo = None;
    let mut tvg_name = "";
    let mut kind = None;
    let mut rest = attributes
        .find(char::is_whitespace)
        .map_or("", |at| &attributes[at..]);
    // The duration is followed by name="value" attributes. Consume entire quoted
    // values so that commas, spaces, and text resembling attributes stay literal.
    while let Some((key, value)) = rest.trim_start().split_once('=') {
        let Some(value) = value.trim_start().strip_prefix('"') else {
            rest = value
                .find(char::is_whitespace)
                .map_or("", |at| &value[at..]);
            continue;
        };
        let Some((value, tail)) = value.split_once('"') else {
            break;
        };
        match key.trim() {
            "group-title" => group = value.trim(),
            "tvg-logo" => logo = Some(value),
            "tvg-name" => tvg_name = value.trim(),
            "type" | "tvg-type" => {
                let parsed = match value.trim().to_ascii_lowercase().as_str() {
                    "live" | "tv" => Some(MediaKind::Live),
                    "movie" | "movies" | "vod" => Some(MediaKind::Movies),
                    "series" | "episode" => Some(MediaKind::Series),
                    _ => None,
                };
                kind = parsed.or(kind);
            }
            _ => {}
        }
        rest = tail;
    }
    (
        if title.is_empty() { tvg_name } else { title },
        group,
        kind,
        logo,
    )
}

pub(crate) fn kind_for_url(url: &Url) -> MediaKind {
    let path = url.path();
    let stream_route = path.split('/').rev().nth(3);
    match stream_route {
        Some("series") => MediaKind::Series,
        Some("live") => MediaKind::Live,
        Some("movie") => MediaKind::Movies,
        _ => {
            let ext = path
                .rsplit('/')
                .next()
                .and_then(|name| name.rsplit_once('.'));
            if ext.is_some_and(|(_, ext)| {
                matches!(
                    ext.to_ascii_lowercase().as_str(),
                    "mp4" | "m4v" | "mov" | "mkv" | "avi" | "webm" | "mpg" | "mpeg"
                )
            }) {
                MediaKind::Movies
            } else {
                MediaKind::Live
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn late_hls_tag_replaces_preceding_channels() {
        let origin = "https://example.test/list.m3u8";
        let catalog = parse(
            b"#EXTM3U\nfirst.ts\n#EXT-X-TARGETDURATION:8\nsecond.ts",
            origin,
            "Live",
        )
        .unwrap();
        assert_eq!(catalog.items.len(), 1);
        assert_eq!(catalog.items[0].url.as_str(), origin);
    }

    #[test]
    fn mixed_playlist_types_do_not_imply_episode_lookup() {
        let catalog = parse(
            br#"#EXTM3U
#EXTINF:-1 tvg-type="movie" tvg-logo="/art.jpg",Film
/watch/1
#EXTINF:-1 type="series",Episode
/episode.mp4
/live/account/token/2.m3u8
"#,
            "https://example.test/catalog.m3u",
            "Test",
        )
        .unwrap();
        let kinds: Vec<_> = catalog.items.iter().map(|item| item.kind).collect();
        assert_eq!(
            kinds,
            [MediaKind::Movies, MediaKind::Series, MediaKind::Live]
        );
        assert!(catalog.items.iter().all(|item| !item.opens_episodes));
        assert_eq!(
            catalog.items[0].poster_url.as_ref().unwrap().path(),
            "/art.jpg"
        );
        assert!(catalog.items[1].poster_url.is_none());
    }

    #[test]
    fn rejects_remote_file_urls_and_preserves_quoted_commas() {
        let catalog = parse(
            b"#EXTM3U\r\n#EXTINF:-1 group-title=\"Info, monde\",Le direct\r\nlive.m3u8\r\nfile:///tmp/test.mp4",
            "https://example.test/redirected/index.m3u",
            "Test",
        )
        .unwrap();
        assert_eq!(catalog.items.len(), 1);
        let channel = &catalog.items[0];
        assert_eq!(channel.group, "Info, monde");
        assert_eq!(
            channel.url.as_str(),
            "https://example.test/redirected/live.m3u8"
        );
    }
}
