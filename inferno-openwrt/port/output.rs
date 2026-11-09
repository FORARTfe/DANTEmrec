// SPDX-License-Identifier: GPL-3.0-or-later
// OpenWrt adapter. No audio-buffer allocations occur in submit().
use std::io;
use std::sync::{atomic::{AtomicBool, AtomicU64, Ordering}, mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

pub trait BlockWriter: Send + 'static {
    fn write_block(&mut self, data: &[u8], cancel: &AtomicBool) -> io::Result<()>;
}

struct Block { bytes: Vec<u8>, used: usize }

pub struct Producer {
    free: mpsc::Receiver<Vec<u8>>,
    ready: mpsc::SyncSender<Block>,
    failed: Arc<AtomicBool>,
    frames_per_block: usize,
    channels: usize,
}

pub struct Control {
    pub failed: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
    pub written_frames: Arc<AtomicU64>,
    thread: Option<JoinHandle<io::Result<()>>>,
}

pub fn start<W: BlockWriter>(writer: W, channels: usize, frames_per_block: usize,
                            blocks: usize) -> io::Result<(Producer, Control)> {
    if !(1..=32).contains(&channels) || !(256..=65536).contains(&frames_per_block)
        || !(2..=64).contains(&blocks) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid output pool dimensions"));
    }
    let bytes = channels.checked_mul(frames_per_block).and_then(|v| v.checked_mul(4))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "output pool overflow"))?;
    let total = bytes.checked_mul(blocks)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "output pool overflow"))?;
    if total > 32 * 1024 * 1024 {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "output pool exceeds 32 MiB limit"));
    }
    let (free_tx, free_rx) = mpsc::sync_channel(blocks);
    let (ready_tx, ready_rx) = mpsc::sync_channel::<Block>(blocks);
    for _ in 0..blocks {
        let mut data = Vec::new();
        data.try_reserve_exact(bytes).map_err(|e| io::Error::other(e.to_string()))?;
        data.resize(bytes, 0);
        free_tx.send(data).map_err(|_| io::Error::other("pool initialization failed"))?;
    }
    let failed = Arc::new(AtomicBool::new(false));
    let cancel = Arc::new(AtomicBool::new(false));
    let written_frames = Arc::new(AtomicU64::new(0));
    let failure_flag = failed.clone();
    let cancel_flag = cancel.clone();
    let frame_counter = written_frames.clone();
    let thread = thread::Builder::new().name("inferno-output".into()).spawn(move || {
        let mut writer = writer;
        let result = (|| -> io::Result<()> {
            loop {
                if cancel_flag.load(Ordering::Acquire) { return Ok(()); }
                let block = match ready_rx.recv_timeout(Duration::from_millis(50)) {
                    Ok(block) => block,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
                };
                writer.write_block(&block.bytes[..block.used], &cancel_flag)?;
                frame_counter.fetch_add((block.used / (channels * 4)) as u64, Ordering::Relaxed);
                // The fixed-size pool bounds all buffers, including the one in flight.
                // During normal shutdown the producer may already have been dropped.
                let _ = free_tx.try_send(block.bytes);
            }
        })();
        if let Err(ref e) = result {
            eprintln!("inferno2pipe: output failed: {e}");
            failure_flag.store(true, Ordering::Release);
        }
        result
    })?;
    Ok((Producer { free: free_rx, ready: ready_tx, failed: failed.clone(),
                    frames_per_block, channels },
        Control { failed, cancel, written_frames, thread: Some(thread) }))
}

/// Serialize planar i32 samples as interleaved S32_LE, independent of CPU endianness.
pub fn interleave(channels: &[Vec<i32>], start: usize, frames: usize, out: &mut [u8])
    -> Result<usize, &'static str> {
    let end = start.checked_add(frames).ok_or("sample index overflow")?;
    let size = frames.checked_mul(channels.len()).and_then(|v| v.checked_mul(4))
        .ok_or("sample byte count overflow")?;
    if channels.is_empty() || out.len() < size || channels.iter().any(|c| c.len() < end) {
        return Err("invalid sample buffer dimensions");
    }
    let mut offset = 0;
    for frame in start..end {
        for channel in channels {
            out[offset..offset + 4].copy_from_slice(&channel[frame].to_le_bytes());
            offset += 4;
        }
    }
    Ok(size)
}

impl Producer {
    pub fn submit(&mut self, frames: usize, channels: &[Vec<i32>]) -> Result<(), &'static str> {
        if self.failed.load(Ordering::Acquire) { return Err("output already failed"); }
        if channels.len() != self.channels || channels.iter().any(|c| c.len() < frames) {
            self.failed.store(true, Ordering::Release);
            return Err("invalid callback dimensions");
        }
        let result = (|| {
            let mut start = 0;
            while start < frames {
                let count = (frames - start).min(self.frames_per_block);
                let mut bytes = self.free.try_recv().map_err(|_| "output pool exhausted; capture stopped")?;
                let used = interleave(channels, start, count, &mut bytes)?;
                self.ready.try_send(Block { bytes, used })
                    .map_err(|_| "output worker unavailable; capture stopped")?;
                start += count;
            }
            Ok(())
        })();
        if result.is_err() { self.failed.store(true, Ordering::Release); }
        result
    }
}

impl Control {
    pub fn is_finished(&self) -> bool { self.thread.as_ref().map_or(true, |t| t.is_finished()) }
    pub fn cancel(&self) { self.cancel.store(true, Ordering::Release); }
    pub fn join_finished(&mut self) -> io::Result<()> {
        if !self.is_finished() {
            return Err(io::Error::new(io::ErrorKind::WouldBlock, "output worker has not stopped"));
        }
        match self.thread.take() {
            Some(t) => t.join().map_err(|_| io::Error::other("output worker panicked"))?,
            None => Ok(()),
        }
    }
}
impl Drop for Control {
    fn drop(&mut self) {
        self.cancel();
        // Never block protocol shutdown on a failed disk. Process exit ends this thread.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::io::Write;
    struct Capture(Arc<Mutex<Vec<u8>>>);
    impl BlockWriter for Capture {
        fn write_block(&mut self, data: &[u8], _: &AtomicBool) -> io::Result<()> {
            self.0.lock().unwrap().write_all(data)
        }
    }
    #[test]
    fn little_endian_and_channel_order() {
        let input = vec![vec![0x01020304, -1], vec![i32::MIN, i32::MAX]];
        let mut out = [0; 16];
        assert_eq!(interleave(&input, 0, 2, &mut out).unwrap(), 16);
        assert_eq!(out, [4,3,2,1,0,0,0,128,255,255,255,255,255,255,255,127]);
    }
    #[test]
    fn rejects_short_buffers_and_overflow() {
        assert!(interleave(&[vec![1]], 0, 2, &mut [0; 8]).is_err());
        assert!(interleave(&[vec![1]], usize::MAX, 1, &mut [0; 4]).is_err());
        assert!(interleave(&[vec![1]], 0, 1, &mut [0; 3]).is_err());
    }
    #[test]
    fn chunking_preserves_frames() {
        let captured = Arc::new(Mutex::new(Vec::new()));
        let (mut producer, mut ctl) = start(Capture(captured.clone()), 2, 256, 4).unwrap();
        let input = vec![(0..600).collect(), (600..1200).collect()];
        producer.submit(600, &input).unwrap();
        drop(producer);
        for _ in 0..100 {
            if ctl.is_finished() { break; }
            thread::sleep(Duration::from_millis(10));
        }
        ctl.join_finished().unwrap();
        let mut expected = vec![0; 600 * 2 * 4];
        interleave(&input, 0, 600, &mut expected).unwrap();
        assert_eq!(*captured.lock().unwrap(), expected);
        assert_eq!(ctl.written_frames.load(Ordering::Relaxed), 600);
    }
    struct Stalled;
    impl BlockWriter for Stalled {
        fn write_block(&mut self, _: &[u8], cancel: &AtomicBool) -> io::Result<()> {
            while !cancel.load(Ordering::Acquire) { thread::sleep(Duration::from_millis(1)); }
            Ok(())
        }
    }
    #[test]
    fn overload_is_bounded_and_visible() {
        let (mut producer, ctl) = start(Stalled, 1, 256, 2).unwrap();
        assert!(producer.submit(3 * 256, &[vec![42; 3 * 256]]).is_err());
        assert!(ctl.failed.load(Ordering::Acquire));
        ctl.cancel();
    }
    #[test]
    fn pool_limit_enforced() {
        assert!(start(Stalled, 32, 65536, 64).is_err());
        assert!(start(Stalled, 0, 256, 4).is_err());
    }
}
