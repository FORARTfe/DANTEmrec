// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2023-2025 Teodor Wozniak
// OpenWrt frontend for Inferno by Teodor Wozniak and contributors.
mod output;
mod sink;
use clap::Parser;
use inferno_aoip::device_server::{DeviceServer, Settings};
use log::{error, info};
use std::{io, path::PathBuf, process::ExitCode, sync::{Arc, atomic::{AtomicBool, Ordering}}, time::Duration};
use tokio::signal::unix::{signal, SignalKind};

#[derive(Parser, Debug)]
#[command(version, about = "Unofficial Dante-compatible capture for OpenWrt; not endorsed by Audinate")]
struct Args {
    #[arg(long, short = 'c', default_value_t = 2, value_parser = clap::value_parser!(u16).range(1..=32))]
    channels_count: u16,
    #[arg(long, short = 'o', default_value = "/dev/null")]
    output: PathBuf,
    #[arg(long, default_value_t = 4096, value_parser = clap::value_parser!(u32).range(256..=65536))]
    block_frames: u32,
    #[arg(long, default_value_t = 16, value_parser = clap::value_parser!(u16).range(2..=64))]
    queue_blocks: u16,
    #[arg(long, default_value_t = 5000, value_parser = clap::value_parser!(u32).range(100..=30000))]
    output_timeout_ms: u32,
    #[arg(long, default_value_t = 60, value_parser = clap::value_parser!(u32).range(5..=600))]
    startup_timeout_s: u32,
}
async fn wait_failure(failed: Arc<AtomicBool>) {
    while !failed.load(Ordering::Acquire) { tokio::time::sleep(Duration::from_millis(50)).await; }
}
async fn run(args: Args) -> Result<(), Box<dyn std::error::Error>> {
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let mut settings = Settings::new("Inferno OpenWrt", "InfernoOW", None, &Default::default());
    settings.make_rx_channels(args.channels_count as usize);
    settings.make_tx_channels(0);
    let writer = sink::Sink::new(args.output.clone(), Duration::from_millis(args.output_timeout_ms as u64));
    let (mut producer, mut control) = output::start(writer, args.channels_count as usize,
                                                  args.block_frames as usize, args.queue_blocks as usize)?;
    info!("output={:?}; PCM=S32_LE; channels={}; rate={}; pool={} bytes",
          args.output, args.channels_count, settings.self_info.sample_rate,
          args.channels_count as usize * args.block_frames as usize * args.queue_blocks as usize * 4);
    let start = tokio::time::timeout(Duration::from_secs(args.startup_timeout_s as u64),
                                   DeviceServer::start(settings));
    let mut server = tokio::select! {
        result = start => result.map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "PTP startup timed out"))?,
        _ = terminate.recv() => return Ok(()),
        _ = interrupt.recv() => return Ok(()),
        _ = wait_failure(control.failed.clone()) => return Err(io::Error::other("output failed during startup").into()),
    };
    let mut reported = false;
    server.receive_with_callback(Box::new(move |frames, channels| {
        if !reported {
            if let Err(e) = producer.submit(frames, channels) {
                error!("{e}");
                reported = true;
            }
        }
    })).await;
    tokio::select! {
        _ = terminate.recv() => info!("SIGTERM: stopping"),
        _ = interrupt.recv() => info!("SIGINT: stopping"),
        _ = wait_failure(control.failed.clone()) => error!("output failed; stopping capture"),
    }
    // Keep the writer alive while the callback is shut down; then drain its queue.
    if tokio::time::timeout(Duration::from_secs(5), server.shutdown()).await.is_err() {
        error!("protocol shutdown timed out");
    }
    let drain_deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while !control.is_finished() && tokio::time::Instant::now() < drain_deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    if !control.is_finished() {
        control.cancel();
        return Err(io::Error::new(io::ErrorKind::TimedOut, "output did not drain; final queued audio may be incomplete").into());
    }
    control.join_finished()?;
    info!("output complete: {} frames", control.written_frames.load(Ordering::Relaxed));
    if control.failed.load(Ordering::Acquire) {
        return Err(io::Error::other("capture stopped after output overload/failure").into());
    }
    Ok(())
}
#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .write_style(env_logger::WriteStyle::Never).init();
    match run(Args::parse()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => { error!("{e}"); ExitCode::FAILURE }
    }
}
