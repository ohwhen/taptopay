#!/usr/bin/env ruby
# frozen_string_literal: true

# Refresh PSP × country coverage from Apple's Tap to Pay regions page.
#
# Reads:  data.json (previous snapshot — optional, used for diff)
# Writes: data.json (fresh scrape), CHANGELOG.md (prepends diff), README.md, index.html
#
# Local:  bundle exec ruby scripts/refresh.rb
# CI:     .github/workflows/refresh.yml

require "http"
require "oga"
require "countries"
require "json"
require "date"
require "set"
require "cgi"
require "pathname"

ROOT           = Pathname.new(File.expand_path("..", __dir__))
DATA_PATH      = ROOT.join("data.json")
CHANGELOG_PATH = ROOT.join("CHANGELOG.md")
README_PATH    = ROOT.join("README.md")
INDEX_PATH     = ROOT.join("index.html")

SOURCE_URL = "https://developer.apple.com/tap-to-pay/regions/"

# Display names Apple uses that don't directly match an ISO short name (or that
# we want to force to a specific code regardless). Extend if Apple ever uses
# an unusual spelling.
EXPLICIT_CODE = {
  "UAE" => "AE",
  "UK"  => "GB",
  "USA" => "US"
}.freeze

# Shorter labels for ISO names that are awkwardly long as column headers.
SHORT_LABEL_OVERRIDES = {
  "AE" => "UAE",
  "GB" => "UK",
  "US" => "USA"
}.freeze

def lookup_code(display_name)
  return EXPLICIT_CODE[display_name] if EXPLICIT_CODE.key?(display_name)
  c = ISO3166::Country.find_country_by_any_name(display_name)
  c&.alpha2
end

def short_label(code, full_name)
  SHORT_LABEL_OVERRIDES[code] || full_name
end

# PSP brand consolidation (case-insensitive).
NAME_NORMALIZE = {
  "mypos"            => "myPOS",
  "viva"             => "Viva.com",
  "viva.com"         => "Viva.com",
  "bnp parisbas"     => "BNP Paribas", # typo in Apple's Monaco section
  "worldline/payone" => "Worldline",
  "pay.nl"           => "Pay.nl"
}.freeze

GLOBAL_MIN   = 5
REGIONAL_MIN = 2

CHANGELOG_HEADER = <<~MD
  # Changelog

  Daily diff of [Apple's Tap to Pay on iPhone — Regions](https://developer.apple.com/tap-to-pay/regions/) page, maintained by `scripts/refresh.rb` via GitHub Actions. Most recent change at the top.

MD

# ─── scrape ────────────────────────────────────────────────────────────────────

def normalize_name(raw)
  n = raw.gsub(/\s+/, " ").strip
  NAME_NORMALIZE.fetch(n.downcase, n)
end

def scrape
  resp = HTTP
    .headers("User-Agent" => "taptopay-refresh/1.0 (+https://github.com/ohwhen/taptopay)")
    .timeout(30)
    .get(SOURCE_URL)
  abort "FATAL: HTTP #{resp.status} fetching #{SOURCE_URL}" unless resp.status.success?

  doc   = Oga.parse_html(resp.to_s)
  items = doc.css(".region-item")
  abort "FATAL: no .region-item elements found — Apple's HTML structure changed." if items.empty?

  countries = []
  seen      = Set.new

  items.each do |item|
    h4 = item.at_css("h4")
    next unless h4

    country = h4.text.strip
    code    = lookup_code(country)
    abort "FATAL: cannot resolve ISO code for country '#{country}' — add an EXPLICIT_CODE entry or check the `countries` gem." unless code
    warn "WARN: duplicate country #{code} (#{country})" if seen.include?(code)
    seen << code

    psps = []
    item.css("ul > li").each do |li|
      anchors = li.css("a").to_a
      if anchors.any?
        first   = anchors[0]
        name    = normalize_name(first.text)
        url     = first.attribute("href")&.value
        sdk_url = nil
        if anchors.size >= 2 && anchors[1].text.strip.downcase == "sdk"
          sdk_url = anchors[1].attribute("href")&.value
        end
        psps << { "name" => name, "url" => url, "sdk_url" => sdk_url, "status" => "live" }
      else
        text = li.text.strip
        m    = text.match(/\A(.+?)\s*\(coming soon\)\s*\z/i)
        if m.nil?
          warn "WARN: unparseable <li> #{text.inspect}"
          next
        end
        psps << { "name" => normalize_name(m[1]), "url" => nil, "sdk_url" => nil, "status" => "coming_soon" }
      end
    end

    psps.sort_by! { |p| [p["name"].downcase, p["status"]] }
    countries << { "code" => code, "name" => country, "psps" => psps }
  end

  countries.sort_by! { |c| c["name"] }
  abort "FATAL: only #{seen.size} countries scraped — Apple's page may be incomplete." if seen.size < 30

  {
    "snapshot_date" => Date.today.iso8601,
    "source_url"    => SOURCE_URL,
    "countries"     => countries
  }
end

# ─── diff / changelog ──────────────────────────────────────────────────────────

def flatten_pairs(data, statuses)
  out = Set.new
  data["countries"].each do |c|
    c["psps"].each do |p|
      out << [c["code"], c["name"], p["name"]] if statuses.include?(p["status"])
    end
  end
  out
end

def diff_data(old, new_data)
  old_live = flatten_pairs(old, ["live"])
  new_live = flatten_pairs(new_data, ["live"])
  old_soon = flatten_pairs(old, ["coming_soon"])
  new_soon = flatten_pairs(new_data, ["coming_soon"])

  added_live    = new_live - old_live
  removed_live  = old_live - new_live
  added_soon    = new_soon - old_soon
  removed_soon  = old_soon - new_soon

  became_live   = added_live.select { |k| old_soon.include?(k) }
  brand_new     = added_live.reject { |k| old_soon.include?(k) }
  soon_dropped  = removed_soon.reject { |k| new_live.include?(k) }
  newly_soon    = added_soon.reject { |k| old_live.include?(k) }

  {
    added:           brand_new.sort,
    became_live:     became_live.sort,
    removed:         removed_live.to_a.sort,
    newly_announced: newly_soon.sort,
    soon_removed:    soon_dropped.sort
  }
end

def changelog_entry(date, diff)
  out = +"## #{date}\n"
  emit = lambda do |title, items|
    next if items.empty?
    out << "\n### #{title}\n"
    items.each { |cc, cn, pn| out << "- #{pn} — #{cn} (`#{cc}`)\n" }
  end
  emit.call("Added (live)",                diff[:added])
  emit.call("Now live (was coming soon)",  diff[:became_live])
  emit.call("Removed",                     diff[:removed])
  emit.call("Newly announced",             diff[:newly_announced])
  emit.call("No longer announced",         diff[:soon_removed])
  out << "\n"
  out
end

def prepend_changelog(date, body)
  existing = CHANGELOG_PATH.exist? ? CHANGELOG_PATH.read : CHANGELOG_HEADER
  existing = CHANGELOG_HEADER + existing unless existing.start_with?("# Changelog")

  if (m = existing.match(/\n(## \d{4}-\d{2}-\d{2})/))
    head = existing[0...m.begin(0)].rstrip + "\n\n"
    tail = existing[m.begin(0)..].sub(/\A\n+/, "")
  else
    head = existing.rstrip + "\n\n"
    tail = ""
  end
  CHANGELOG_PATH.write(head + body + tail)
end

# ─── rendering helpers ─────────────────────────────────────────────────────────

def psp_index(data)
  index = Hash.new { |h, k| h[k] = {} }
  urls  = {}
  data["countries"].each do |c|
    c["psps"].each do |p|
      cur = index[p["name"]][c["code"]]
      next if cur == "live"
      index[p["name"]][c["code"]] = p["status"]
      urls[p["name"]] = p["url"] if p["url"] && urls[p["name"]].nil?
    end
  end
  [index, urls]
end

def live_count(sup) = sup.count { |_, v| v == "live" }
def soon_count(sup) = sup.count { |_, v| v == "coming_soon" }

# ─── README ────────────────────────────────────────────────────────────────────

def render_readme(data)
  index, urls = psp_index(data)
  codes = data["countries"].map { |c| c["code"] }
  name_by_code = data["countries"].each_with_object({}) { |c, h| h[c["code"]] = c["name"] }

  rows = index.sort_by { |name, sup| [-live_count(sup), name.downcase] }
  total_psps = rows.size
  total_live = rows.sum { |_, sup| live_count(sup) }

  c_live = codes.each_with_object({}) { |c, h| h[c] = 0 }
  c_soon = codes.each_with_object({}) { |c, h| h[c] = 0 }
  rows.each do |_, sup|
    sup.each { |cc, v| (v == "live" ? c_live : c_soon)[cc] += 1 }
  end

  globals_  = rows.select { |_, s| live_count(s) >= GLOBAL_MIN }
  regionals = rows.select { |_, s| live_count(s).between?(REGIONAL_MIN, GLOBAL_MIN - 1) }
  locals_   = rows.select { |_, s| live_count(s) == 1 }
  soon_only = rows.select { |_, s| live_count(s).zero? }

  matrix = lambda do |rows_in, with_footer: false|
    lines = []
    lines << "| PSP | #{codes.join(' | ')} | Total |"
    lines << "|:---|#{':-:|' * codes.size}---:|"
    rows_in.each do |name, sup|
      cells = codes.map do |cc|
        case sup[cc]
        when "live"        then "●"
        when "coming_soon" then "◐"
        else                    " "
        end
      end
      live = live_count(sup)
      soon = soon_count(sup)
      t = "**#{live}**" + (soon.positive? ? " (+#{soon}◐)" : "")
      label = urls[name] ? "[#{name}](#{urls[name]})" : name
      lines << "| #{label} | #{cells.join(' | ')} | #{t} |"
    end
    if with_footer
      fts = codes.map do |cc|
        cell = "**#{c_live[cc]}**"
        cell += "+#{c_soon[cc]}◐" if c_soon[cc].positive?
        cell
      end
      lines << "| **Country total (all PSPs)** | #{fts.join(' | ')} | **#{total_live}** |"
    end
    lines
  end

  out = []
  out << "<!-- generated from data.json by scripts/refresh.rb — do not edit -->"
  out << ""
  out << "![taptopay — Apple Tap to Pay on iPhone PSP × country coverage](assets/banner.png)"
  out << ""
  out << "*Who supports [Tap to Pay on iPhone](https://developer.apple.com/tap-to-pay/) where — flipped from Apple's by-country list into a single PSP × country matrix. Refreshed daily from [Apple's regions page](https://developer.apple.com/tap-to-pay/regions/).*"
  out << ""
  out << "---"
  out << ""
  out << "## Why"
  out << ""
  out << "Apple's [Tap to Pay regions page](https://developer.apple.com/tap-to-pay/regions/) lists, for each supported country, the PSPs you can integrate with — answering *\"is my PSP in country X?\"* one country at a time. This repo flips the data so you can also ask the other direction: which PSPs span the most countries, and where do they overlap. Updated daily; see [CHANGELOG.md](CHANGELOG.md) for additions and removals."
  out << ""
  out << "## Coverage matrix"
  out << ""
  out << "Visible: **#{globals_.size} PSPs with reach in #{GLOBAL_MIN}+ countries**, sorted by coverage. The footer row counts PSPs across *all* #{total_psps} entries (including collapsed sections below). `●` live · `◐` announced. PSP names link to each provider's Tap to Pay page."
  out << ""
  out.concat(matrix.call(globals_, with_footer: true))
  out << ""

  out << "<details>"
  out << "<summary><strong>Regional PSPs</strong> — #{regionals.size} more with reach in #{REGIONAL_MIN}–#{GLOBAL_MIN - 1} countries</summary>"
  out << ""
  out.concat(matrix.call(regionals))
  out << ""
  out << "</details>"
  out << ""

  local_by_country = Hash.new { |h, k| h[k] = [] }
  locals_.each do |name, sup|
    sup.each do |cc, v|
      next unless v == "live"
      label = urls[name] ? "[#{name}](#{urls[name]})" : name
      local_by_country[cc] << label
      break
    end
  end
  out << "<details>"
  out << "<summary><strong>Country-specific PSPs</strong> — #{locals_.size} PSPs available in only one country, grouped by country</summary>"
  out << ""
  out << "| Country | PSPs available *only* here |"
  out << "|:---|:---|"
  codes.select { |c| local_by_country.key?(c) }.sort_by { |c| name_by_code[c] }.each do |cc|
    psps = local_by_country[cc].sort_by(&:downcase)
    out << "| #{name_by_code[cc]} (`#{cc}`) | #{psps.join(', ')} |"
  end
  out << ""
  out << "</details>"
  out << ""

  soon_pairs = []
  soon_only.each do |name, sup|
    sup.each do |cc, v|
      if v == "coming_soon"
        soon_pairs << [name, cc]
        break
      end
    end
  end
  out << "<details>"
  out << "<summary><strong>Coming soon</strong> — #{soon_pairs.size} PSPs announced but not yet live</summary>"
  out << ""
  out << "| PSP | Country |"
  out << "|:---|:---|"
  soon_pairs.sort_by { |n, _| n.downcase }.each { |n, cc| out << "| #{n} | #{name_by_code[cc]} (`#{cc}`) |" }
  out << ""
  out << "*(Some live PSPs also have a `◐` announcement for another country; those show ◐ in their row above.)*"
  out << ""
  out << "</details>"
  out << ""

  top5 = globals_.first(5)
  country_rank = codes.sort_by { |c| [-c_live[c], c] }.first(5)
  out << "## At a glance"
  out << ""
  out << "- **#{total_psps} PSPs** across **#{codes.size} countries / regions** — #{total_live} live PSP × country combinations."
  out << "- Broadest reach: #{top5.map { |n, s| "**#{n}** (#{live_count(s)})" }.join(', ')}."
  out << "- Densest markets: #{country_rank.map { |c| "**#{c}** (#{c_live[c]} PSPs)" }.join(', ')}."
  out << "- Long tail: **#{locals_.size}** PSPs are country-specific (one country only)."
  out << ""
  out << "## Interactive table"
  out << ""
  out << "GitHub strips the CSS that pins table headers. Sticky-header version with every PSP in one view: **<https://ohwhen.github.io/taptopay/>**."
  out << ""
  out << "## Country codes"
  out << ""
  buf = []
  data["countries"].each do |c|
    buf << "`#{c['code']}` #{short_label(c['code'], c['name'])}"
    if buf.size == 5
      out << (buf.join(" · ") + "  ")
      buf = []
    end
  end
  out << (buf.join(" · ") + "  ") unless buf.empty?
  out << ""

  out << "## Data"
  out << ""
  out << "Machine-readable: [`data.json`](data.json) — the source of truth this README is generated from."
  out << ""
  out << "```"
  out << "{"
  out << '  "snapshot_date": "YYYY-MM-DD",'
  out << '  "source_url": "https://developer.apple.com/tap-to-pay/regions/",'
  out << '  "countries": ['
  out << '    {"code": "AU", "name": "Australia", "psps": ['
  out << '      {"name": "Adyen", "url": "https://…", "sdk_url": "https://…", "status": "live"},'
  out << "      …"
  out << "    ]}, …"
  out << "  ]"
  out << "}"
  out << "```"
  out << ""
  out << "## Notes"
  out << ""
  out << "- Brands with multiple spellings on Apple's page are consolidated by `scripts/refresh.rb` — `myPos`/`MyPos`/`myPOS` → **myPOS**; `Viva`/`Viva.com` → **Viva.com**; `BNP Parisbas` (Monaco, sic) → **BNP Paribas**; `Worldline/Payone` (Austria) → **Worldline**. **PAYONE** (Germany) is kept distinct because Apple lists it as its own brand."
  out << "- The visible matrix's footer counts PSPs across all sections (visible + collapsed), so the per-country numbers match the interactive page."
  out << ""
  out << "## Source"
  out << ""
  out << "Apple, [Tap to Pay on iPhone — Regions](https://developer.apple.com/tap-to-pay/regions/). Snapshot: **#{data['snapshot_date']}**."
  out << ""

  out.join("\n")
end

# ─── index.html ────────────────────────────────────────────────────────────────

INDEX_CSS = <<~CSS
  :root{--bg:#0a0a0a;--panel:#111;--panel-2:#161616;--ink:#f2f2f2;--ink-dim:#b8b8b8;--ink-mute:#777;--line:#222;--line-soft:#1a1a1a}
  *{box-sizing:border-box}html,body{margin:0;padding:0;background:var(--bg);color:var(--ink)}
  body{font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Helvetica,Arial,sans-serif;min-height:100vh}
  header{max-width:1200px;margin:0 auto;padding:40px 24px 24px}
  header h1{margin:0 0 6px;font-size:36px;font-weight:700;letter-spacing:-.02em}
  header p{margin:0;color:var(--ink-dim);font-size:16px}
  header .meta{margin-top:14px;display:flex;flex-wrap:wrap;gap:8px;font-size:13px;color:var(--ink-mute)}
  header .meta a{color:var(--ink-dim);text-decoration:underline;text-decoration-color:var(--ink-mute)}
  header .meta a:hover{color:var(--ink)}
  header .legend{margin-top:14px;display:flex;gap:18px;font-size:13px;color:var(--ink-dim)}
  header .legend .dot{display:inline-block;width:10px;height:10px;border-radius:50%;vertical-align:middle;margin-right:6px}
  .dot.live{background:var(--ink)}.dot.soon{background:transparent;border:1.5px solid var(--ink-dim)}
  .matrix-wrap{max-width:1200px;margin:0 auto;padding:0 24px 60px}
  .matrix{position:relative;overflow:auto;max-height:80vh;background:var(--panel);border:1px solid var(--line);border-radius:8px;scrollbar-color:#333 #111}
  table{border-collapse:separate;border-spacing:0;font-size:13px;width:max-content}
  th,td{padding:6px 9px;text-align:center;white-space:nowrap;border-right:1px solid var(--line-soft);border-bottom:1px solid var(--line-soft);background:var(--panel)}
  th{font-weight:600;color:var(--ink-dim);font-size:12px;letter-spacing:.03em}
  thead th{position:sticky;top:0;z-index:2;background:var(--panel-2)}
  th:first-child,td:first-child{position:sticky;left:0;z-index:1;text-align:left;background:var(--panel-2);border-right:1px solid var(--line);min-width:220px;max-width:220px;padding-left:14px}
  th:last-child,td:last-child{position:sticky;right:0;z-index:1;background:var(--panel-2);border-left:1px solid var(--line);text-align:right;padding-right:14px;font-variant-numeric:tabular-nums}
  thead th:first-child,thead th:last-child{z-index:4}
  tfoot td{font-weight:600;background:var(--panel-2);color:var(--ink)}
  td.live{color:var(--ink)}td.soon{color:var(--ink-dim)}td.empty{color:#2a2a2a}
  td.psp{font-weight:600;color:var(--ink)} td.psp a{color:var(--ink);text-decoration:none;border-bottom:1px dotted var(--ink-mute)} td.psp a:hover{border-bottom-color:var(--ink)}
  th.code abbr{text-decoration:none;cursor:help}
  tbody tr:hover td{background:#1c1c1c} tbody tr:hover td:first-child,tbody tr:hover td:last-child{background:#232323}
  footer{max-width:1200px;margin:0 auto;padding:0 24px 60px;color:var(--ink-mute);font-size:13px}
  footer a{color:var(--ink-dim)}
  @media (max-width:700px){header h1{font-size:28px}th:first-child,td:first-child{min-width:160px;max-width:160px}}
CSS

def esc(s) = CGI.escapeHTML(s.to_s)

def render_index_html(data)
  index, urls = psp_index(data)
  codes = data["countries"].map { |c| c["code"] }
  name_by_code = data["countries"].each_with_object({}) { |c, h| h[c["code"]] = c["name"] }
  rows = index.sort_by { |name, sup| [-live_count(sup), name.downcase] }

  c_live = codes.each_with_object({}) { |c, h| h[c] = 0 }
  c_soon = codes.each_with_object({}) { |c, h| h[c] = 0 }
  rows.each { |_, sup| sup.each { |cc, v| (v == "live" ? c_live : c_soon)[cc] += 1 } }
  total_live = c_live.values.sum

  p = []
  p << "<!doctype html>"
  p << "<!-- generated from data.json by scripts/refresh.rb — do not edit -->"
  p << '<html lang="en"><head><meta charset="utf-8"/>'
  p << '<meta name="viewport" content="width=device-width, initial-scale=1"/>'
  p << "<title>taptopay — Apple Tap to Pay coverage matrix</title>"
  p << '<meta name="description" content="Which Payment Service Providers (PSPs) support Apple Tap to Pay on iPhone in each country. Auto-refreshed daily."/>'
  p << "<style>"
  p << INDEX_CSS.gsub(/\n/, "")
  p << "</style></head><body>"

  p << "<header><h1>taptopay</h1>"
  p << "<p>Apple Tap to Pay on iPhone — PSP × country coverage matrix</p>"
  p << '<div class="meta">'
  p << '<span>Source: <a href="https://developer.apple.com/tap-to-pay/regions/">developer.apple.com/tap-to-pay/regions</a></span>'
  p << "<span>· Snapshot #{data['snapshot_date']}</span>"
  p << "<span>· #{rows.size} PSPs · #{codes.size} countries · #{total_live} live cells</span>"
  p << '<span>· <a href="https://github.com/ohwhen/taptopay/blob/main/CHANGELOG.md">changelog</a> · <a href="https://github.com/ohwhen/taptopay/blob/main/data.json">data.json</a></span>'
  p << "</div>"
  p << '<div class="legend"><span><span class="dot live"></span>live support</span>'
  p << '<span><span class="dot soon"></span>announced / coming soon</span>'
  p << "<span>First row and column stay pinned while you scroll.</span></div></header>"

  p << '<div class="matrix-wrap"><div class="matrix"><table>'
  p << '<thead><tr><th class="psp">PSP</th>'
  codes.each { |cc| p << %Q(<th class="code"><abbr title="#{esc(name_by_code[cc])}">#{cc}</abbr></th>) }
  p << "<th>Total</th></tr></thead><tbody>"
  rows.each do |name, sup|
    live = live_count(sup)
    soon = soon_count(sup)
    label = if urls[name]
              %Q(<a href="#{esc(urls[name])}" target="_blank" rel="noreferrer">#{esc(name)}</a>)
            else
              esc(name)
            end
    p << "<tr>"
    p << %Q(<td class="psp">#{label}</td>)
    codes.each do |cc|
      case sup[cc]
      when "live"        then p << '<td class="live">●</td>'
      when "coming_soon" then p << '<td class="soon">◐</td>'
      else                    p << '<td class="empty">·</td>'
      end
    end
    t = live.to_s
    t += %Q( <span style="color:var(--ink-mute);font-weight:400">+#{soon}◐</span>) if soon.positive?
    p << "<td>#{t}</td></tr>"
  end
  p << "</tbody><tfoot><tr><td class=\"psp\">Country total</td>"
  codes.each do |cc|
    cell = c_live[cc].to_s
    cell += %Q( <span style="color:var(--ink-mute);font-weight:400">+#{c_soon[cc]}◐</span>) if c_soon[cc].positive?
    p << "<td>#{cell}</td>"
  end
  p << "<td>#{total_live}</td></tr></tfoot></table></div></div>"

  p << '<footer><p><strong>Repository:</strong> <a href="https://github.com/ohwhen/taptopay">github.com/ohwhen/taptopay</a> · auto-refreshed daily.</p></footer>'
  p << "</body></html>"
  p.join
end

# ─── main ──────────────────────────────────────────────────────────────────────

def core(d) = { "source_url" => d["source_url"], "countries" => d["countries"] }

def main
  new_data = scrape
  old_data = DATA_PATH.exist? ? JSON.parse(DATA_PATH.read) : nil
  data_changed = old_data.nil? || core(old_data) != core(new_data)

  if data_changed
    DATA_PATH.write(JSON.pretty_generate(new_data) + "\n")
    if old_data.nil?
      total = new_data["countries"].sum { |c| c["psps"].size }
      soon  = new_data["countries"].sum { |c| c["psps"].count { |p| p["status"] == "coming_soon" } }
      live  = total - soon
      body  = "## #{new_data['snapshot_date']}\n\nInitial snapshot: **#{live} live** + **#{soon} coming-soon** PSP × country entries across **#{new_data['countries'].size} countries / regions**.\n\n"
      CHANGELOG_PATH.write(CHANGELOG_HEADER + body)
    else
      d = diff_data(old_data, new_data)
      prepend_changelog(new_data["snapshot_date"], changelog_entry(new_data["snapshot_date"], d)) if d.values.any? { |v| !v.empty? }
    end
  end

  current = JSON.parse(DATA_PATH.read)
  README_PATH.write(render_readme(current))
  INDEX_PATH.write(render_index_html(current))

  n_psps = current["countries"].sum { |c| c["psps"].size }
  status_str = data_changed ? "CHANGED" : "unchanged"
  puts "refresh: data=#{status_str} · #{n_psps} PSP×country entries · #{current['countries'].size} countries · snapshot #{current['snapshot_date']}"
end

main if $PROGRAM_NAME == __FILE__
