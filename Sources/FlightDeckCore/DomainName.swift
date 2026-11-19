import Foundation
// Destinations, part 2: the organisation behind a host name. `registrable("api.notion.com")` is "notion.com": the
// public suffix ("com") plus one label. The full Public Suffix List has ~10,000 rules; this embeds the few hundred
// multi-label ICANN suffixes that matter in practice (country second levels such as co.uk, com.au, co.jp), and treats
// every other name's last label as its suffix. A name under a suffix that's missing here is grouped one level too
// high (e.g. "a.b.example.xx" → "example.xx" is still right; only rare multi-label suffixes like "k12.ca.us" are
// wrong, and those then group by the suffix's own second label), never split into unrelated organisations.
//
// The PSL's "private" section (e.g. compute-1.amazonaws.com, github.io) is deliberately left out: those are hosting
// customers, and grouping reverse-DNS names by them would make every cloud machine its own organisation. Reverse names
// of hosting and CDN providers are flagged instead (`provider`), since the provider is who owns the IP, not
// necessarily the service the app talked to.

public enum DomainName {
    /// Multi-label public suffixes (ICANN section subset). Single-label TLDs need no entry.
    static let suffixes: Set<String> = {
        var s: Set<String> = []
        // Second levels used under many ccTLDs.
        let common = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "info", "biz", "nom", "gob", "gen", "ltd", "plc", "sch", "nic"]
        let cc = ["uk", "au", "nz", "jp", "kr", "za", "in", "br", "mx", "ar", "cn", "hk", "tw", "sg", "my", "id", "th", "ph", "vn",
                  "tr", "il", "eg", "sa", "ae", "pk", "ng", "ke", "ua", "pe", "co", "ve", "cl", "uy", "ec", "bo", "py", "cr", "pa",
                  "do", "gt", "sv", "hn", "ni", "cu", "jm", "tt", "bd", "lk", "np", "kh", "mm", "la", "mo", "fj", "pg", "ma", "tn",
                  "dz", "gh", "tz", "ug", "zm", "zw", "bw", "na", "mz", "ao", "cm", "ci", "sn", "et", "qa", "kw", "bh", "om", "jo",
                  "lb", "iq", "ir", "af", "kz", "uz", "az", "ge", "am", "by", "md", "rs", "ba", "mk", "al", "me", "mt", "cy", "gr",
                  "pl", "ro", "hu", "pt", "es", "fr", "it"]
        for c in cc { for l in common { s.insert("\(l).\(c)") } }
        // Suffixes that don't follow the pattern above.
        s.formUnion(["ltd.uk", "me.uk", "nhs.uk", "police.uk", "asn.au", "id.au", "geek.nz", "school.nz", "govt.nz",
                     "lg.jp", "ad.jp", "ed.jp", "gr.jp", "re.kr", "pe.kr", "web.za", "firm.in", "res.in", "ind.in",
                     "eu.org", "us.com", "uk.com", "eu.com", "de.com", "cn.com", "jpn.com", "br.com", "za.com",
                     "blogspot.com", "k12.ca.us", "qc.ca", "on.ca", "bc.ca", "ab.ca", "gc.ca", "nsw.gov.au", "vic.gov.au"])
        return s
    }()

    /// Lowercased, trailing dot removed; nil for empty names and numeric addresses (a PTR answer that is itself an
    /// IP literal names nothing).
    public static func normalize(_ host: String) -> String? {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, AddressScope.of(h) == nil, !h.contains(" ") else { return nil }
        return h
    }

    /// The registrable domain ("eTLD+1") of a host name: "api.notion.com" → "notion.com",
    /// "news.bbc.co.uk" → "bbc.co.uk". A name that is itself a suffix (or a single label such as "router") is
    /// returned whole. nil when `host` isn't a name (see `normalize`).
    public static func registrable(_ host: String) -> String? {
        guard let h = normalize(host) else { return nil }
        let labels = h.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count > 2 else { return labels.isEmpty ? nil : labels.joined(separator: ".") }
        // Longest matching suffix first: look at the last 3, then 2 labels.
        for n in stride(from: min(3, labels.count - 1), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            if suffixes.contains(suffix) { return labels.suffix(n + 1).joined(separator: ".") }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Hosting, cloud and CDN providers whose reverse names describe the machine's owner, not the service on it.
    static let providers: [String: String] = [
        "amazonaws.com": "Amazon Web Services", "cloudfront.net": "Amazon CloudFront (CDN)", "awsglobalaccelerator.com": "AWS Global Accelerator",
        "1e100.net": "Google", "googleusercontent.com": "Google Cloud",
        "akamaitechnologies.com": "Akamai (CDN)", "akamaiedge.net": "Akamai (CDN)", "akamai.net": "Akamai (CDN)",
        "fastly.net": "Fastly (CDN)", "cloudflare.com": "Cloudflare",
        "edgecastcdn.net": "Edgecast (CDN)", "azure.com": "Microsoft Azure", "cloudapp.net": "Microsoft Azure",
        "msedge.net": "Microsoft (CDN)", "linodeusercontent.com": "Linode / Akamai Cloud", "your-server.de": "Hetzner",
        "hetzner.com": "Hetzner", "ovh.net": "OVHcloud", "digitalocean.com": "DigitalOcean", "vultrusercontent.com": "Vultr",
        "oraclecloud.com": "Oracle Cloud",
    ]

    /// "Amazon Web Services" for "ec2-3-4-5-6.compute-1.amazonaws.com"; nil for names that aren't a known provider's.
    public static func provider(_ host: String) -> String? {
        guard let d = registrable(host) else { return nil }
        return providers[d]
    }
}
