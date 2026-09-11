//! tls.rs — opt-in TLS transport on top of the existing raw-fd event loop.
//!
//! Decision-64 deliberately keeps the Mojo HTTP/WS/H2 state machines unaware of
//! TLS. A per-process fd → rustls session table adapts ciphertext at the two
//! lowest transport operations (`recv` and `send_all`). HTTP/1, WebSocket,
//! streaming responses and HTTP/2 therefore keep their byte-level behavior.
//!
//! Configuration:
//!   FASTAPI_MOJO_TLS_CERT=/path/to/cert.pem
//!   FASTAPI_MOJO_TLS_KEY=/path/to/key.pem
//!   FASTAPI_MOJO_TLS_ALPN=h2,http/1.1   (default)
//!
//! The crypto backend is rustls with `rustls-rustcrypto`, not ring/aws-lc, to
//! preserve the Mojo + Rust-only North Star. The provider is explicitly an
//! alpha-quality upstream project; TLS is therefore opt-in and this limitation
//! is documented in ADR-0039.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::os::raw::{c_int, c_void};
use std::sync::{Arc, Mutex, OnceLock};

use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::server::ServerConfig;
use rustls::ServerConnection;

const MSG_DONTWAIT: c_int = 0x40;
const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;

extern "C" {
    #[link_name = "recv"]
    fn c_recv(fd: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    #[link_name = "send"]
    fn c_send(fd: c_int, buf: *const c_void, len: usize, flags: c_int) -> isize;
    fn __errno_location() -> *mut c_int;
}

fn errno() -> c_int {
    unsafe { *__errno_location() }
}

enum Bootstrap {
    Disabled,
    Enabled(Arc<ServerConfig>),
    Failed,
}

static CONFIG: OnceLock<Bootstrap> = OnceLock::new();
static SESSIONS: OnceLock<Mutex<HashMap<i32, ServerConnection>>> = OnceLock::new();

fn sessions() -> &'static Mutex<HashMap<i32, ServerConnection>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn bootstrap() -> &'static Bootstrap {
    CONFIG.get_or_init(|| match load_config_from_env() {
        Ok(Some(config)) => Bootstrap::Enabled(Arc::new(config)),
        Ok(None) => Bootstrap::Disabled,
        Err(error) => {
            eprintln!("ERROR: fastapi_mojo TLS configuration failed: {error}");
            Bootstrap::Failed
        }
    })
}

/// Initialize once during `create_bound_socket`. Returns false only when TLS
/// was requested but certificate/key loading or provider setup failed.
pub fn init_from_env() -> bool {
    !matches!(bootstrap(), Bootstrap::Failed)
}

pub fn enabled() -> bool {
    matches!(bootstrap(), Bootstrap::Enabled(_))
}

fn config() -> Option<Arc<ServerConfig>> {
    match bootstrap() {
        Bootstrap::Enabled(config) => Some(config.clone()),
        _ => None,
    }
}

fn load_config_from_env() -> Result<Option<ServerConfig>, String> {
    let cert_path = std::env::var("FASTAPI_MOJO_TLS_CERT").unwrap_or_default();
    let key_path = std::env::var("FASTAPI_MOJO_TLS_KEY").unwrap_or_default();
    if cert_path.is_empty() && key_path.is_empty() {
        return Ok(None);
    }
    if cert_path.is_empty() || key_path.is_empty() {
        return Err("FASTAPI_MOJO_TLS_CERT and FASTAPI_MOJO_TLS_KEY must be set together".into());
    }

    let certificates: Vec<CertificateDer<'static>> =
        CertificateDer::pem_file_iter(&cert_path)
            .map_err(|e| format!("read certificate {cert_path:?}: {e}"))?
            .collect::<Result<_, _>>()
            .map_err(|e| format!("parse certificate {cert_path:?}: {e}"))?;
    if certificates.is_empty() {
        return Err(format!("certificate file contains no certificates: {cert_path:?}"));
    }
    let key: PrivateKeyDer<'static> = PrivateKeyDer::from_pem_file(&key_path)
        .map_err(|e| format!("read private key {key_path:?}: {e}"))?;

    let provider = rustls_rustcrypto::provider();
    let mut config = ServerConfig::builder_with_provider(Arc::new(provider))
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("select provider protocol versions: {e}"))?
        .with_no_client_auth()
        .with_single_cert(certificates, key)
        .map_err(|e| format!("load certificate/key into rustls: {e}"))?;
    config.alpn_protocols = alpn_from_env()?;
    Ok(Some(config))
}

pub(crate) fn alpn_protocols(raw: &str) -> Result<Vec<Vec<u8>>, String> {
    if raw.is_empty() {
        return Ok(vec![b"h2".to_vec(), b"http/1.1".to_vec()]);
    }
    let mut protocols = Vec::new();
    for item in raw.split(',') {
        let item = item.trim();
        if item.is_empty()
            || item.len() > 255
            || !item
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/'))
            || protocols.iter().any(|existing: &Vec<u8>| existing == item.as_bytes())
        {
            return Err(format!(
                "invalid or duplicate ALPN entry in FASTAPI_MOJO_TLS_ALPN: {item:?}"
            ));
        }
        protocols.push(item.as_bytes().to_vec());
    }
    Ok(protocols)
}

fn alpn_from_env() -> Result<Vec<Vec<u8>>, String> {
    alpn_protocols(&std::env::var("FASTAPI_MOJO_TLS_ALPN").unwrap_or_default())
}

struct SocketReader {
    fd: c_int,
    saw_eof: bool,
    fatal_io: bool,
}

impl Read for SocketReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            let n = unsafe {
                c_recv(
                    self.fd,
                    buf.as_mut_ptr() as *mut c_void,
                    buf.len(),
                    MSG_DONTWAIT,
                )
            };
            if n > 0 {
                return Ok(n as usize);
            }
            if n == 0 {
                self.saw_eof = true;
                return Ok(0);
            }
            let code = errno();
            if code == EINTR {
                continue;
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                return Err(io::Error::from(io::ErrorKind::WouldBlock));
            }
            self.fatal_io = true;
            return Err(io::Error::other(format!("tls recv errno {code}")));
        }
    }
}

struct SocketWriter {
    fd: c_int,
    fatal_io: bool,
}

impl Write for SocketWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            let n = unsafe { c_send(self.fd, buf.as_ptr() as *const c_void, buf.len(), 0) };
            if n > 0 {
                return Ok(n as usize);
            }
            if n == 0 {
                self.fatal_io = true;
                return Err(io::Error::other("tls send returned zero"));
            }
            let code = errno();
            if code == EINTR {
                continue;
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                return Err(io::Error::from(io::ErrorKind::WouldBlock));
            }
            self.fatal_io = true;
            return Err(io::Error::other(format!("tls send errno {code}")));
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct ReadProgress {
    bytes_read: bool,
    saw_eof: bool,
}

fn read_ciphertext(fd: c_int, conn: &mut ServerConnection) -> io::Result<ReadProgress> {
    let mut reader = SocketReader {
        fd,
        saw_eof: false,
        fatal_io: false,
    };
    let mut bytes_read = false;
    loop {
        match conn.read_tls(&mut reader) {
            Ok(0) => break,
            Ok(_) => bytes_read = true,
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
            // rustls uses ErrorKind::Other for deframer backpressure. Existing
            // bytes still need process_new_packets(); only socket I/O is fatal.
            Err(err) if err.kind() == io::ErrorKind::Other && !reader.fatal_io => {
                bytes_read = true;
                break;
            }
            Err(err) => return Err(err),
        }
    }
    Ok(ReadProgress {
        bytes_read,
        saw_eof: reader.saw_eof,
    })
}

fn process_and_flush(fd: c_int, conn: &mut ServerConnection) -> io::Result<()> {
    conn.process_new_packets()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))?;
    flush_tls(fd, conn)
}

fn flush_tls(fd: c_int, conn: &mut ServerConnection) -> io::Result<()> {
    while conn.wants_write() {
        let mut writer = SocketWriter {
            fd,
            fatal_io: false,
        };
        match conn.write_tls(&mut writer) {
            Ok(0) => break,
            Ok(_) => {}
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                // The socket already has a send timeout; treat persistent
                // backpressure as a transport failure rather than stalling poll.
                return Err(err);
            }
            Err(err) => return Err(err),
        }
    }
    Ok(())
}

/// Attach a rustls server session after accept. Returns false on fatal setup.
pub fn accept(fd: c_int) -> bool {
    let Some(config) = config() else {
        return true;
    };
    match ServerConnection::new(config) {
        Ok(conn) => {
            let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
            map.insert(fd, conn);
            true
        }
        Err(error) => {
            eprintln!("ERROR: TLS accept failed on fd {fd}: {error}");
            false
        }
    }
}

pub fn has_session(fd: c_int) -> bool {
    if !enabled() {
        return false;
    }
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .contains_key(&fd)
}

/// Same return contract as io::sys_recv. `None` means this is a plain socket.
pub fn recv(fd: c_int, buf: &mut [u8]) -> Option<i32> {
    if !has_session(fd) {
        return None;
    }
    let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
    let conn = map.get_mut(&fd)?;
    loop {
        if conn.is_handshaking() {
            let progress = match read_ciphertext(fd, conn) {
                Ok(progress) => progress,
                Err(_) => return Some(-2),
            };
            if process_and_flush(fd, conn).is_err() {
                return Some(-2);
            }
            if conn.is_handshaking() {
                if progress.saw_eof {
                    return Some(0);
                }
                return Some(-1);
            }
            continue;
        }

        match conn.reader().read(buf) {
            Ok(0) => return Some(0),
            Ok(n) => return Some(n as i32),
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {}
            Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Some(0),
            Err(_) => return Some(-2),
        }

        let progress = match read_ciphertext(fd, conn) {
            Ok(progress) => progress,
            Err(_) => return Some(-2),
        };
        if process_and_flush(fd, conn).is_err() {
            return Some(-2);
        }
        if progress.saw_eof {
            // Reader has already drained any final plaintext above.
            return Some(0);
        }
        if !progress.bytes_read && conn.reader().read(buf).is_err() {
            // Nothing new arrived. The second read distinguishes WouldBlock
            // (below) from a clean close without copying an empty buffer.
            return Some(-1);
        }
    }
}

/// Encrypt and send a complete plaintext buffer. `None` means plain socket.
pub fn send_all(fd: c_int, buf: &[u8]) -> Option<c_int> {
    if !has_session(fd) {
        return None;
    }
    let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
    let conn = map.get_mut(&fd)?;
    let mut offset = 0usize;
    while offset < buf.len() {
        if flush_tls(fd, conn).is_err() {
            return Some(-1);
        }
        let written = match conn.writer().write(&buf[offset..]) {
            Ok(0) => return Some(-1),
            Ok(n) => n,
            Err(_) => return Some(-1),
        };
        offset += written;
        if flush_tls(fd, conn).is_err() {
            return Some(-1);
        }
    }
    Some(0)
}

/// Best-effort close_notify, then drop the fd's TLS state.
pub fn close(fd: c_int) {
    if !enabled() {
        return;
    }
    let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(conn) = map.get_mut(&fd) {
        conn.send_close_notify();
        let _ = flush_tls(fd, conn);
    }
    map.remove(&fd);
}
