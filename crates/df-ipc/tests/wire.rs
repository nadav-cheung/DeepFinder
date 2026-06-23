// SPDX-License-Identifier: MIT
//! Wire tests: bincode message round-trips + LengthDelimitedCodec framing.

use bytes::{Bytes, BytesMut};
use df_ipc::proto::{MatchKind, ResponseFrame, SearchOptions, SearchRequest};
use df_ipc::wire::{decode_frame, decode_request, encode_frame, encode_request};
use tokio_util::codec::{Decoder, Encoder, LengthDelimitedCodec};

fn sample_request() -> SearchRequest {
    SearchRequest {
        query: "downloads report".into(),
        scope: Some("/Users/x".into()),
        limit: Some(50),
        opts: SearchOptions {
            direct: false,
            extensions: vec![],
            types: vec![],
            excludes: vec![],
        },
    }
}

#[test]
fn request_roundtrip() {
    let req = sample_request();
    let buf = encode_request(&req).unwrap();
    let back = decode_request(&buf).unwrap();
    assert_eq!(back.query, req.query);
    assert_eq!(back.scope, req.scope);
    assert_eq!(back.limit, req.limit);
    assert!(!back.opts.direct);
}

#[test]
fn frame_roundtrip_all_variants() {
    let cases = vec![
        ResponseFrame::Batch {
            paths: vec!["/a/b".into(), "/c/d".into()],
            meta: vec![],
            kind: vec![MatchKind::Filename, MatchKind::Content],
        },
        ResponseFrame::Done { total: 7 },
        ResponseFrame::Error {
            message: "boom".into(),
        },
    ];
    for frame in cases {
        let buf = encode_frame(&frame).unwrap();
        let back = decode_frame(&buf).unwrap();
        assert!(matches!(
            back,
            ResponseFrame::Batch { .. } | ResponseFrame::Done { .. } | ResponseFrame::Error { .. }
        ));
    }
}

/// The transport codec: a length-prefixed Bytes round-trips intact. This is the
/// primitive the daemon/CLI rely on; bincode payload is independent of it.
#[test]
fn length_delimited_codec_roundtrip() {
    let mut codec = LengthDelimitedCodec::new();
    let mut buf = BytesMut::new();
    codec
        .encode(Bytes::from_static(b"payload"), &mut buf)
        .unwrap();
    // encoded = 4-byte length prefix + payload
    assert_eq!(buf.len(), 4 + 7);
    let decoded = codec.decode(&mut buf).unwrap();
    let got = decoded.unwrap();
    assert_eq!(got.as_ref(), &b"payload"[..]);
    // fully consumed
    assert!(buf.is_empty());
}
