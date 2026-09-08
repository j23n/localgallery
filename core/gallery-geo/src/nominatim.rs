//! Nominatim reverse geocode. English names, injectable endpoint.

use std::time::Duration;

use gallery_meta::places::{place_from_parts, PlaceWriteRequest};
use serde::Deserialize;

use crate::{GeoError, ReverseGeocoder};

/// Public OSM instance — hosts should override for real libraries.
pub const DEFAULT_ENDPOINT: &str = "https://nominatim.openstreetmap.org/reverse";

/// Identifiable UA; Nominatim requires one.
pub const DEFAULT_USER_AGENT: &str = "LocalGallery/0.1 (https://github.com/j23n/localgallery)";

/// Nominatim's polite floor.
pub const MIN_LOOKUP_INTERVAL: Duration = Duration::from_secs(1);

/// HTTP client for one endpoint.
#[derive(Debug, Clone)]
pub struct Nominatim {
    endpoint: String,
    user_agent: String,
    timeout: Duration,
}

impl Nominatim {
    /// `endpoint` is the reverse URL (query string is appended).
    pub fn new(endpoint: impl Into<String>) -> Self {
        Nominatim {
            endpoint: endpoint.into(),
            user_agent: DEFAULT_USER_AGENT.into(),
            timeout: Duration::from_secs(15),
        }
    }
}

impl Default for Nominatim {
    fn default() -> Self {
        Self::new(DEFAULT_ENDPOINT)
    }
}

impl ReverseGeocoder for Nominatim {
    fn lookup(&self, lat: f64, lon: f64) -> Result<Option<PlaceWriteRequest>, GeoError> {
        nominatim_lookup(&self.endpoint, &self.user_agent, self.timeout, lat, lon)
    }
}

/// Address object from a Nominatim `jsonv2` reverse response.
#[derive(Debug, Deserialize, Default, Clone)]
pub struct NominatimAddress {
    /// Country name.
    pub country: Option<String>,
    /// Region / state.
    pub state: Option<String>,
    /// City.
    pub city: Option<String>,
    /// Town (used when `city` is empty).
    pub town: Option<String>,
    /// Village.
    pub village: Option<String>,
    /// Municipality.
    pub municipality: Option<String>,
    /// Suburb.
    pub suburb: Option<String>,
    /// Neighbourhood.
    pub neighbourhood: Option<String>,
    /// City district.
    pub city_district: Option<String>,
    /// ISO 3166-1 alpha-2.
    pub country_code: Option<String>,
}

/// Collapse Nominatim fields the same way Linux did: city fallbacks, then
/// [`place_from_parts`].
pub fn request_from_nominatim(addr: NominatimAddress) -> Option<PlaceWriteRequest> {
    let city = first_nonempty(&[
        addr.city.as_deref(),
        addr.town.as_deref(),
        addr.village.as_deref(),
        addr.municipality.as_deref(),
    ]);
    let sublocation = first_nonempty(&[
        addr.suburb.as_deref(),
        addr.neighbourhood.as_deref(),
        addr.city_district.as_deref(),
    ]);
    place_from_parts(
        addr.country.as_deref(),
        addr.state.as_deref(),
        city,
        sublocation,
        addr.country_code.as_deref(),
    )
}

fn first_nonempty<'a>(parts: &[Option<&'a str>]) -> Option<&'a str> {
    parts
        .iter()
        .copied()
        .flatten()
        .find(|s| !s.trim().is_empty())
}

#[derive(Debug, Deserialize)]
struct NominatimResponse {
    #[serde(default)]
    address: Option<NominatimAddress>,
}

fn nominatim_lookup(
    endpoint: &str,
    user_agent: &str,
    timeout: Duration,
    lat: f64,
    lon: f64,
) -> Result<Option<PlaceWriteRequest>, GeoError> {
    let agent = ureq::AgentBuilder::new()
        .user_agent(user_agent)
        .timeout(timeout)
        .build();
    let response = agent
        .get(endpoint)
        .set("Accept-Language", "en")
        .query("format", "jsonv2")
        .query("lat", &format!("{lat}"))
        .query("lon", &format!("{lon}"))
        .call()
        .map_err(|e| classify_ureq(e))?;
    let status = response.status();
    if status == 404 {
        return Ok(None);
    }
    if status == 429 || status >= 500 {
        return Err(GeoError::Retryable(format!("Nominatim HTTP {status}")));
    }
    if status >= 400 {
        return Err(GeoError::Fatal(format!("Nominatim HTTP {status}")));
    }
    let body: NominatimResponse = response
        .into_json()
        .map_err(|e| GeoError::Fatal(e.to_string()))?;
    Ok(request_from_nominatim(body.address.unwrap_or_default()))
}

fn classify_ureq(err: ureq::Error) -> GeoError {
    match &err {
        ureq::Error::Status(429, _) => GeoError::Retryable(err.to_string()),
        ureq::Error::Status(s, _) if *s >= 500 => GeoError::Retryable(err.to_string()),
        ureq::Error::Transport(_) => GeoError::Retryable(err.to_string()),
        _ => GeoError::Fatal(err.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_paris_collapses_to_places_path() {
        let bytes = include_str!("../tests/fixtures/nominatim-paris.json");
        let body: NominatimResponse = serde_json::from_str(bytes).unwrap();
        let req = request_from_nominatim(body.address.unwrap()).unwrap();
        assert_eq!(req.path, "Places/France/Île-de-France/Paris/Louvre");
        assert_eq!(req.country_code.as_deref(), Some("FR"));
        assert_eq!(req.city.as_deref(), Some("Paris"));
    }

    #[test]
    fn missing_city_uses_town() {
        let req = request_from_nominatim(NominatimAddress {
            country: Some("United Kingdom".into()),
            town: Some("Bath".into()),
            country_code: Some("gb".into()),
            ..NominatimAddress::default()
        })
        .unwrap();
        assert_eq!(req.path, "Places/United Kingdom/Bath");
    }
}
