mod bindings;
mod playlist;
mod xtream;

use serde::Serialize;
use url::Url;

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Error {
    InvalidAddress,
    InvalidPlaylist,
    LocalHls,
    EmptyPlaylist,
    InvalidResponse,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Live,
    Movies,
    Series,
}

impl MediaKind {
    fn parse(value: &str) -> Result<Self, Error> {
        match value {
            "live" => Ok(Self::Live),
            "movies" => Ok(Self::Movies),
            "series" => Ok(Self::Series),
            _ => Err(Error::InvalidResponse),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaItem {
    pub name: String,
    pub group: String,
    pub kind: MediaKind,
    pub url: Url,
    pub opens_episodes: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster_url: Option<Url>,
}

#[derive(Serialize)]
pub struct Catalog {
    pub name: String,
    pub items: Vec<MediaItem>,
}

fn is_web_address(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https") && url.has_host()
}

// Providers also encode hierarchy in display names when parent IDs are absent.
fn group_path(label: &str) -> String {
    label
        .replace(" | ", " › ")
        .replace(" / ", " › ")
        .replace(" > ", " › ")
        .split('›')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" › ")
}

fn poster_url(origin: &Url, value: Option<&str>) -> Option<Url> {
    let value = value?.trim();
    if value.is_empty() {
        return None;
    }
    origin.join(value).ok().filter(is_web_address)
}

fn web_address(value: &str) -> Result<Url, Error> {
    Url::parse(value.trim())
        .ok()
        .filter(is_web_address)
        .ok_or(Error::InvalidAddress)
}

// Both platform bindings depend on this API. Network I/O belongs to the caller.
pub use playlist::parse as parse_playlist;
pub use xtream::{Endpoints, Episode, episodes as xtream_episodes};

pub fn xtream_login(
    server: &str,
    username: &str,
    password: &str,
    section: &str,
) -> Result<Url, Error> {
    Ok(xtream::Server::new(server, username, password)?.source_url(MediaKind::parse(section)?))
}

pub fn xtream_endpoints(login: &str) -> Result<Endpoints, Error> {
    let server = xtream::Server::from_login(login)?;
    Ok(server.endpoints(server.kind))
}

pub fn xtream_catalog(login: &str, streams: &[u8], categories: &[u8]) -> Result<Catalog, Error> {
    let server = xtream::Server::from_login(login)?;
    server.catalog(server.kind, streams, categories)
}
