// SPDX-License-Identifier: MIT
//! Wire framing: bincode message codec + length-delimited transport.

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_util::codec::{Framed, LengthDelimitedCodec};

use crate::proto::{IndexRequest, Request, ResponseFrame, SearchRequest};
use crate::{IpcError, Result};

/// Encode a `Search` request. The on-wire form is the tagged [`Request`] enum
/// (so the daemon can distinguish `Search` from `Index`); the `&SearchRequest`
/// signature is preserved so existing callers are unchanged.
pub fn encode_request(req: &SearchRequest) -> Result<Bytes> {
    encode_request_enum(&Request::Search(req.clone()))
}

/// Encode an `Index` request (P2.3 background-build submit).
pub fn encode_index_request(req: &IndexRequest) -> Result<Bytes> {
    encode_request_enum(&Request::Index(req.clone()))
}

fn encode_request_enum(req: &Request) -> Result<Bytes> {
    bincode::serde::encode_to_vec(req, bincode::config::standard())
        .map(Bytes::from)
        .map_err(|e| IpcError::Other(format!("encode request: {e}")))
}

/// Decode a request. Returns the tagged [`Request`] enum so the daemon can
/// dispatch `Search` vs `Index`.
pub fn decode_request(buf: &[u8]) -> Result<Request> {
    bincode::serde::decode_from_slice::<Request, _>(buf, bincode::config::standard())
        .map_err(|e| IpcError::Other(format!("decode request: {e}")))
        .map(|(req, _)| req)
}

pub fn encode_frame(frame: &ResponseFrame) -> Result<Bytes> {
    bincode::serde::encode_to_vec(frame, bincode::config::standard())
        .map(Bytes::from)
        .map_err(|e| IpcError::Other(format!("encode frame: {e}")))
}

pub fn decode_frame(buf: &[u8]) -> Result<ResponseFrame> {
    bincode::serde::decode_from_slice::<ResponseFrame, _>(buf, bincode::config::standard())
        .map_err(|e| IpcError::Other(format!("decode frame: {e}")))
        .map(|(frame, _)| frame)
}

/// Wrap a duplex stream with a 4-byte length-delimited codec.
pub fn framed<S>(stream: S) -> Framed<S, LengthDelimitedCodec>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    Framed::new(stream, LengthDelimitedCodec::new())
}
