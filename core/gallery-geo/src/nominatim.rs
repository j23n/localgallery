//! Nominatim reverse geocode. English names, injectable endpoint.

use std::io::Read;
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

/// Reverse JSON is a few kilobytes. Anything larger is not a place name.
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;

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
        .map_err(classify_ureq)?;
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
    check_content_length(response.header("Content-Length"))?;
    let bytes = read_capped_body(response.into_reader())?;
    let body: NominatimResponse = serde_json::from_slice(&bytes)
        .map_err(|_| GeoError::Fatal("Nominatim response was not JSON".into()))?;
    Ok(request_from_nominatim(body.address.unwrap_or_default()))
}

/// Reject a declared length above [`MAX_RESPONSE_BYTES`]. Missing length is
/// allowed — [`read_capped_body`] still bounds the stream.
fn check_content_length(header: Option<&str>) -> Result<(), GeoError> {
    let Some(raw) = header else {
        return Ok(());
    };
    let len = raw
        .trim()
        .parse::<u64>()
        .map_err(|_| GeoError::Fatal("Nominatim Content-Length was not a number".into()))?;
    if len > MAX_RESPONSE_BYTES as u64 {
        return Err(GeoError::Fatal(format!(
            "Nominatim Content-Length {len} exceeds {MAX_RESPONSE_BYTES}"
        )));
    }
    Ok(())
}

fn read_capped_body(mut reader: impl Read) -> Result<Vec<u8>, GeoError> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = reader
            .read(&mut tmp)
            .map_err(|_| GeoError::Retryable("Nominatim body read failed".into()))?;
        if n == 0 {
            break;
        }
        if buf.len().saturating_add(n) > MAX_RESPONSE_BYTES {
            return Err(GeoError::Fatal(format!(
                "Nominatim body exceeds {MAX_RESPONSE_BYTES} bytes"
            )));
        }
        buf.extend_from_slice(&tmp[..n]);
    }
    Ok(buf)
}

/// Status / transport class only. ureq's `Display` embeds the request URL,
/// which carries the lookup coordinates.
fn classify_ureq(err: ureq::Error) -> GeoError {
    match err {
        ureq::Error::Status(429, _) => GeoError::Retryable("Nominatim HTTP 429".into()),
        ureq::Error::Status(s, _) if s >= 500 => GeoError::Retryable(format!("Nominatim HTTP {s}")),
        ureq::Error::Status(s, _) => GeoError::Fatal(format!("Nominatim HTTP {s}")),
        ureq::Error::Transport(_) => GeoError::Retryable("Nominatim transport error".into()),
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

    #[test]
    fn oversized_content_length_is_rejected() {
        let err = check_content_length(Some("1000000")).unwrap_err();
        assert!(
            matches!(err, GeoError::Fatal(ref d) if d.contains("Content-Length")),
            "{err}"
        );
    }

    #[test]
    fn missing_content_length_is_allowed() {
        assert!(check_content_length(None).is_ok());
    }

    #[test]
    fn normal_content_length_is_allowed() {
        assert!(check_content_length(Some("512")).is_ok());
        assert!(check_content_length(Some(&MAX_RESPONSE_BYTES.to_string())).is_ok());
    }

    #[test]
    fn invalid_content_length_is_rejected() {
        let err = check_content_length(Some("lots")).unwrap_err();
        assert!(matches!(err, GeoError::Fatal(_)), "{err}");
    }

    #[test]
    fn streamed_body_is_capped() {
        let big = vec![b'x'; MAX_RESPONSE_BYTES + 1];
        let err = read_capped_body(std::io::Cursor::new(big)).unwrap_err();
        assert!(
            matches!(err, GeoError::Fatal(ref d) if d.contains("body exceeds")),
            "{err}"
        );
    }

    #[test]
    fn streamed_body_under_cap_is_kept() {
        let bytes = br#"{"address":{}}"#;
        let got = read_capped_body(std::io::Cursor::new(&bytes[..])).unwrap();
        assert_eq!(got, bytes);
    }

    #[test]
    fn classify_ureq_omits_url_text() {
        let err = classify_ureq(ureq::Error::Status(
            429,
            ureq::Response::new(429, "Too Many", "").unwrap(),
        ));
        match err {
            GeoError::Retryable(d) => {
                assert_eq!(d, "Nominatim HTTP 429");
                assert!(!d.contains("http"));
                assert!(!d.contains("lat"));
            }
            other => panic!("{other}"),
        }
    }

    struct HttpReply {
        status: u16,
        extra_headers: Vec<(String, String)>,
        body: Vec<u8>,
        include_content_length: bool,
    }

    fn serve(reply: HttpReply) -> String {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut req = [0u8; 4096];
            let _ = stream.read(&mut req);
            let reason = match reply.status {
                200 => "OK",
                404 => "Not Found",
                _ => "Error",
            };
            let mut head = format!(
                "HTTP/1.1 {} {}\r\nConnection: close\r\n",
                reply.status, reason
            );
            if reply.include_content_length
                && !reply
                    .extra_headers
                    .iter()
                    .any(|(k, _)| k.eq_ignore_ascii_case("Content-Length"))
            {
                head.push_str(&format!("Content-Length: {}\r\n", reply.body.len()));
            }
            for (k, v) in reply.extra_headers {
                head.push_str(&format!("{k}: {v}\r\n"));
            }
            head.push_str("\r\n");
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&reply.body);
        });
        format!("http://{addr}/reverse")
    }

    fn paris_body() -> Vec<u8> {
        include_bytes!("../tests/fixtures/nominatim-paris.json").to_vec()
    }

    #[test]
    fn lookup_accepts_a_normal_response() {
        let url = serve(HttpReply {
            status: 200,
            extra_headers: vec![("Content-Type".into(), "application/json".into())],
            body: paris_body(),
            include_content_length: true,
        });
        let req = Nominatim::new(url).lookup(48.86, 2.35).unwrap().unwrap();
        assert_eq!(req.path, "Places/France/Île-de-France/Paris/Louvre");
    }

    #[test]
    fn lookup_rejects_oversized_content_length() {
        let url = serve(HttpReply {
            status: 200,
            extra_headers: vec![("Content-Length".into(), "1000000".into())],
            body: paris_body(),
            include_content_length: false,
        });
        let err = Nominatim::new(url).lookup(48.86, 2.35).unwrap_err();
        assert!(
            matches!(err, GeoError::Fatal(ref d) if d.contains("Content-Length")),
            "{err}"
        );
    }

    #[test]
    fn lookup_accepts_missing_content_length() {
        let url = serve(HttpReply {
            status: 200,
            extra_headers: vec![("Content-Type".into(), "application/json".into())],
            body: paris_body(),
            include_content_length: false,
        });
        let req = Nominatim::new(url).lookup(48.86, 2.35).unwrap().unwrap();
        assert_eq!(req.city.as_deref(), Some("Paris"));
    }

    #[test]
    fn lookup_rejects_missing_length_when_body_exceeds_cap() {
        let url = serve(HttpReply {
            status: 200,
            extra_headers: vec![],
            body: vec![b'x'; MAX_RESPONSE_BYTES + 8],
            include_content_length: false,
        });
        let err = Nominatim::new(url).lookup(48.86, 2.35).unwrap_err();
        assert!(
            matches!(err, GeoError::Fatal(ref d) if d.contains("body exceeds")),
            "{err}"
        );
    }
}
