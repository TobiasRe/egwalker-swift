//! Exports a diamond-types .dt file to JSON with the *original* agent names and
//! sequence numbers, including whether each delete run was forward or backspace.
//! Format: {"endContent": "...", "txns": [{"agent","seqStart","span":[s,e],"parents":[..],
//!          "ops":[[pos, delLen, insContent, fwd], ...]}]}
use diamond_types::list::ListOpLog;
use diamond_types::list::operation::ListOpKind;

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&args[1]).unwrap();
    let oplog = ListOpLog::load_from(&bytes).unwrap();
    let mut out = String::new();
    out.push_str("{\"endContent\":");
    out.push_str(&esc(&oplog.checkout_tip().content().to_string()));
    out.push_str(",\"txns\":[");
    for (i, e) in oplog.as_chunked_operation_vec().into_iter().enumerate() {
        if i > 0 { out.push(','); }
        let parents: Vec<String> = e.parents.0.iter().map(|p| p.to_string()).collect();
        out.push_str(&format!("{{\"agent\":{},\"seqStart\":{},\"span\":[{},{}],\"parents\":[{}],\"ops\":[",
            esc(oplog.get_agent_name(e.agent_span.agent)), e.agent_span.seq_range.start,
            e.span.start, e.span.end, parents.join(",")));
        for (j, op) in e.ops.iter().enumerate() {
            if j > 0 { out.push(','); }
            match op.kind {
                ListOpKind::Ins => out.push_str(&format!("[{},0,{},true]", op.loc.span.start,
                    esc(op.content.as_ref().map(|c| c.as_str()).unwrap_or("")))),
                ListOpKind::Del => out.push_str(&format!("[{},{},\"\",{}]", op.loc.span.start,
                    op.loc.span.end - op.loc.span.start, op.loc.fwd)),
            }
        }
        out.push_str("]}");
    }
    out.push_str("]}");
    std::fs::write(&args[2], out).unwrap();
}
