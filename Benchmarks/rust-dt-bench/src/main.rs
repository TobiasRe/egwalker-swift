//! Benchmark harness for diamond-types: measures `checkout_tip()` ("merge" in the
//! Eg-walker paper benchmarks) on the paper traces, plus allocator peak memory.
//! Usage: dt-bench <path/to/X.dt> [iterations]
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};
use std::time::Instant;
use diamond_types::list::ListOpLog;

struct Counting;
static CUR: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = System.alloc(l);
        if !p.is_null() { let c = CUR.fetch_add(l.size(), Relaxed) + l.size(); PEAK.fetch_max(c, Relaxed); }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) { CUR.fetch_sub(l.size(), Relaxed); System.dealloc(p, l) }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        let r = System.realloc(p, l, n);
        if !r.is_null() {
            if n >= l.size() { let c = CUR.fetch_add(n - l.size(), Relaxed) + (n - l.size()); PEAK.fetch_max(c, Relaxed); }
            else { CUR.fetch_sub(l.size() - n, Relaxed); }
        }
        r
    }
}
#[global_allocator] static A: Counting = Counting;

// When run under LD_PRELOAD=libmemtrack.so, use the same malloc-level tracker as
// the Swift harness so both numbers are measured identically.
extern "C" { fn dlsym(handle: *mut std::ffi::c_void, symbol: *const std::ffi::c_char) -> *mut std::ffi::c_void; }
fn memtrack(name: &str) -> Option<extern "C" fn() -> i64> {
    let c = std::ffi::CString::new(name).unwrap();
    let p = unsafe { dlsym(std::ptr::null_mut(), c.as_ptr()) };
    if p.is_null() { None } else { Some(unsafe { std::mem::transmute::<*mut std::ffi::c_void, extern "C" fn() -> i64>(p) }) }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let iters: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(20);
    let bytes = std::fs::read(path).unwrap();
    let oplog = ListOpLog::load_from(&bytes).unwrap();

    // Memory: peak heap growth during one checkout, relative to the loaded oplog.
    let (mt_cur, mt_peak) = (memtrack("memtrack_current"), memtrack("memtrack_peak"));
    if let Some(reset) = memtrack("memtrack_reset_peak") { reset(); }
    let mt_base = mt_cur.map(|f| f()).unwrap_or(0);
    let base = CUR.load(Relaxed);
    PEAK.store(base, Relaxed);
    let branch = oplog.checkout_tip();
    let (peak, retained) = match (mt_cur, mt_peak) {
        (Some(c), Some(p)) => ((p() - mt_base) as usize, (c() - mt_base) as usize),
        _ => (PEAK.load(Relaxed) - base, CUR.load(Relaxed) - base),
    };
    let len = branch.len();
    drop(branch);

    let mut times = Vec::with_capacity(iters);
    for _ in 0..iters {
        let t = Instant::now();
        let b = oplog.checkout_tip();
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        std::hint::black_box(&b);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let median = times[times.len() / 2];
    let min = times[0];
    println!("{{\"impl\":\"diamond-types\",\"trace\":\"{}\",\"ops\":{},\"docLen\":{},\"medianMs\":{:.3},\"minMs\":{:.3},\"peakHeapBytes\":{},\"retainedBytes\":{}}}",
        std::path::Path::new(path).file_stem().unwrap().to_string_lossy(), oplog.len(), len, median, min, peak, retained);
}
