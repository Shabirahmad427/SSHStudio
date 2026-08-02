# SFTP Performance Candidate Report

Date: 2026-08-02

Scope: local deterministic benchmarks and unit tests only. No real server or Coaraci ProxyJump connection was used.

## Measured Bottlenecks

- Directory browsing used one-off `ssh ls` commands, causing one process launch and authentication path per navigation.
- Directory listings were parsed on the MainActor and constructed unstable `RemoteFile` UUIDs on every refresh.
- The listing cache was an unbounded dictionary keyed only by path, with no TTL, options, profile identity, or invalidation policy.
- Mutations triggered immediate full refreshes independently, allowing refresh storms after batches.
- Transfer progress updates were applied for every parsed progress line.
- Control sockets were under `~/.ssh` and did not include enough profile/auth identity in the hash.

## Architecture Changes

- Normal directory listings now use the authenticated persistent `sftp` session.
- Listing requests use request IDs, obsolete task cancellation, duplicate in-flight coalescing, and stale-response rejection.
- Added a bounded in-memory listing cache keyed by profile ID, normalized path, and listing options, with TTL and LRU eviction.
- Cached listings display immediately, then refresh in the background when stale; explicit refresh bypasses cache TTL.
- Parsing and model creation now happen off MainActor and reuse the shared long-listing parser.
- Remote rows use stable IDs so selection can survive refresh.
- Transfer progress is throttled at the model update boundary.
- OpenSSH ControlPath now lives in a restrictive per-user Application Support directory, with secure temp fallback, and includes profile/auth identity.
- Persistent session queue is bounded, has idle shutdown, joins concurrent connect attempts, and resolves pending continuations on shutdown.

## Before/After Benchmarks

| Metric | Baseline | Optimized candidate | Source |
| --- | ---: | ---: | --- |
| Process launches per 10 directory navigations | 10 | 1 | `fakeBenchmarkShowsPersistentBrowsingAvoidsPerNavigationLaunches` |
| First listing latency | simulated connection + listing | one persistent connection + listing | fake adapter, 2 ms per op |
| Cached listing latency | not TTL-bounded | immediate model update from memory | `directoryCacheHitsExpiresInvalidatesAndEvicts` |
| Repeated listing latency | repeated process/auth path | cache hit or persistent `sftp ls` | fake adapter/cache tests |
| Parsing 100 / 1,000 / 10,000 entries | old parser duplicated date formatter work | shared parser, all counts pass under 3 s budget | `parserHandlesLargeListingsDeterministically` |
| Parser suite runtime | n/a | 0.543 s in full test run; 0.522 s focused run | Swift Testing output |
| MainActor time | parse + model replacement | final `[RemoteFile]` assignment only | structured timing event added |
| Memory use for large listings | not measured | 20,972,120 byte peak footprint in focused performance suite | `/usr/bin/time -l` |
| Progress update frequency | every parsed progress line | minimum 0.2 s between non-terminal updates | `transferProgressUpdatesAreThrottled` |
| Transfer throughput fixtures | not real-network measured | integrity path unchanged; progress throttling only | unit tests/build |

## Tests

- `swift build`: passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: passed, 71 tests in 10 suites.
- Focused benchmark: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/time -l swift test --filter SFTPPerformanceTests`: passed, 6 tests in 0.763 s.

## Remaining Limitations

- Real Coaraci/ProxyJump timing is still needed before installing or packaging this candidate.
- Transfer payload throughput was not benchmarked against a real SFTP server; this candidate preserves the existing transfer path and throttles UI progress only.
- Directory pagination was not added because OpenSSH `sftp ls` does not expose safe protocol-level pagination through this subprocess interface.
- Terminal and SFTP lifecycles remain independent; terminal sessions still opt out of ControlMaster.
