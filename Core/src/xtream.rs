use std::collections::{HashMap, HashSet};
use std::io::Read;

use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, utf8_percent_encode};
use serde::{Deserialize, Serialize, de::IgnoredAny};
use url::Url;

use crate::{Catalog, Error, MediaItem, MediaKind, web_address};

const ENCODE_IN_PATH: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

pub(crate) struct Server {
    pub(crate) kind: MediaKind,
    api: Url,
    username: String,
    password: String,
    media_path: String,
}

#[derive(Serialize)]
pub struct Endpoints {
    pub section: MediaKind,
    pub streams: Url,
    pub categories: Url,
}

impl Server {
    pub(crate) fn new(server: &str, username: &str, password: &str) -> Result<Self, Error> {
        let mut base = web_address(server)?;
        if !base.username().is_empty()
            || base.password().is_some()
            || [username, password]
                .iter()
                .any(|part| matches!(*part, "" | "." | ".."))
        {
            return Err(Error::InvalidAddress);
        }
        base.set_fragment(None);
        let extras: Vec<_> = base
            .query_pairs()
            .filter(|(key, _)| !matches!(key.as_ref(), "username" | "password" | "action"))
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        base.set_query(None);
        if !extras.is_empty() {
            base.query_pairs_mut().extend_pairs(extras);
        }
        if !base
            .path_segments()
            .and_then(|mut parts| parts.next_back())
            .is_some_and(|last| last.eq_ignore_ascii_case("player_api.php"))
        {
            base.path_segments_mut()
                .map_err(|_| Error::InvalidAddress)?
                .pop_if_empty()
                .push("player_api.php");
        }
        let media_path = format!(
            "{}/{}",
            utf8_percent_encode(username, ENCODE_IN_PATH),
            utf8_percent_encode(password, ENCODE_IN_PATH)
        );
        Ok(Self {
            kind: MediaKind::Live,
            api: base,
            username: username.to_owned(),
            password: password.to_owned(),
            media_path,
        })
    }

    pub(crate) fn from_login(address: &str) -> Result<Self, Error> {
        let url = web_address(address)?;
        let mut username = None;
        let mut password = None;
        let mut section = MediaKind::Live;
        for (k, v) in url.query_pairs() {
            match k.as_ref() {
                "username" => username = Some(v),
                "password" => password = Some(v),
                "action" => {
                    section = match v.as_ref() {
                        "get_vod_streams" => MediaKind::Movies,
                        "get_series" => MediaKind::Series,
                        _ => MediaKind::Live,
                    }
                }
                _ => {}
            }
        }
        let mut server = Self::new(
            address,
            &username.ok_or(Error::InvalidResponse)?,
            &password.ok_or(Error::InvalidResponse)?,
        )?;
        server.kind = section;
        Ok(server)
    }

    pub(crate) fn source_url(&self, kind: MediaKind) -> Url {
        if kind == MediaKind::Live {
            self.login()
        } else {
            self.endpoints(kind).streams
        }
    }

    pub(crate) fn endpoints(&self, kind: MediaKind) -> Endpoints {
        let (streams, categories) = match kind {
            MediaKind::Live => ("get_live_streams", "get_live_categories"),
            MediaKind::Movies => ("get_vod_streams", "get_vod_categories"),
            MediaKind::Series => ("get_series", "get_series_categories"),
        };
        Endpoints {
            section: kind,
            streams: self.endpoint(streams),
            categories: self.endpoint(categories),
        }
    }

    fn prefix(&self) -> &str {
        self.api
            .path()
            .rsplit_once('/')
            .map_or("", |(prefix, _)| prefix)
    }

    pub(crate) fn login(&self) -> Url {
        let mut url = self.api.clone();
        url.query_pairs_mut()
            .append_pair("username", &self.username)
            .append_pair("password", &self.password);
        url
    }

    fn endpoint(&self, action: &str) -> Url {
        let mut url = self.login();
        url.query_pairs_mut().append_pair("action", action);
        url
    }

    fn stream(&self, route: &str, id: impl std::fmt::Display, ext: &str) -> Url {
        let mut url = self.api.clone();
        url.set_query(None);
        url.set_path(&format!(
            "{}/{route}/{}/{id}.{ext}",
            self.prefix(),
            self.media_path
        ));
        url
    }

    pub(crate) fn catalog(
        &self,
        kind: MediaKind,
        streams: &[u8],
        categories: &[u8],
    ) -> Result<Catalog, Error> {
        let mut items = Vec::new();
        self.visit_catalog(
            kind,
            serde_json::Deserializer::from_slice(streams),
            serde_json::Deserializer::from_slice(categories),
            |item| {
                items.push(item);
                Ok(())
            },
        )?;
        Ok(Catalog {
            name: self.api.host_str().unwrap_or("Xtream").to_owned(),
            items,
        })
    }

    pub(crate) fn visit_catalog<'de>(
        &self,
        kind: MediaKind,
        streams: serde_json::Deserializer<impl serde_json::de::Read<'de>>,
        categories: serde_json::Deserializer<impl serde_json::de::Read<'de>>,
        mut emit: impl FnMut(MediaItem) -> Result<(), Error>,
    ) -> Result<(), Error> {
        let mut hierarchy = HashMap::new();
        visit_rows(categories, |entry: Category| {
            hierarchy.insert(
                entry.category_id.key(),
                (
                    crate::group_path(&entry.category_name),
                    entry.parent_id.map(Id::key).filter(|id| id != "0"),
                ),
            );
            Ok(())
        })?;
        let mut groups = HashMap::with_capacity(hierarchy.len());
        for (id, (label, parent)) in &hierarchy {
            let mut names = vec![label.as_str()];
            let mut visited = HashSet::from([id]);
            let mut next = parent.as_ref();
            while let Some(key) = next {
                let Some((name, ancestor)) = hierarchy.get(key) else {
                    break;
                };
                if !visited.insert(key) || names.len() >= 32 {
                    names.truncate(1);
                    break;
                }
                if !name.is_empty() {
                    names.push(name);
                }
                next = ancestor.as_ref();
            }
            names.reverse();
            groups.insert(id, names.join(" › "));
        }
        let mut seen = HashSet::new();
        let count = visit_rows(streams, |program: Program| {
            let id = match kind {
                MediaKind::Live | MediaKind::Movies => program.stream_id,
                MediaKind::Series => program.series_id,
            };
            let Some(id) = id
                .map(Id::key)
                .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
            else {
                return Ok(());
            };
            if !seen.insert(id.clone()) {
                return Ok(());
            }
            let url = match kind {
                MediaKind::Live => self.stream("live", &id, "m3u8"),
                MediaKind::Movies => self.stream(
                    "movie",
                    &id,
                    extension(program.container_extension.as_deref()),
                ),
                MediaKind::Series => {
                    let mut endpoint = self.endpoint("get_series_info");
                    endpoint.query_pairs_mut().append_pair("series_id", &id);
                    endpoint
                }
            };
            let group = program
                .category_id
                .and_then(|id| groups.get(&id.key()))
                .cloned()
                .unwrap_or_default();
            let name = program.name.as_deref().unwrap_or("").trim();
            emit(MediaItem {
                name: if name.is_empty() {
                    format!("Chaîne {id}")
                } else {
                    name.to_owned()
                },
                group,
                kind,
                url,
                opens_episodes: kind == MediaKind::Series,
                poster_url: crate::poster_url(&self.api, program.cover.as_deref())
                    .or_else(|| crate::poster_url(&self.api, program.cover_big.as_deref()))
                    .or_else(|| crate::poster_url(&self.api, program.stream_icon.as_deref())),
            })
        })?;
        if seen.is_empty() {
            return Err(if count == 0 {
                Error::EmptyPlaylist
            } else {
                Error::InvalidResponse
            });
        }
        Ok(())
    }
}

// Deserialize and discard each provider row before moving to the next one.
fn visit_rows<'de, T: Deserialize<'de>, F: FnMut(T) -> Result<(), Error>>(
    mut input: serde_json::Deserializer<impl serde_json::de::Read<'de>>,
    emit: F,
) -> Result<u64, Error> {
    struct Rows<T, F>(F, std::marker::PhantomData<T>);
    impl<'de, T: Deserialize<'de>, F: FnMut(T) -> Result<(), Error>> serde::de::Visitor<'de>
        for Rows<T, F>
    {
        type Value = u64;
        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            formatter.write_str("an array of catalog rows")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(mut self, mut rows: A) -> Result<u64, A::Error> {
            let mut count = 0;
            while let Some(row) = rows.next_element::<Row<T>>()? {
                count += 1;
                if let Row::Valid(value) = row {
                    (self.0)(value)
                        .map_err(|_| serde::de::Error::custom("catalog write failed"))?;
                }
            }
            Ok(count)
        }
    }
    use serde::Deserializer;
    let count = input
        .deserialize_seq(Rows(emit, std::marker::PhantomData))
        .map_err(|_| Error::InvalidResponse)?;
    input.end().map_err(|_| Error::InvalidResponse)?;
    Ok(count)
}

pub fn episodes(endpoint: &str, data: &[u8]) -> Result<Vec<Episode>, Error> {
    episodes_from_reader(endpoint, data)
}

pub(crate) fn episodes_from_reader(
    endpoint: &str,
    input: impl Read,
) -> Result<Vec<Episode>, Error> {
    let server = Server::from_login(endpoint)?;
    let info: SeriesInfo = serde_json::from_reader(input).map_err(|_| Error::InvalidResponse)?;
    let mut episodes = Vec::new();
    let mut seen = HashSet::new();
    let mut add_episode = |season_fallback: u64, raw: EpisodeResponse| {
        let season = raw
            .season
            .and_then(|season| season.number())
            .unwrap_or(season_fallback);
        let Some(id) = raw.id.number().filter(|id| *id > 0) else {
            return;
        };
        if !seen.insert(id) {
            return;
        }
        let number = raw.episode_num.and_then(|number| number.number());
        let name = raw
            .title
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| {
                number.map_or_else(
                    || "Épisode".to_owned(),
                    |number| format!("Épisode {number}"),
                )
            });
        episodes.push(Episode {
            name,
            season,
            number,
            url: server.stream("series", id, extension(raw.container_extension.as_deref())),
        });
    };
    match info.episodes {
        Episodes::BySeason(seasons) => {
            for (season, listing) in seasons {
                listing.visit(season.parse().unwrap_or(0), &mut add_episode);
            }
        }
        Episodes::Array(entries) => {
            for (index, entry) in entries.into_iter().enumerate() {
                match entry {
                    EpisodeEntry::Episode(episode) => add_episode(0, episode),
                    EpisodeEntry::Season(listing) => listing.visit(index as u64, &mut add_episode),
                }
            }
        }
    }
    episodes.sort_by(|a, b| {
        (
            a.season == 0,
            a.season,
            a.number.unwrap_or(u64::MAX),
            a.name.as_str(),
            a.url.as_str(),
        )
            .cmp(&(
                b.season == 0,
                b.season,
                b.number.unwrap_or(u64::MAX),
                b.name.as_str(),
                b.url.as_str(),
            ))
    });
    Ok(episodes)
}

fn extension(value: Option<&str>) -> &str {
    value
        .map(|ext| ext.trim().trim_start_matches('.'))
        .filter(|ext| {
            !ext.is_empty()
                && ext.len() <= 8
                && ext.bytes().all(|byte| byte.is_ascii_alphanumeric())
        })
        .unwrap_or("mp4")
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Id {
    Number(u64),
    Text(String),
}

impl Id {
    fn key(self) -> String {
        match self {
            Self::Number(value) => value.to_string(),
            Self::Text(value) => value,
        }
    }

    fn number(&self) -> Option<u64> {
        match self {
            Self::Number(value) => Some(*value),
            Self::Text(value) => value.parse().ok(),
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Row<T> {
    Valid(T),
    Invalid(IgnoredAny),
}

// A provider can omit a field, or return a value with the wrong type.
// Preserve the rest of a usable row in either case.
fn optional_field<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(match Row::deserialize(deserializer)? {
        Row::Valid(value) => Some(value),
        Row::Invalid(_) => None,
    })
}

#[derive(Deserialize)]
struct Program {
    #[serde(default, deserialize_with = "optional_field")]
    cover: Option<String>,
    #[serde(default, deserialize_with = "optional_field")]
    cover_big: Option<String>,
    #[serde(default, deserialize_with = "optional_field")]
    stream_icon: Option<String>,
    #[serde(default, deserialize_with = "optional_field")]
    stream_id: Option<Id>,
    #[serde(default, deserialize_with = "optional_field")]
    series_id: Option<Id>,
    #[serde(default, deserialize_with = "optional_field")]
    name: Option<String>,
    #[serde(default, deserialize_with = "optional_field")]
    category_id: Option<Id>,
    #[serde(default, deserialize_with = "optional_field")]
    container_extension: Option<String>,
}

#[derive(Deserialize)]
struct Category {
    #[serde(default, deserialize_with = "optional_field")]
    parent_id: Option<Id>,
    category_id: Id,
    category_name: String,
}

#[derive(Deserialize)]
struct SeriesInfo {
    episodes: Episodes,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Episodes {
    BySeason(HashMap<String, SeasonEpisodes>),
    Array(Vec<EpisodeEntry>),
}

#[derive(Deserialize)]
#[serde(untagged)]
enum EpisodeEntry {
    Episode(EpisodeResponse),
    Season(SeasonEpisodes),
}

#[derive(Deserialize)]
#[serde(untagged)]
enum SeasonEpisodes {
    List(Vec<EpisodeResponse>),
    Keyed(HashMap<String, EpisodeResponse>),
}

impl SeasonEpisodes {
    fn visit(self, season: u64, visit: &mut impl FnMut(u64, EpisodeResponse)) {
        match self {
            Self::List(entries) => {
                for episode in entries {
                    visit(season, episode);
                }
            }
            Self::Keyed(entries) => {
                for episode in entries.into_values() {
                    visit(season, episode);
                }
            }
        }
    }
}

#[derive(Deserialize)]
struct EpisodeResponse {
    id: Id,
    season: Option<Id>,
    episode_num: Option<Id>,
    title: Option<String>,
    container_extension: Option<String>,
}

#[derive(Serialize)]
pub struct Episode {
    pub name: String,
    pub season: u64,
    pub number: Option<u64>,
    pub url: Url,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_encodes_credentials_for_query_and_playback_path() {
        let server = Server::new("https://example.test/panel/", "user+name", "p/a&ss").unwrap();
        assert_eq!(
            server.endpoints(MediaKind::Live).streams.as_str(),
            "https://example.test/panel/player_api.php?username=user%2Bname&password=p%2Fa%26ss&action=get_live_streams"
        );
        let catalog = server
            .catalog(
                MediaKind::Live,
                br#"[{"stream_id":5,"name":"Test","category_id":"8"}]"#,
                br#"[{"category_id":8,"category_name":"Direct"}]"#,
            )
            .unwrap();
        assert_eq!(catalog.items[0].group, "Direct");
        assert_eq!(
            catalog.items[0].url.as_str(),
            "https://example.test/panel/live/user%2Bname/p%2Fa%26ss/5.m3u8"
        );
    }
    #[test]
    fn poster_urls_follow_provider_metadata_and_ignore_unusable_schemes() {
        let server = Server::new("https://example.test/panel/", "u", "p").unwrap();
        let catalog = server.catalog(MediaKind::Movies,
            br#"[{"stream_id":1,"cover":"file:///tmp/private","stream_icon":"art/poster.jpg"},{"stream_id":2,"cover":false},{"stream_id":3,"cover_big":"https://cdn.test/large.jpg"}]"#, b"[]").unwrap();
        assert_eq!(
            catalog.items[0].poster_url.as_ref().unwrap().as_str(),
            "https://example.test/panel/art/poster.jpg"
        );
        assert!(catalog.items[1].poster_url.is_none());
        assert_eq!(
            catalog.items[2].poster_url.as_ref().unwrap().host_str(),
            Some("cdn.test")
        );
    }

    #[test]
    fn streamed_catalog_rejects_a_truncated_or_trailing_response() {
        let server = Server::new("https://example.test", "u", "p").unwrap();
        for rows in [
            br#"[{"stream_id":1},"#.as_slice(),
            br#"[{"stream_id":1}] {}"#,
        ] {
            assert!(matches!(
                server.catalog(MediaKind::Live, rows, b"[]"),
                Err(Error::InvalidResponse)
            ));
        }
    }

    #[test]
    fn reads_flat_and_indexed_episode_lists() {
        let endpoint = "https://example.test/panel/player_api.php?username=user&password=pass";
        let response = br#"{"episodes":[[{"id":4}],{"0":{"id":5}},{"id":6,"season":"2"}]}"#;
        let entries = episodes(endpoint, response).unwrap();
        assert_eq!(
            entries.iter().map(|entry| entry.season).collect::<Vec<_>>(),
            [1, 2, 0]
        );
    }
}

#[cfg(test)]
mod source_tests {
    use super::*;

    #[test]
    fn saved_sections_round_trip_without_changing_playback_paths() {
        let base = Server::new(
            "https://example.test/panel/player_api.php?tenant=fixture",
            "user +",
            "démo",
        )
        .unwrap();
        for kind in [MediaKind::Live, MediaKind::Movies, MediaKind::Series] {
            let saved = base.source_url(kind);
            let restored = Server::from_login(saved.as_str()).unwrap();
            assert_eq!(restored.kind, kind);
            let plan = restored.endpoints(kind);
            assert_eq!(plan.streams.path(), "/panel/player_api.php");
            assert!(
                plan.categories
                    .query_pairs()
                    .any(|(k, v)| k == "tenant" && v == "fixture")
            );
            let response = br#"[null,{"stream_id":"007","series_id":12,"name":"Titre","container_extension":"mkv","category_id":1}]"#;
            let items = restored
                .catalog(
                    kind,
                    response,
                    br#"[{"category_id":"1","category_name":"Test"}]"#,
                )
                .unwrap()
                .items;
            assert_eq!(items.len(), 1);
            assert_eq!(items[0].group, "Test");
            assert_eq!(items[0].opens_episodes, kind == MediaKind::Series);
            if kind == MediaKind::Series {
                let result = episodes(items[0].url.as_str(),br#"{"episodes":{"2":[{"id":"8","episode_num":2},{"id":"7","episode_num":1}]}}"#).unwrap();
                assert_eq!(
                    result.iter().map(|e| e.number).collect::<Vec<_>>(),
                    [Some(1), Some(2)]
                );
                assert!(result[0].url.path().ends_with("/7.mp4"));
            } else {
                assert!(items[0].url.query().is_none());
                assert!(items[0].url.path().ends_with(if kind == MediaKind::Movies {
                    "/007.mkv"
                } else {
                    "/007.m3u8"
                }));
            }
        }
    }
}
