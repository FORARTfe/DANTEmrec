// SPDX-License-Identifier: GPL-3.0-or-later
// Capacity is independent of advertised network latency and the collector cadence.
fn parse_samples(value: &str) -> Result<usize, &'static str> {
    let n: usize = value.parse().map_err(|_| "RX_BUFFER_SAMPLES is not an integer")?;
    if !(65536..=524288).contains(&n) || !n.is_power_of_two() {
        return Err("RX_BUFFER_SAMPLES must be a power of two in 65536..=524288");
    }
    Ok(n)
}
pub(crate) fn samples() -> usize {
    parse_samples(&std::env::var("INFERNO_RX_BUFFER_SAMPLES").unwrap_or_else(|_| "65536".into()))
        .expect("invalid OpenWrt receive buffer setting")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn accepts_bounded_powers_of_two() {
        for n in [65536, 131072, 262144, 524288] { assert_eq!(parse_samples(&n.to_string()), Ok(n)); }
    }
    #[test] fn rejects_bad_sizes() {
        for s in ["0", "-1", "65535", "65537", "1048576", "bad", ""] { assert!(parse_samples(s).is_err()); }
    }
}
