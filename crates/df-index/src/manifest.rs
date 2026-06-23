// SPDX-License-Identifier: MIT
//! Content shard MANIFEST: the shard list + base_docid map + build_time, written
//! atomically alongside the `.dfcs` files.

use std::path::Path;

use df_core::varint::{decode_u32, encode_u32};

/// One entry per content shard.
#[derive(Debug, Clone)]
pub struct ShardEntry {
    pub shard_id: u32,
    pub base_docid: u32,
    pub num_docs: u32,
    pub file: String, // shard-NNNNN.dfcs (filename within the content dir)
}

#[derive(Debug, Clone)]
pub struct Manifest {
    pub build_time: u64,
    pub total_content_docs: u32,
    pub shards: Vec<ShardEntry>,
}

impl Manifest {
    /// build_time:u64, total:u32, count:u32, then per shard
    /// (id:u32, base:u32, num:u32, varint file-len, file bytes).
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.build_time.to_le_bytes());
        out.extend_from_slice(&self.total_content_docs.to_le_bytes());
        out.extend_from_slice(&(self.shards.len() as u32).to_le_bytes());
        for s in &self.shards {
            out.extend_from_slice(&s.shard_id.to_le_bytes());
            out.extend_from_slice(&s.base_docid.to_le_bytes());
            out.extend_from_slice(&s.num_docs.to_le_bytes());
            encode_u32(s.file.len() as u32, &mut out);
            out.extend_from_slice(s.file.as_bytes());
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 16 {
            return None;
        }
        let bt = u64::from_le_bytes(bytes[0..8].try_into().ok()?);
        let total = u32::from_le_bytes(bytes[8..12].try_into().ok()?);
        let count = u32::from_le_bytes(bytes[12..16].try_into().ok()?) as usize;
        let mut p = 16usize;
        let mut shards = Vec::with_capacity(count);
        for _ in 0..count {
            if p + 12 > bytes.len() {
                return None;
            }
            let id = u32::from_le_bytes(bytes[p..p + 4].try_into().ok()?);
            let base = u32::from_le_bytes(bytes[p + 4..p + 8].try_into().ok()?);
            let num = u32::from_le_bytes(bytes[p + 8..p + 12].try_into().ok()?);
            p += 12;
            let flen = decode_u32(bytes, &mut p)? as usize;
            if p + flen > bytes.len() {
                return None;
            }
            let file = String::from_utf8(bytes[p..p + flen].to_vec()).ok()?;
            p += flen;
            shards.push(ShardEntry {
                shard_id: id,
                base_docid: base,
                num_docs: num,
                file,
            });
        }
        Some(Manifest {
            build_time: bt,
            total_content_docs: total,
            shards,
        })
    }

    pub fn read(path: &Path) -> Option<Self> {
        let bytes = std::fs::read(path).ok()?;
        Self::decode(&bytes)
    }
}

pub fn write_manifest(path: &Path, manifest: &Manifest) -> crate::Result<()> {
    crate::atomic_write_public(path, &manifest.encode())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_roundtrip() {
        let m = Manifest {
            build_time: 555,
            total_content_docs: 100,
            shards: vec![
                ShardEntry {
                    shard_id: 0,
                    base_docid: 0,
                    num_docs: 50,
                    file: "shard-00000.dfcs".into(),
                },
                ShardEntry {
                    shard_id: 1,
                    base_docid: 50,
                    num_docs: 50,
                    file: "shard-00001.dfcs".into(),
                },
            ],
        };
        let bytes = m.encode();
        let back = Manifest::decode(&bytes).unwrap();
        assert_eq!(back.build_time, 555);
        assert_eq!(back.total_content_docs, 100);
        assert_eq!(back.shards.len(), 2);
        assert_eq!(back.shards[1].base_docid, 50);
        assert_eq!(back.shards[1].file, "shard-00001.dfcs");
    }
}
